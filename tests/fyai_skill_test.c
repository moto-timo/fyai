/*
 * fyai_skill_test.c - tests for the parsing and expansion of skills
 *
 * Copyright (c) 2026 Pantelis Antoniou <pantelis.antoniou@konsulko.com>
 * SPDX-License-Identifier: MIT
 */

#define FYAI_MODULE FYAIEM_UNKNOWN

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fyai.h"
#include "fyai_skill.h"
#include "fyai_test.h"

#include "fyai_test_registry.h"

FYAI_TEST_ENTRY(skill, name_valid, skill_name_valid)
FYAI_TEST_ENTRY(skill, parse_frontmatter, skill_parse_frontmatter)
FYAI_TEST_ENTRY(skill, parse_rejects, skill_parse_rejects)
FYAI_TEST_ENTRY(skill, expand_arguments, skill_expand_arguments)
FYAI_TEST_ENTRY(skill, allowed_tools, skill_allowed_tools)

static struct fy_generic_builder *skill_builder(void)
{
	struct fy_generic_builder_cfg cfg = {
		.flags = FYGBCF_SCOPE_LEADER | FYGBCF_DEDUP_ENABLED,
	};

	return fy_generic_builder_create(&cfg);
}

int skill_name_valid(void)
{
	FYAI_TCHECK(fyai_skill_name_valid("review"));
	FYAI_TCHECK(fyai_skill_name_valid("pr-2-review"));
	FYAI_TCHECK(!fyai_skill_name_valid(""));
	FYAI_TCHECK(!fyai_skill_name_valid("-lead"));
	FYAI_TCHECK(!fyai_skill_name_valid("Upper"));
	FYAI_TCHECK(!fyai_skill_name_valid("a/b"));
	FYAI_TCHECK(!fyai_skill_name_valid(
		"a1234567890123456789012345678901234567890123456789012345678901234"));
	printf("ok - a skill name is lowercase, digits and '-', 64 at most\n");
	return 0;
}

int skill_parse_frontmatter(void)
{
	struct fy_generic_builder *gb = skill_builder();
	fy_generic parsed, fm;
	char why[512];

	FYAI_TCHECK(gb != NULL);
	parsed = fyai_skill_parse(gb,
		"---\ndescription: Do a thing.\ncontext: fork\n"
		"allowed-tools: [Read]\nunknown-key: kept\n---\nBODY\n",
		"from-dir", why, sizeof(why));
	FYAI_TCHECK(fy_is_mapping(parsed));
	fm = fy_get(parsed, "frontmatter", fy_invalid);
	/* The directory names a skill whose front matter does not. */
	FYAI_TCHECK(fy_equal(fy_get(fm, "name", fy_invalid), "from-dir"));
	FYAI_TCHECK(fy_equal(fy_get(fm, "unknown-key", fy_invalid), "kept"));
	FYAI_TCHECK(fy_equal(fy_get(parsed, "body", fy_invalid), "BODY\n"));

	/* A name in the front matter wins, and CRLF lines are read. */
	parsed = fyai_skill_parse(gb,
		"---\r\nname: given\r\ndescription: D.\r\n---\r\nB\r\n",
		"dir", why, sizeof(why));
	FYAI_TCHECK(fy_is_mapping(parsed));
	fm = fy_get(parsed, "frontmatter", fy_invalid);
	FYAI_TCHECK(fy_equal(fy_get(fm, "name", fy_invalid), "given"));
	fy_generic_builder_destroy(gb);
	printf("ok - the front matter is split, named and kept\n");
	return 0;
}

/* Whether @text is refused with a cause that contains @needle. */
static bool skill_refused(struct fy_generic_builder *gb, const char *text,
			  const char *needle)
{
	fy_generic parsed;
	char why[512];

	parsed = fyai_skill_parse(gb, text, "dir", why, sizeof(why));
	return fy_is_invalid(parsed) && strstr(why, needle);
}

int skill_parse_rejects(void)
{
	struct fy_generic_builder *gb = skill_builder();

	FYAI_TCHECK(gb != NULL);
	FYAI_TCHECK(skill_refused(gb, "no front matter\n", "must start"));
	FYAI_TCHECK(skill_refused(gb, "---\ndescription: D.\n", "closing"));
	FYAI_TCHECK(skill_refused(gb, "---\nname: x\n---\n", "description"));
	FYAI_TCHECK(skill_refused(gb, "---\n- a\n---\n", "mapping"));
	FYAI_TCHECK(skill_refused(gb, "---\nname: Bad Name\ndescription: D.\n"
				  "---\n", "name"));
	FYAI_TCHECK(skill_refused(gb, "---\ndescription: D.\ncontext: spawn\n"
				  "---\n", "context"));
	FYAI_TCHECK(skill_refused(gb, "---\ndescription: D.\ntimeout: -1\n"
				  "---\n", "timeout"));
	fy_generic_builder_destroy(gb);
	printf("ok - a front matter that the schema refuses is not read\n");
	return 0;
}

/* The body of @body expanded with @args. */
static const char *skill_expanded(struct fy_generic_builder *gb,
				  const char *body, const char *args)
{
	fy_generic skill, out;

	skill = fy_mapping(gb, "frontmatter", fy_mapping(gb, "name", "s"),
			   "body", body);
	out = fyai_skill_expand(NULL, gb, skill, args);
	return fy_is_string(out) ?
		fy_gb_intern_string(gb, fy_castp(&out, "")) : NULL;
}

int skill_expand_arguments(void)
{
	struct fy_generic_builder *gb = skill_builder();
	const char *out;

	FYAI_TCHECK(gb != NULL);
	out = skill_expanded(gb, "all=$ARGUMENTS first=$0 second=$ARGUMENTS[1]",
			     "a 'b c' d");
	FYAI_TCHECK(out && !strcmp(out, "all=a 'b c' d first=a second=b c"));
	/* A word past the end is empty. */
	out = skill_expanded(gb, "[$5]", "a");
	FYAI_TCHECK(out && !strcmp(out, "[]"));
	/* The files of the skill are under skill:NAME. */
	out = skill_expanded(gb, "${CLAUDE_SKILL_DIR}/x.md", "");
	FYAI_TCHECK(out && !strcmp(out, "skill:s/x.md"));
	/* A body that names no argument gets them at its end. */
	out = skill_expanded(gb, "Do it.", "now please");
	FYAI_TCHECK(out && !strcmp(out, "Do it.\n\nARGUMENTS: now please\n"));
	out = skill_expanded(gb, "Do it.\n", "");
	FYAI_TCHECK(out && !strcmp(out, "Do it.\n"));
	fy_generic_builder_destroy(gb);
	printf("ok - the arguments take their places as Claude Code puts them\n");
	return 0;
}

/* Whether the sequence @list holds @name. */
static bool skill_has(fy_generic list, const char *name)
{
	fy_generic item;

	fy_foreach(item, list)
		if (fy_equal(item, name))
			return true;
	return false;
}

int skill_allowed_tools(void)
{
	struct fy_generic_builder *gb = skill_builder();
	fy_generic tools, dropped;

	FYAI_TCHECK(gb != NULL);
	dropped = fy_seq_empty;
	tools = fyai_skill_allowed_tools(gb,
		fy_mapping(gb, "allowed-tools",
			   "Read, Bash(git:*) WebFetch todo_write"),
		&dropped);
	FYAI_TCHECK(fy_is_sequence(tools));
	FYAI_TCHECK(skill_has(tools, "read_file"));
	FYAI_TCHECK(skill_has(tools, "shell"));
	FYAI_TCHECK(skill_has(tools, "shell_output"));
	FYAI_TCHECK(skill_has(tools, "todo_write"));
	/* Every forked skill keeps its files, its questions and the time. */
	FYAI_TCHECK(skill_has(tools, "skill"));
	FYAI_TCHECK(skill_has(tools, "ask_parent"));
	FYAI_TCHECK(!skill_has(tools, "write_file"));
	FYAI_TCHECK(fy_len(dropped) == 1 && skill_has(dropped, "WebFetch"));
	/* No allowed-tools: every tool. */
	tools = fyai_skill_allowed_tools(gb, fy_map_empty, NULL);
	FYAI_TCHECK(fy_is_invalid(tools));
	fy_generic_builder_destroy(gb);
	printf("ok - allowed-tools maps Claude Code names to fyai tools\n");
	return 0;
}
