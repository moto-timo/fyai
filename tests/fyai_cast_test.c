/*
 * fyai_cast_test.c - tests for the asciicast writer
 *
 * Copyright (c) 2026 Pantelis Antoniou <pantelis.antoniou@konsulko.com>
 * SPDX-License-Identifier: MIT
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <libfyaml.h>

#include "fyai.h"
#include "fyai_cast.h"
#include "fyai_test.h"
#include "fyai_yaml_flags.h"
#include "fyai_test_registry.h"

FYAI_TEST_ENTRY(cast, events, cast_events)
FYAI_TEST_ENTRY(cast, utf8_repair, cast_utf8_repair)

/* Make a recording in a new directory and return its text. */
static char *record(void (*fill)(struct fyai_cast *), char *path, size_t psz)
{
	struct fyai_cast *c;
	char dir[] = "/tmp/fyai-cast-XXXXXX", *text;
	FILE *fp;
	long size;

	FYAI_TCHECK(mkdtemp(dir));
	snprintf(path, psz, "%s/run.cast", dir);
	c = fyai_cast_open(NULL, path, 100, 30, "prog \"x\"");
	FYAI_TCHECK(c);
	fill(c);
	fyai_cast_close(c);
	fp = fopen(path, "r");
	FYAI_TCHECK(fp);
	fseek(fp, 0, SEEK_END);
	size = ftell(fp);
	rewind(fp);
	text = calloc(1, (size_t)size + 1);
	FYAI_TCHECK(text && fread(text, 1, (size_t)size, fp) == (size_t)size);
	fclose(fp);
	return text;
}

static void cleanup(const char *path)
{
	char dir[256];
	char *slash;

	FYAI_TCHECK(strlen(path) < sizeof(dir));
	strcpy(dir, path);
	slash = strrchr(dir, '/');
	*slash = '\0';
	FYAI_TCHECK(!unlink(path));
	FYAI_TCHECK(!rmdir(dir));
}

static void fill_events(struct fyai_cast *c)
{
	fyai_cast_output(c, "a\"b\\c\r\n\x1b[0m", 11);
	fyai_cast_input(c, "k", 1);
	fyai_cast_resize(c, 80, 24);
	fyai_cast_marker(c, "step 1: wait");
}

/* Every line is a JSON document: the header is a mapping, an event is a
 * sequence of the time, the kind and the text. */
static void check_lines(const char *text)
{
	struct fy_generic_builder_cfg cfg = {
		.flags = FYGBCF_SCHEMA_AUTO | FYGBCF_SCOPE_LEADER,
	};
	struct fy_generic_builder *gb = fy_generic_builder_create(&cfg);
	const char *line = text, *end;
	char *copy;
	fy_generic v;
	size_t lines = 0;

	FYAI_TCHECK(gb);
	while (*line) {
		end = strchr(line, '\n');
		FYAI_TCHECK(end);
		copy = strndup(line, (size_t)(end - line));
		FYAI_TCHECK(copy);
		v = fy_parse(gb, copy, FYAI_YAML_PARSE_FLAGS | FYOPPF_INPUT_TYPE_STRING,
			     NULL);
		FYAI_TCHECK(fy_is_valid(v));
		if (!lines) {
			FYAI_TCHECK(fy_is_mapping(v));
			FYAI_TCHECK(fy_get(v, "version", 0LL) == 2);
		} else {
			FYAI_TCHECK(fy_is_sequence(v) && fy_len(v) == 3);
			FYAI_TCHECK(fy_is_string(fy_get_at(v, 1)));
			FYAI_TCHECK(fy_is_string(fy_get_at(v, 2)));
		}
		free(copy);
		lines++;
		line = end + 1;
	}
	FYAI_TCHECK(lines > 1);
	fy_generic_builder_destroy(gb);
}

int cast_events(void)
{
	char path[256];
	char *text = record(fill_events, path, sizeof(path));
	struct stat st;

	check_lines(text);
	FYAI_TCHECK(!strncmp(text, "{\"version\": 2, \"width\": 100, "
			     "\"height\": 30, \"timestamp\": ", 45));
	FYAI_TCHECK(strstr(text, "\"command\": \"prog \\\"x\\\"\"}\n"));
	FYAI_TCHECK(strstr(text, ", \"o\", \"a\\\"b\\\\c\\r\\n\\u001B[0m\"]\n"));
	FYAI_TCHECK(strstr(text, ", \"i\", \"k\"]\n"));
	FYAI_TCHECK(strstr(text, ", \"r\", \"80x24\"]\n"));
	FYAI_TCHECK(strstr(text, ", \"m\", \"step 1: wait\"]\n"));
	/* A recording holds what the terminal showed: only the owner reads. */
	FYAI_TCHECK(!stat(path, &st) && (st.st_mode & 077) == 0);
	free(text);
	cleanup(path);
	return 0;
}

static void fill_utf8(struct fyai_cast *c)
{
	/* A character in two pieces, a stray byte, and a cut sequence that
	 * the next bytes do not finish. */
	fyai_cast_output(c, "\xe2\x96", 2);
	fyai_cast_output(c, "\x8c" "\xff" "ok", 4);
	fyai_cast_output(c, "\xe2", 1);
	fyai_cast_output(c, "A", 1);
}

int cast_utf8_repair(void)
{
	char path[256];
	char *text = record(fill_utf8, path, sizeof(path));

	check_lines(text);
	FYAI_TCHECK(strstr(text, ", \"o\", \"\xe2\x96\x8c\xef\xbf\xbd" "ok\"]\n"));
	FYAI_TCHECK(strstr(text, ", \"o\", \"\xef\xbf\xbd" "A\"]\n") ||
		    strstr(text, ", \"o\", \"A\"]\n"));
	free(text);
	cleanup(path);
	return 0;
}
