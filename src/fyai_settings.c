/*
 * fyai_settings.c - the settings tool: the model reads the configuration
 *
 * SPDX-License-Identifier: MIT
 *
 * The model asks; fyai answers from the merged configuration by the access
 * that the schema states for each key (x-fyai-model, see
 * doc/declarative-state.md). A hidden key is left out of every answer and
 * named under `hidden`. The model never writes state: it presents a change
 * set and an explanation, and fyai checks the set, makes the diff, and
 * applies it at once (write), after the user accepts it in the review panel
 * (review), or keeps it as a proposal that the user approves later.
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fyai.h"
#include "fyai_agent.h"
#include "fyai_ask.h"
#include "fyai_branch.h"
#include "fyai_config.h"
#include "fyai_diff.h"
#include "fyai_event.h"
#include "fyai_settings.h"
#include "fyai_storage.h"
#include "fyai_tool_registry.h"
#include "fyai_ui.h"
#include "utils.h"

#define FYAI_MODULE FYAIEM_CONFIG

/* The bound on the depth of a walk of the schema or of a value. */
#define SETTINGS_DEPTH_MAX	64
/* The bound on the keys that one list gives. */
#define SETTINGS_LIST_MAX	100
/* The bounds on one change set, on its explanation, and on each log. */
#define SETTINGS_CHANGES_MAX	32
#define SETTINGS_EXPLANATION_MAX 16384
#define SETTINGS_LOG_MAX	64
/* The bounds on the words of a search and on the keys that it gives. */
#define SETTINGS_SEARCH_WORDS	8
#define SETTINGS_SEARCH_LIMIT	20
#define SETTINGS_SEARCH_MAX	50

struct settings_walk {
	struct fyai_ctx *ctx;
	struct fy_generic_builder *gb;
	fy_generic hidden;	/* the hidden paths met, a sequence */
	fy_generic keys;	/* the rows of a list, a sequence */
	size_t count;
	bool changed;		/* only keys that are not the default */
};

/*
 * A path names keys of the schema and of user mappings (server and persona
 * names); a segment `*` stands for any such name. Its characters are those,
 * so the title row can show it as it is.
 */
static bool settings_path_valid(const char *path)
{
	const char *p;

	for (p = path; *p; p++)
		if (!(*p >= 'a' && *p <= 'z') && !(*p >= 'A' && *p <= 'Z') &&
		    !(*p >= '0' && *p <= '9') && !strchr("_-./:*", *p))
			return false;
	/* No empty segment, and none that starts with a dot. */
	return *path != '/' && *path != '.' && (!*path || p[-1] != '/') &&
	       !strstr(path, "//") && !strstr(path, "/.");
}

static bool seq_has(fy_generic seq, const char *s)
{
	fy_generic v;

	fy_foreach(v, seq)
		if (fy_equal(v, s))
			return true;
	return false;
}

static const char *settings_join(struct fy_generic_builder *gb,
				 const char *path, const char *key)
{
	return fy_gb_intern_string(gb, fy_sprintfa("%s%s%s", path,
						   *path ? "/" : "", key));
}

/*
 * The arena is out of reach of the shell when a view holds it as a
 * descriptor, or when the sandbox is on and denies it: the sandbox denies
 * <project>/.fyai, so an arena elsewhere is not known to be denied.
 */
static bool settings_arena_protected(struct fyai_ctx *ctx)
{
	struct fyai_cfg *cfg = ctx->cfg;
	char arena[PATH_MAX], denied[PATH_MAX];
	char *root, *deny;
	size_t len;
	bool inside;

	if (cfg->view_arena)
		return true;
	if (!cfg->enable_sandbox || !cfg->arena_dir || cfg->view_project)
		return false;
	root = fyai_discover_project_root();
	if (!root)
		return false;
	deny = NULL;
	inside = asprintf(&deny, "%s/.fyai", root) >= 0 &&
		 realpath(deny, denied) && realpath(cfg->arena_dir, arena);
	len = inside ? strlen(denied) : 0;
	inside = inside && !strncmp(denied, arena, len) &&
		 (arena[len] == '/' || !arena[len]);
	free(deny);
	free(root);
	return inside;
}

/*
 * The default of the schema node @node: its own, else the mapping of the
 * defaults of its members, so a group such as `retry` shows what applies.
 * fy_invalid when nothing below it has a default.
 */
static fy_generic settings_schema_default(struct fy_generic_builder *gb,
					  fy_generic node, int depth)
{
	fy_generic v, out, key, child;

	v = fy_get(node, "default", fy_invalid);
	if (fy_is_valid(v) || depth > SETTINGS_DEPTH_MAX)
		return v;
	out = fy_invalid;
	fy_foreach_key_value(key, child, fy_get(node, "properties",
						fy_invalid)) {
		v = settings_schema_default(gb, child, depth + 1);
		if (!fy_is_valid(v))
			continue;
		out = fy_assoc(gb, fy_is_valid(out) ? out : fy_mapping(gb),
			       key, v);
	}
	return out;
}

/* The value in force at @path, or the default of the schema. */
static fy_generic settings_value(struct settings_walk *w, const char *path,
				 const char **layerp)
{
	struct fyai_cfg *cfg = w->ctx->cfg;
	fy_generic v, stored;

	v = *path ? fy_get_at_pathstr(w->gb, cfg->config_doc, path) :
		cfg->config_doc;
	if (!fy_is_valid(v)) {
		*layerp = "default";
		return settings_schema_default(w->gb,
					       fyai_config_schema_node(path),
					       0);
	}
	if (fy_is_mapping(cfg->config_session) && *path &&
	    fy_is_valid(fy_get_at_pathstr(w->gb, cfg->config_session, path))) {
		*layerp = "session";
		return v;
	}
	stored = !*path ? w->ctx->arena_config :
		 fy_is_mapping(w->ctx->arena_config) ?
		 fy_get_at_pathstr(w->gb, w->ctx->arena_config, path) :
		 fy_invalid;
	*layerp = fy_is_valid(stored) && !fy_compare(stored, v) ? "branch" :
		  "invocation";
	return v;
}

/*
 * @v at @path without the members that the model must not read. Each such
 * member is named in the hidden list of @w.
 */
static fy_generic settings_redact(struct settings_walk *w, const char *path,
				  fy_generic v, int depth)
{
	fy_generic out, key, member;
	const char *sub;

	if (!fy_is_mapping(v) || depth > SETTINGS_DEPTH_MAX)
		return v;
	out = fy_mapping(w->gb);
	fy_foreach_key_value(key, member, v) {
		sub = settings_join(w->gb, path, fy_castp(&key, ""));
		if (fyai_config_model_access(sub) == FYAI_MODEL_HIDDEN) {
			w->hidden = fy_append(w->gb, w->hidden, sub);
			continue;
		}
		out = fy_assoc(w->gb, out, key,
			       settings_redact(w, sub, member, depth + 1));
	}
	return out;
}

/*
 * The first sentence of the description of @node: the schema keeps it short
 * as a hint, so it names a key without the cost of the whole text.
 */
static const char *settings_summary(struct fy_generic_builder *gb,
				    fy_generic node)
{
	const char *desc = fy_get(node, "description", "");
	const char *end;

	end = strstr(desc, ". ");
	return fy_gb_intern_string(gb, fy_sprintfa("%.*s",
			end ? (int)(end - desc + 1) : (int)strlen(desc), desc));
}

/* The members of the schema node of @path, with the access of each. */
static fy_generic settings_children(struct settings_walk *w, const char *path,
				    fy_generic node)
{
	fy_generic rows, key, child;
	const char *sub;
	enum fyai_model_access access;

	rows = fy_sequence(w->gb);
	fy_foreach_key_value(key, child, fy_get(node, "properties",
						fy_invalid)) {
		sub = settings_join(w->gb, path, fy_castp(&key, ""));
		access = fyai_config_model_access(sub);
		if (access == FYAI_MODEL_HIDDEN) {
			w->hidden = fy_append(w->gb, w->hidden, sub);
			continue;
		}
		rows = fy_append(w->gb, rows, fy_mapping(w->gb,
			"key", sub,
			"access", fyai_model_access_name(access),
			"summary", settings_summary(w->gb, child)));
	}
	return rows;
}

struct settings_search {
	const char *words[SETTINGS_SEARCH_WORDS];
	size_t nwords;
	size_t limit;
	fy_generic by_key;	/* keys whose path holds every word */
	fy_generic by_text;	/* keys whose description holds some word */
	size_t found;
};

/*
 * Match each key of the schema under @path: every word must be in its path
 * or in its description. A member of a mapping of user names, such as a
 * server, is under the segment `*`, which stands for any name.
 */
static void settings_search_walk(struct settings_walk *w,
				 struct settings_search *s, const char *path,
				 fy_generic node, int depth)
{
	static const char *const alts[] = { "oneOf", "anyOf" };
	fy_generic key, child, alt, row;
	const char *sub, *desc;
	size_t i, in_key;

	if (!fy_is_mapping(node) || depth > SETTINGS_DEPTH_MAX)
		return;
	fy_foreach_key_value(key, child, fy_get(node, "properties",
						fy_invalid)) {
		sub = settings_join(w->gb, path, fy_castp(&key, ""));
		if (fyai_config_model_access(sub) == FYAI_MODEL_HIDDEN)
			continue;
		desc = fy_get(child, "description", "");
		in_key = 0;
		for (i = 0; i < s->nwords; i++) {
			if (strcasestr(sub, s->words[i]))
				in_key++;
			else if (!strcasestr(desc, s->words[i]))
				break;
		}
		if (i == s->nwords) {
			s->found++;
			row = fy_mapping(w->gb, "key", sub,
				"access", fyai_model_access_name(
					fyai_config_model_access(sub)),
				"summary", settings_summary(w->gb, child));
			if (in_key == s->nwords && fy_len(s->by_key) < s->limit)
				s->by_key = fy_append(w->gb, s->by_key, row);
			else if (in_key < s->nwords &&
				 fy_len(s->by_text) < s->limit)
				s->by_text = fy_append(w->gb, s->by_text, row);
		}
		settings_search_walk(w, s, sub, child, depth + 1);
	}
	settings_search_walk(w, s, settings_join(w->gb, path, "*"),
			     fy_get(node, "additionalProperties", fy_invalid),
			     depth + 1);
	for (i = 0; i < ARRAY_SIZE(alts); i++)
		fy_foreach(alt, fy_get(node, alts[i], fy_invalid))
			settings_search_walk(w, s, path, alt, depth + 1);
}

/* The keys that match @query, those that name it in their path first. */
static fy_generic settings_search(struct settings_walk *w, const char *path,
				  fy_generic node, const char *query,
				  long long limit)
{
	struct settings_search s;
	fy_generic keys, row;
	char *copy, *word, *save;

	memset(&s, 0, sizeof(s));
	s.limit = limit > 0 && limit <= SETTINGS_SEARCH_MAX ? (size_t)limit :
		  SETTINGS_SEARCH_LIMIT;
	s.by_key = fy_sequence(w->gb);
	s.by_text = fy_sequence(w->gb);
	copy = strdup(query);
	if (!copy)
		return fy_value(w->gb, "settings: the query could not be kept");
	for (word = strtok_r(copy, " \t", &save);
	     word && s.nwords < SETTINGS_SEARCH_WORDS;
	     word = strtok_r(NULL, " \t", &save))
		s.words[s.nwords++] = fy_gb_intern_string(w->gb, word);
	free(copy);
	if (!s.nwords)
		return fy_value(w->gb, "settings: search needs a query");
	settings_search_walk(w, &s, path, node, 0);
	keys = s.by_key;
	fy_foreach(row, s.by_text) {
		if (fy_len(keys) >= s.limit)
			break;
		keys = fy_append(w->gb, keys, row);
	}
	return fy_mapping(w->gb, "query", query, "path", path, "keys", keys,
			  "found", (long long)s.found);
}

/* The schema of a node as the model reads it: no members, no extensions. */
static fy_generic settings_schema(struct fy_generic_builder *gb,
				  fy_generic node)
{
	fy_generic out, key, v;
	const char *name;

	out = fy_mapping(gb);
	fy_foreach_key_value(key, v, node) {
		name = fy_castp(&key, "");
		if (!strncmp(name, "x-fyai-", 7) ||
		    fy_any_equal(key, "properties", "additionalProperties"))
			continue;
		out = fy_assoc(gb, out, key, v);
	}
	return out;
}

static fy_generic settings_describe(struct settings_walk *w, const char *path)
{
	fy_generic node, value, result;
	const char *layer;

	node = *path ? fyai_config_schema_node(path) :
	       fyai_config_schema(NULL);
	value = settings_redact(w, path, settings_value(w, path, &layer), 0);
	result = fy_mapping(w->gb,
		"path", path,
		"access", fyai_model_access_name(
				fyai_config_model_access(path)),
		"scope", fyai_config_session_scoped(path) ? "session" :
			 "stored",
		"layer", layer);
	if (fy_is_valid(value))
		result = fy_assoc(w->gb, result, "value", value);
	if (fy_is_mapping(node)) {
		result = fy_assoc(w->gb, result, "schema",
				  settings_schema(w->gb, node));
		if (fy_is_mapping(fy_get(node, "properties", fy_invalid)))
			result = fy_assoc(w->gb, result, "keys",
					  settings_children(w, path, node));
	} else {
		result = fy_assoc(w->gb, result, "schema", fy_null);
	}
	return result;
}

/* Add a row for each key under @path that has no members in the schema. */
static void settings_list_walk(struct settings_walk *w, const char *path,
			       fy_generic node, int depth)
{
	fy_generic props, key, child, value, dflt;
	enum fyai_model_access access;
	const char *sub, *layer;

	if (w->count >= SETTINGS_LIST_MAX || depth > SETTINGS_DEPTH_MAX)
		return;
	props = fy_get(node, "properties", fy_invalid);
	if (*path && !fy_is_mapping(props)) {
		access = fyai_config_model_access(path);
		value = settings_value(w, path, &layer);
		dflt = fy_get(node, "default", fy_invalid);
		if (w->changed && (!strcmp(layer, "default") ||
				   (fy_is_valid(dflt) &&
				    !fy_compare(value, dflt))))
			return;
		value = settings_redact(w, path, value, 0);
		w->keys = fy_append(w->gb, w->keys, fy_mapping(w->gb,
			"key", path,
			"access", fyai_model_access_name(access),
			"layer", layer,
			"value", fy_is_valid(value) ? value : fy_null));
		w->count++;
		return;
	}
	fy_foreach_key_value(key, child, props) {
		sub = settings_join(w->gb, path, fy_castp(&key, ""));
		if (fyai_config_model_access(sub) == FYAI_MODEL_HIDDEN) {
			w->hidden = fy_append(w->gb, w->hidden, sub);
			continue;
		}
		settings_list_walk(w, sub, child, depth + 1);
	}
}

/* A change set that the model presented, checked, and diffed by fyai. */
struct settings_change {
	fy_generic changes;	/* [{path, value} or {path, delete: true}] */
	fy_generic paths;	/* the paths, in order */
	fy_generic before;	/* {path: value or null} of its layer */
	fy_generic after;
	fy_generic stored;	/* the branch configuration after */
	fy_generic session;	/* the session layer after, or fy_invalid */
	enum fyai_model_access access;	/* the strictest of every path */
	bool trial;		/* the session layer only, for every scope */
	const char *diff;	/* Markdown that fyai made, in the builder */
	const char *unified;	/* the unified diff alone */
	/* The entry of the change log that this change reverts or keeps,
	 * and the status the entry takes when the change applies, or NULL. */
	const char *mark_id;
	const char *mark_status;
};

/*
 * @text without control bytes: a line break and a tab stay, every other
 * byte under a blank becomes `?`. The text then sets no colour and moves no
 * cursor wherever it is drawn.
 */
static const char *settings_clean(struct fy_generic_builder *gb,
				  const char *text)
{
	char *copy, *p;
	const char *out;

	copy = strdup(text);
	if (!copy)
		return NULL;
	for (p = copy; *p; p++)
		if (((unsigned char)*p < 0x20 && *p != '\n' && *p != '\t') ||
		    (unsigned char)*p == 0x7f)
			*p = '?';
	out = fy_gb_intern_string(gb, copy);
	free(copy);
	return out;
}

/* Check the arguments of a change and find the strictest access of it. */
static int settings_change_normalize(struct settings_walk *w,
				     fy_generic list, struct settings_change *c,
				     char *why, size_t why_size)
{
	enum fyai_model_access access;
	fy_generic item, value, out, paths;
	const char *path;
	bool del;
	size_t n;

	n = fy_is_sequence(list) ? fy_len(list) : 0;
	if (n < 1 || n > SETTINGS_CHANGES_MAX) {
		snprintf(why, why_size, "a change needs 1 to %d changes",
			 SETTINGS_CHANGES_MAX);
		return -1;
	}
	c->access = FYAI_MODEL_WRITE;
	out = fy_sequence(w->gb);
	paths = fy_sequence(w->gb);
	fy_foreach(item, list) {
		path = fy_get(item, "path", "");
		if (!*path || !settings_path_valid(path) || strchr(path, '*')) {
			snprintf(why, why_size, "'%s' is not a key", path);
			return -1;
		}
		if (!fy_is_mapping(fyai_config_schema_node(path))) {
			snprintf(why, why_size, "%s is not a key of the schema",
				 path);
			return -1;
		}
		del = fy_get(item, "delete", false);
		value = fy_get(item, "value", fy_invalid);
		if (del == fy_is_valid(value)) {
			snprintf(why, why_size, "%s: give a value, or delete: "
				 "true", path);
			return -1;
		}
		access = fyai_config_model_access_tree(path);
		if (access <= FYAI_MODEL_READ) {
			snprintf(why, why_size, "%s is %s: the model cannot "
				 "change it", path,
				 fyai_model_access_name(access));
			return -1;
		}
		if (access < c->access)
			c->access = access;
		if (seq_has(paths, path)) {
			snprintf(why, why_size, "%s is changed twice", path);
			return -1;
		}
		paths = fy_append(w->gb, paths, path);
		out = fy_append(w->gb, out, del ?
			fy_mapping(w->gb, "path", path, "delete", true) :
			fy_mapping(w->gb, "path", path, "value", value));
	}
	c->changes = out;
	c->paths = paths;
	return 0;
}

/*
 * @doc with @path set to @value, or removed for fy_invalid. A removal also
 * removes each parent that it leaves empty, when the schema makes the parent
 * a plain mapping with no default: such an empty mapping means what its
 * absence means. A parent of a union, such as `sandbox`, stays.
 */
static fy_generic settings_doc_set(struct fy_generic_builder *gb,
				   fy_generic doc, const char *path,
				   fy_generic value)
{
	fy_generic node, parent;
	char *up, *slash;

	if (fy_is_valid(value))
		return fy_set_at_pathstr(gb, doc, path,
					 fy_gb_internalize(gb, value));
	if (!fy_is_valid(fy_get_at_pathstr(gb, doc, path)))
		return doc;
	doc = fy_delete_at_pathstr(gb, doc, path);
	up = strdup(path);
	if (!up)
		return fy_invalid;
	while (fy_is_valid(doc) && (slash = strrchr(up, '/'))) {
		*slash = '\0';
		node = fyai_config_schema_node(up);
		parent = fy_get_at_pathstr(gb, doc, up);
		if (!fy_is_mapping(parent) || !fy_empty(parent) ||
		    !fy_equal(fy_get(node, "type", fy_invalid), "object") ||
		    fy_is_valid(fy_get(node, "default", fy_invalid)))
			break;
		doc = fy_delete_at_pathstr(gb, doc, up);
	}
	free(up);
	return doc;
}

static fy_generic settings_doc_get(struct fy_generic_builder *gb,
				   fy_generic doc, const char *path)
{
	fy_generic v;

	v = fy_is_mapping(doc) ? fy_get_at_pathstr(gb, doc, path) : fy_invalid;
	return fy_is_valid(v) ? v : fy_null;
}

/* The emitted YAML of @v, or "{}" for a document that has nothing. */
static const char *settings_emit(struct fy_generic_builder *gb, fy_generic v)
{
	fy_generic text;

	if (!fy_is_mapping(v) || fy_empty(v))
		return "{}\n";
	text = fy_emit(gb, v, FYAI_YAML_EMIT_FLAGS, NULL);
	return fy_is_string(text) ? fy_gb_intern_string(gb,
					fy_castp(&text, "")) : NULL;
}

/*
 * @unified without the header rows of each file: the summary row names the
 * layer, and the rows of the panel are few.
 */
static const char *settings_diff_body(struct fy_generic_builder *gb,
				      const char *unified)
{
	struct response_buffer out = { 0 };
	const char *line, *nl, *body;
	size_t len;
	int rc = 0;

	for (line = unified; *line && !rc; line += len) {
		nl = strchr(line, '\n');
		len = nl ? (size_t)(nl - line) + 1 : strlen(line);
		if (!strncmp(line, "--- ", 4) || !strncmp(line, "+++ ", 4))
			continue;
		rc = response_buffer_append_data(&out, line, len);
	}
	body = rc ? NULL : fy_gb_intern_string(gb, out.data ? out.data : "");
	free(out.data);
	return body;
}

/*
 * The fence of a block that holds @text: more backticks than any run in
 * it, so that no text can close the block and write Markdown of its own.
 * NULL for a run too long to outdo.
 */
static const char *settings_fence(struct fy_generic_builder *gb,
				  const char *text)
{
	char fence[64];
	size_t run, longest = 0;
	const char *p;

	for (p = text; *p; p++) {
		for (run = 0; p[run] == '`'; run++)
			;
		if (run > longest)
			longest = run;
		if (run)
			p += run - 1;
	}
	if (longest >= sizeof(fence) - 1)
		return NULL;
	memset(fence, '`', longest < 3 ? 3 : longest + 1);
	fence[longest < 3 ? 3 : longest + 1] = '\0';
	return fy_gb_intern_string(gb, fence);
}

/* @unified as a fenced diff block, without the header rows of each file. */
static const char *settings_diff_block(struct fy_generic_builder *gb,
				       const char *unified)
{
	const char *body, *fence;

	body = settings_diff_body(gb, unified);
	fence = body ? settings_fence(gb, body) : NULL;
	if (!fence)
		return NULL;
	return fy_gb_intern_string(gb, fy_sprintfa("%sdiff\n%s%s\n", fence,
						   body, fence));
}

/*
 * Make the diff of @c: the unified diff of the emitted documents of each
 * layer that it writes, under a summary row. The diff holds values that the
 * model wrote, so its fence is longer than every run of backticks in it, and
 * no control byte stays.
 */
static int settings_change_diff(struct settings_walk *w,
				struct settings_change *c, fy_generic stored0,
				fy_generic session0)
{
	struct response_buffer all = { 0 };
	const char *a, *b, *p, *scope, *body;
	char *part;
	size_t added = 0, removed = 0;
	int rc = -1;

	if (fy_is_valid(c->stored)) {
		a = settings_emit(w->gb, stored0);
		b = settings_emit(w->gb, c->stored);
		if (!a || !b || fyai_diff_unified(a, strlen(a), b, strlen(b),
				"branch configuration", "branch configuration",
				2, &part))
			goto out;
		rc = response_buffer_append(&all, part);
		free(part);
		if (rc)
			goto out;
		rc = -1;
	}
	if (fy_is_valid(c->session)) {
		a = settings_emit(w->gb, session0);
		b = settings_emit(w->gb, c->session);
		if (!a || !b || fyai_diff_unified(a, strlen(a), b, strlen(b),
				"session layer", "session layer", 2, &part))
			goto out;
		rc = response_buffer_append(&all, part);
		free(part);
		if (rc)
			goto out;
		rc = -1;
	}
	c->unified = settings_clean(w->gb, all.data ? all.data : "");
	if (!c->unified)
		goto out;
	for (p = c->unified; *p; p = strchr(p, '\n') ? strchr(p, '\n') + 1 :
						       p + strlen(p)) {
		if (*p == '+' && strncmp(p, "+++", 3))
			added++;
		else if (*p == '-' && strncmp(p, "---", 3))
			removed++;
	}
	scope = c->trial ? "this session only, as a trial" :
		fy_is_valid(c->stored) && fy_is_valid(c->session) ?
			"the branch configuration and this session" :
		fy_is_valid(c->stored) ? "the branch configuration" :
			"this session";
	body = settings_diff_block(w->gb, c->unified);
	if (!body)
		goto out;
	c->diff = fy_gb_intern_string(w->gb, fy_sprintfa(
		"**%zu key%s \u00b7 +%zu \u2212%zu lines \u00b7 %s**\n\n%s",
		fy_len(c->paths), fy_len(c->paths) == 1 ? "" : "s",
		added, removed, scope, body));
	rc = c->diff ? 0 : -1;
out:
	free(all.data);
	return rc;
}

/*
 * Build the configuration after @c: each path in the session layer when it
 * is session-scoped or the change is a trial, else in the branch
 * configuration. Both are checked; the diff is made from them.
 */
static int settings_change_build(struct settings_walk *w,
				 struct settings_change *c,
				 char *why, size_t why_size)
{
	struct fyai_ctx *ctx = w->ctx;
	struct fyai_cfg *cfg = ctx->cfg;
	fy_generic stored0, session0, stored, session, item, value, problems, p;
	bool in_session, any_stored = false, any_session = false;
	const char *path;
	size_t len;

	stored0 = fy_is_mapping(ctx->arena_config) ? ctx->arena_config :
		  fy_map_empty;
	session0 = fy_is_mapping(cfg->config_session) ? cfg->config_session :
		   fy_map_empty;
	stored = stored0;
	session = session0;
	c->before = fy_mapping(w->gb);
	c->after = fy_mapping(w->gb);
	fy_foreach(item, c->changes) {
		path = fy_get(item, "path", "");
		value = fy_get(item, "value", fy_invalid);
		in_session = c->trial || fyai_config_session_scoped(path);
		c->before = fy_assoc(w->gb, c->before, path, settings_doc_get(
			w->gb, in_session ? session0 : stored0, path));
		if (in_session) {
			session = settings_doc_set(cfg->gb, session, path,
						   value);
			any_session = true;
		} else {
			stored = settings_doc_set(ctx->gb, stored, path, value);
			any_stored = true;
		}
		if (!fy_is_valid(stored) || !fy_is_valid(session)) {
			snprintf(why, why_size, "%s: the value cannot be set",
				 path);
			return -1;
		}
	}
	c->stored = fy_invalid;
	c->session = fy_invalid;
	if (any_stored) {
		problems = fyai_config_check(cfg, &stored);
		if (!fy_empty(problems)) {
			len = (size_t)snprintf(why, why_size,
				"the configuration would not be valid:");
			fy_foreach(p, problems)
				if (len < why_size)
					len += (size_t)snprintf(why + len,
						why_size - len, " %s;",
						fy_castp(&p, ""));
			return -1;
		}
		c->stored = stored;
	}
	if (any_session) {
		if (!fyai_config_session_layer_valid(ctx, session)) {
			snprintf(why, why_size,
				 "the session layer would not be valid");
			return -1;
		}
		c->session = session;
	}
	fy_foreach(item, c->changes) {
		path = fy_get(item, "path", "");
		in_session = c->trial || fyai_config_session_scoped(path);
		c->after = fy_assoc(w->gb, c->after, path, settings_doc_get(
			w->gb, in_session ? session : stored, path));
	}
	if (settings_change_diff(w, c, stored0, session0)) {
		snprintf(why, why_size, "the diff could not be made");
		return -1;
	}
	if (!*c->unified) {
		snprintf(why, why_size, "the change changes nothing");
		return -1;
	}
	return 0;
}

/* The next id of a log: @prefix and one more than the highest number. */
static const char *settings_next_id(struct fy_generic_builder *gb,
				    fy_generic log, char prefix)
{
	fy_generic item;
	const char *name;
	long long n, top = 0;

	fy_foreach(item, log) {
		name = fy_get(item, "name", "");
		if (*name != prefix)
			continue;
		n = strtoll(name + 1, NULL, 10);
		if (n > top)
			top = n;
	}
	return fy_gb_intern_string(gb, fy_sprintfa("%c%lld", prefix, top + 1));
}

/* @log with @entry, without its oldest entries past the bound. */
static fy_generic settings_log_append(struct fy_generic_builder *gb,
				      fy_generic log, fy_generic entry)
{
	fy_generic out, item;
	size_t n, skip;

	n = fy_len(log) + 1;
	skip = n > SETTINGS_LOG_MAX ? n - SETTINGS_LOG_MAX : 0;
	out = fy_sequence(gb);
	fy_foreach(item, log) {
		if (skip) {
			skip--;
			continue;
		}
		out = fy_append(gb, out, item);
	}
	return fy_append(gb, out, entry);
}

/*
 * Publish @member of the store of this branch as @log, and @member2 as @log2
 * when it is not NULL, with the configuration of the context, under the
 * operation `settings`.
 */
static int settings_publish(struct fyai_ctx *ctx, const char *member,
			    fy_generic log, const char *member2,
			    fy_generic log2)
{
	struct fyai_branch prev;
	fy_generic store;

	fyai_branch_decode(ctx->branch_prev, &prev);
	store = fyai_branch_store_build(ctx->gb, &prev);
	store = fy_assoc(ctx->gb, store, member,
			 fy_gb_internalize(ctx->gb, log));
	if (member2)
		store = fy_assoc(ctx->gb, store, member2,
				 fy_gb_internalize(ctx->gb, log2));
	fyai_error_check(ctx, fy_is_valid(store), err_out,
			 "settings: cannot build the store of branch '%s'",
			 fyai_ctx_branch(ctx));
	ctx->branch_store = store;
	fyai_branch_op_set(ctx, FYAI_BRANCH_OP_SETTINGS, NULL);
	return fyai_publish_state(ctx);
err_out:
	return -1;
}

fy_generic fyai_settings_log(struct fyai_ctx *ctx, const char *member)
{
	struct fyai_branch prev;

	if (!fyai_branch_decode(ctx->branch_prev, &prev))
		return fy_seq_empty;
	return fy_get(prev.store, member, fy_seq_empty);
}

/* The entry of a log for @c, built in @gb. */
static fy_generic settings_entry(struct fyai_ctx *ctx,
				 struct fy_generic_builder *gb,
				 const struct settings_change *c,
				 const char *id, const char *explanation,
				 const char *status)
{
	fy_generic entry;

	entry = fy_mapping(gb,
		"name", id,
		"status", status,
		"access", fyai_model_access_name(c->access),
		"paths", c->paths,
		"changes", c->changes,
		"trial", c->trial,
		"before", c->before,
		"after", c->after,
		"diff", c->unified ? c->unified : "",
		"explanation", explanation,
		"origin", fyai_ctx_branch(ctx),
		"time", (long long)fyai_branch_timestamp());
	if (c->mark_id)
		entry = fy_assoc(gb, entry, "of", fy_mapping(gb,
			"id", c->mark_id, "status", c->mark_status));
	return entry;
}

/* The entry @id of @log, or fy_invalid. */
static fy_generic settings_log_find(fy_generic log, const char *id)
{
	fy_generic item;

	fy_foreach(item, log)
		if (fy_equal(fy_get(item, "name", fy_invalid), id))
			return item;
	return fy_invalid;
}

/* @log with the status of entry @id replaced by @status. */
static fy_generic settings_log_status(struct fy_generic_builder *gb,
				      fy_generic log, const char *id,
				      const char *status)
{
	fy_generic out, item;

	out = fy_sequence(gb);
	fy_foreach(item, log) {
		if (fy_equal(fy_get(item, "name", fy_invalid), id))
			item = fy_assoc(gb, item, "status", status);
		out = fy_append(gb, out, item);
	}
	return out;
}

/*
 * Apply @c: the session layer first, then the branch configuration with the
 * entry of the change log in one publish. Returns 0, or -1 with the cause
 * reported.
 */
static int settings_apply(struct fyai_ctx *ctx, struct fy_generic_builder *gb,
			  struct settings_change *c, const char *explanation,
			  const char **idp, const char *member2,
			  fy_generic log2)
{
	fy_generic log;
	const char *id;

	log = fyai_settings_log(ctx, "config_changes");
	id = settings_next_id(gb, log, 'c');
	if (c->mark_id)
		log = settings_log_status(gb, log, c->mark_id, c->mark_status);
	if (fy_is_valid(c->session) &&
	    fyai_config_session_layer_adopt(ctx, c->session))
		return -1;
	if (fy_is_valid(c->stored))
		ctx->arena_config = c->stored;
	log = settings_log_append(gb, log, settings_entry(ctx, gb, c, id,
		explanation, fy_is_valid(c->stored) ? "applied" : "session"));
	if (settings_publish(ctx, "config_changes", log, member2, log2))
		return -1;
	if (fy_is_valid(c->stored) && fyai_config_rederive(ctx))
		return -1;
	*idp = id;
	return 0;
}

/* Keep @c as a proposal of this branch for the user to approve later. */
static int settings_propose(struct fyai_ctx *ctx, struct fy_generic_builder *gb,
			    struct settings_change *c, const char *explanation,
			    const char **idp)
{
	fy_generic log;
	const char *id;

	log = fyai_settings_log(ctx, "config_proposals");
	id = settings_next_id(gb, log, 'p');
	log = settings_log_append(gb, log, settings_entry(ctx, gb, c, id,
		explanation, "pending"));
	if (settings_publish(ctx, "config_proposals", log, NULL, fy_invalid))
		return -1;
	*idp = id;
	return 0;
}

/* The answer of the review panel. */
struct settings_review {
	bool done;
	bool given;
	unsigned int selected;
	char *other;
};

static void settings_review_done(void *user,
				 const struct fyai_ask_reply *replies, size_t n)
{
	struct settings_review *r = user;

	r->done = true;
	if (!replies || !n)
		return;
	r->given = true;
	r->selected = replies[0].selected;
	if (replies[0].other)
		r->other = strdup(replies[0].other);
}

/*
 * Put @c to the user in the review panel: the proposal that the model wrote
 * and the diff that fyai made, under headings of their own. Returns 1 when
 * the user accepts, 0 when the user rejects, with the typed reply in
 * *@replyp, and -1 when the panel could not be shown.
 */
static fy_generic settings_review_questions(struct fy_generic_builder *gb,
					    const struct settings_change *c,
					    const char *explanation)
{
	return fy_sequence(gb, fy_mapping(gb,
		"id", "settings",
		"header", "Settings",
		"question", fy_sprintfa("The model presents a change of %zu "
			"key%s (%s). Apply it?", fy_len(c->paths),
			fy_len(c->paths) == 1 ? "" : "s",
			fyai_model_access_name(c->access)),
		"multi_select", false,
		/* Reject comes first and is under the cursor: a stray Enter,
		 * or one pasted with a reply, must not apply a change. */
		"options", fy_sequence(gb,
			fy_mapping(gb, "id", "reject", "label", "Reject",
				   "description", "Leave the configuration as "
				   "it is.", "preview", ""),
			fy_mapping(gb, "id", "accept", "label", "Accept",
				   "description", "Apply the change that the "
				   "diff shows.", "preview", "")),
		"proposal", explanation,
		"diff", c->diff));
}

/*
 * The decision of the review panel: 1 when the user accepts, 0 when the
 * user rejects, with the typed reply in *@replyp when there is one. No
 * answer at all, as from Escape, rejects.
 */
static int settings_review_answer(const struct fyai_ask_reply *replies,
				  size_t n, char **replyp)
{
	*replyp = NULL;
	if (!replies || !n)
		return 0;
	if (replies[0].other && *replies[0].other) {
		*replyp = strdup(replies[0].other);
		return 0;
	}
	return (replies[0].selected & 2u) ? 1 : 0;
}

static int settings_review(struct fyai_ctx *ctx, struct fy_generic_builder *gb,
			   const struct settings_change *c,
			   const char *explanation, char **replyp)
{
	struct settings_review r = { 0 };
	fy_generic questions;

	*replyp = NULL;
	questions = settings_review_questions(gb, c, explanation);
	fyai_error_check(ctx, fy_is_valid(questions), err_out,
			 "settings: cannot build the review of the change");
	if (fyai_ui_ask(ctx, questions, NULL, settings_review_done, &r))
		return -1;
	while (!r.done)
		if (fyai_event_loop_step(fyai_ctx_loop(ctx), -1) < 0)
			break;
	if (!r.done) {
		fyai_ui_ask_withdraw(ctx, &r);
		fyai_error(ctx, "settings: the event loop stopped during the "
			   "review of a change");
		return -1;
	}
	if (r.other && *r.other) {
		*replyp = r.other;
		return 0;
	}
	free(r.other);
	return r.given && (r.selected & 2u) ? 1 : 0;
err_out:
	return -1;
}

static void settings_walk_init(struct settings_walk *w, struct fyai_ctx *ctx,
			       struct fy_generic_builder *gb)
{
	memset(w, 0, sizeof(*w));
	w->ctx = ctx;
	w->gb = gb;
	w->hidden = fy_sequence(gb);
	w->keys = fy_sequence(gb);
}

/*
 * Check the pending proposal @id again over the configuration in force and
 * make its diff. The configuration may have changed since the model
 * presented it, so the diff is always made now.
 */
static int settings_proposal_prepare(struct settings_walk *w, const char *id,
				     struct settings_change *c,
				     const char **explanationp)
{
	fy_generic entry, of;
	char why[1024];

	memset(c, 0, sizeof(*c));
	entry = settings_log_find(fyai_settings_log(w->ctx,
					"config_proposals"), id);
	fyai_error_check(w->ctx, fy_is_mapping(entry), err_out,
			 "no proposal '%s' on branch '%s'", id,
			 fyai_ctx_branch(w->ctx));
	fyai_error_check(w->ctx, fy_equal(fy_get(entry, "status", fy_invalid),
					  "pending"), err_out,
			 "proposal '%s' is %s, not pending", id,
			 fy_get(entry, "status", "?"));
	c->trial = fy_get(entry, "trial", false);
	*explanationp = fy_gb_intern_string(w->gb,
					    fy_get(entry, "explanation", ""));
	of = fy_get(entry, "of", fy_invalid);
	if (fy_is_mapping(of)) {
		c->mark_id = fy_gb_intern_string(w->gb, fy_get(of, "id", ""));
		c->mark_status = fy_gb_intern_string(w->gb,
						     fy_get(of, "status", ""));
	}
	if (settings_change_normalize(w, fy_get(entry, "changes", fy_invalid),
				      c, why, sizeof(why)) ||
	    settings_change_build(w, c, why, sizeof(why))) {
		fyai_error(w->ctx, "proposal '%s' cannot be applied: %s", id,
			   why);
		return -1;
	}
	return 0;
err_out:
	return -1;
}

fy_generic fyai_settings_proposal_show(struct fyai_ctx *ctx,
				       struct fy_generic_builder *gb,
				       const char *id)
{
	struct settings_walk w;
	struct settings_change c;
	const char *explanation;

	settings_walk_init(&w, ctx, gb);
	if (settings_proposal_prepare(&w, id, &c, &explanation))
		return fy_invalid;
	return fy_mapping(gb, "id", id, "explanation", explanation,
			  "diff", c.diff);
}

/*
 * Tell the model how the user decided proposal @id: an event that the next
 * turn reads, as the answer of a background question is.
 */
static void settings_proposal_event(struct fyai_ctx *ctx,
				    struct fy_generic_builder *gb,
				    const char *id, fy_generic result)
{
	const char *json;

	json = emit_json_string(gb, result);
	if (!json || fyai_event_injectf(ctx, "[config '%s' %s]\n%s", id,
					fy_get(result, "status", "decided"),
					json))
		fyai_warning(ctx, "the model is not told that proposal '%s' "
			     "was decided", id);
}

int fyai_settings_proposal_decide(struct fyai_ctx *ctx,
				  struct fy_generic_builder *gb,
				  const char *id, bool approve, bool notify,
				  fy_generic *resultp)
{
	struct settings_walk w;
	struct settings_change c;
	fy_generic proposals;
	const char *explanation, *cid = NULL;

	settings_walk_init(&w, ctx, gb);
	fyai_error_check(ctx, ctx->gb, err_out, "no arena; run fyai init");
	if (settings_proposal_prepare(&w, id, &c, &explanation))
		return -1;
	proposals = fyai_settings_log(ctx, "config_proposals");
	if (!approve) {
		proposals = settings_log_status(gb, proposals, id, "rejected");
		if (settings_publish(ctx, "config_proposals", proposals, NULL,
				     fy_invalid))
			return -1;
		*resultp = fy_mapping(gb, "id", id, "status", "rejected");
		if (notify)
			settings_proposal_event(ctx, gb, id, *resultp);
		return 0;
	}
	proposals = settings_log_status(gb, proposals, id, "approved");
	if (settings_apply(ctx, gb, &c, explanation, &cid,
			   "config_proposals", proposals))
		return -1;
	*resultp = fy_mapping(gb, "id", id, "status", "approved",
			      "change", cid, "diff", c.diff);
	if (notify)
		settings_proposal_event(ctx, gb, id, fy_mapping(gb,
			"id", id, "status", "approved", "change", cid,
			"diff", c.unified));
	return 0;
err_out:
	return -1;
}

/*
 * Apply, review or propose the checked change @c that the model presents:
 * fyai applies a change of write keys unasked only when the setting and the
 * shell both allow it; any other change goes to the review panel, or waits
 * as a proposal when nobody can review it now.
 */
static fy_generic settings_present(struct settings_walk *w,
				   struct settings_change *c,
				   const char *explanation, bool *okp)
{
	struct fyai_ctx *ctx = w->ctx;
	struct fyai_cfg *cfg = ctx->cfg;
	enum fyai_model_access access;
	const char *id = NULL, *status = "rejected";
	char *reply = NULL;
	fy_generic result;
	int rc;

	*okp = false;
	access = c->access;
	if (access == FYAI_MODEL_WRITE &&
	    (cfg->model_access < FYAI_MODEL_WRITE ||
	     !settings_arena_protected(ctx)))
		access = FYAI_MODEL_REVIEW;

	if (access == FYAI_MODEL_WRITE) {
		rc = settings_apply(ctx, w->gb, c, explanation, &id, NULL,
				    fy_invalid);
		status = "applied";
	} else if (fyai_agent_delegated(ctx) || !fyai_ui_ask_available(ctx)) {
		rc = settings_propose(ctx, w->gb, c, explanation, &id);
		status = "pending";
	} else {
		rc = settings_review(ctx, w->gb, c, explanation, &reply);
		if (rc > 0) {
			rc = settings_apply(ctx, w->gb, c, explanation, &id,
					    NULL, fy_invalid);
			status = "applied";
		}
	}
	if (rc < 0) {
		free(reply);
		return fy_value(w->gb, "settings: the change was not applied");
	}
	result = fy_mapping(w->gb, "status", status, "access",
			    fyai_model_access_name(access), "diff", c->unified);
	if (id)
		result = fy_assoc(w->gb, result, "id", id);
	if (reply) {
		result = fy_assoc(w->gb, result, "reply",
				  fy_value(w->gb, reply));
		free(reply);
	}
	if (!strcmp(status, "pending"))
		result = fy_assoc(w->gb, result, "note", "Nobody can review "
			"the change now. It is kept as a proposal; the user "
			"applies it with `config approve`.");
	*okp = strcmp(status, "rejected") != 0;
	return result;
}

/*
 * Build in @c the change that takes entry @entry of the change log back:
 * each path to its value before the change. A path whose value is no
 * longer the one the change left is a conflict; with @force the other paths
 * are taken back, else nothing is. Returns 0, 1 for a conflict, or -1.
 */
static int settings_revert_build(struct settings_walk *w, fy_generic entry,
				 bool force, struct settings_change *c,
				 fy_generic *conflictsp, char *why,
				 size_t why_size)
{
	struct fyai_ctx *ctx = w->ctx;
	fy_generic before, after, item, cur, out, paths, conflicts, b;
	const char *path;
	bool in_session;
	size_t len;
	int access;

	memset(c, 0, sizeof(*c));
	c->trial = fy_get(entry, "trial", false);
	before = fy_get(entry, "before", fy_invalid);
	after = fy_get(entry, "after", fy_invalid);
	out = fy_sequence(w->gb);
	paths = fy_sequence(w->gb);
	conflicts = fy_sequence(w->gb);
	fy_foreach(item, fy_get(entry, "paths", fy_invalid)) {
		path = fy_gb_intern_string(w->gb, fy_castp(&item, ""));
		in_session = c->trial || fyai_config_session_scoped(path);
		cur = settings_doc_get(w->gb, in_session ?
				       ctx->cfg->config_session :
				       ctx->arena_config, path);
		if (fy_compare(cur, fy_get(after, path, fy_null))) {
			conflicts = fy_append(w->gb, conflicts, path);
			continue;
		}
		b = fy_get(before, path, fy_null);
		out = fy_append(w->gb, out, fy_is_null(b) ?
			fy_mapping(w->gb, "path", path, "delete", true) :
			fy_mapping(w->gb, "path", path, "value", b));
		paths = fy_append(w->gb, paths, path);
	}
	*conflictsp = conflicts;
	if (!fy_empty(conflicts) && !force) {
		len = (size_t)snprintf(why, why_size, "changed since the "
				       "change, so nothing is taken back:");
		fy_foreach(item, conflicts)
			if (len < why_size)
				len += (size_t)snprintf(why + len,
					why_size - len, " %s",
					fy_castp(&item, ""));
		return 1;
	}
	if (fy_empty(out)) {
		snprintf(why, why_size, "every path changed since the change");
		return -1;
	}
	access = fyai_model_access_parse(fy_get(entry, "access", fy_invalid));
	c->access = access < 0 ? FYAI_MODEL_HIDDEN :
		    (enum fyai_model_access)access;
	c->changes = out;
	c->paths = paths;
	c->mark_id = fy_gb_intern_string(w->gb, fy_get(entry, "name", ""));
	c->mark_status = "reverted";
	return settings_change_build(w, c, why, why_size) ? -1 : 0;
}

/* The entry @id of the change log that can be reverted or kept. */
static fy_generic settings_change_entry(struct fyai_ctx *ctx, const char *id)
{
	fy_generic entry;

	entry = settings_log_find(fyai_settings_log(ctx, "config_changes"),
				  id);
	fyai_error_check(ctx, fy_is_mapping(entry), err_out,
			 "no change '%s' on branch '%s'", id,
			 fyai_ctx_branch(ctx));
	fyai_error_check(ctx, fy_any_equal(fy_get(entry, "status",
						  fy_invalid),
					   "applied", "session"), err_out,
			 "change '%s' is %s", id,
			 fy_get(entry, "status", "?"));
	return entry;
err_out:
	return fy_invalid;
}

/* The model takes back one of its own changes of write keys. */
static fy_generic settings_revert_run(struct settings_walk *w,
				      fy_generic args, bool *okp)
{
	struct fyai_ctx *ctx = w->ctx;
	struct settings_change c;
	fy_generic entry, conflicts;
	const char *id = fy_get(args, "id", "");
	char why[1024];
	int rc;

	*okp = false;
	if (ctx->cfg->model_access < FYAI_MODEL_REVIEW)
		return fy_value(w->gb, "settings: model_access allows reads "
				"only");
	entry = settings_log_find(fyai_settings_log(ctx, "config_changes"),
				  id);
	if (!fy_is_mapping(entry) ||
	    !fy_any_equal(fy_get(entry, "status", fy_invalid), "applied",
			  "session"))
		return fy_value(w->gb, fy_sprintfa("settings: no change '%s' "
				"to take back", id));
	if (!fy_equal(fy_get(entry, "access", fy_invalid), "write"))
		return fy_value(w->gb, fy_sprintfa("settings: change %s has "
				"review keys; only the user takes it back",
				id));
	rc = settings_revert_build(w, entry, false, &c, &conflicts, why,
				   sizeof(why));
	if (rc)
		return fy_value(w->gb, fy_sprintfa("settings: %s", why));
	return settings_present(w, &c, fy_sprintfa("Take back change %s.", id),
				okp);
}

int fyai_settings_revert(struct fyai_ctx *ctx, struct fy_generic_builder *gb,
			 const char *id, bool force, fy_generic *resultp)
{
	struct settings_walk w;
	struct settings_change c;
	fy_generic entry, conflicts;
	const char *cid;
	char why[1024];

	settings_walk_init(&w, ctx, gb);
	fyai_error_check(ctx, ctx->gb, err_out, "no arena; run fyai init");
	entry = settings_change_entry(ctx, id);
	if (!fy_is_mapping(entry))
		return -1;
	if (settings_revert_build(&w, entry, force, &c, &conflicts, why,
				  sizeof(why))) {
		fyai_error(ctx, "change '%s' is not taken back: %s", id, why);
		return -1;
	}
	if (settings_apply(ctx, gb, &c, fy_sprintfa("Take back change %s.",
						    id), &cid, NULL,
			   fy_invalid))
		return -1;
	*resultp = fy_mapping(gb, "id", id, "status", "reverted",
			      "change", cid, "conflicts", conflicts,
			      "diff", c.diff);
	return 0;
err_out:
	return -1;
}

int fyai_settings_keep(struct fyai_ctx *ctx, struct fy_generic_builder *gb,
		       const char *id, fy_generic *resultp)
{
	struct settings_walk w;
	struct settings_change c;
	fy_generic entry, after, item, v, out, paths, session, stored0;
	fy_generic session0;
	const char *path, *cid;
	char why[1024];

	settings_walk_init(&w, ctx, gb);
	memset(&c, 0, sizeof(c));
	fyai_error_check(ctx, ctx->gb, err_out, "no arena; run fyai init");
	entry = settings_change_entry(ctx, id);
	if (!fy_is_mapping(entry))
		return -1;
	fyai_error_check(ctx, fy_get(entry, "trial", false), err_out,
			 "change '%s' is not a trial", id);
	/* Each key of stored scope goes to the branch with the value of the
	 * trial, and leaves the session layer. */
	after = fy_get(entry, "after", fy_invalid);
	out = fy_sequence(gb);
	paths = fy_sequence(gb);
	session = fy_is_mapping(ctx->cfg->config_session) ?
		  ctx->cfg->config_session : fy_map_empty;
	fy_foreach(item, fy_get(entry, "paths", fy_invalid)) {
		path = fy_gb_intern_string(gb, fy_castp(&item, ""));
		if (fyai_config_session_scoped(path))
			continue;
		v = fy_get(after, path, fy_null);
		out = fy_append(gb, out, fy_is_null(v) ?
			fy_mapping(gb, "path", path, "delete", true) :
			fy_mapping(gb, "path", path, "value", v));
		paths = fy_append(gb, paths, path);
		session = settings_doc_set(ctx->cfg->gb, session, path,
					   fy_invalid);
	}
	fyai_error_check(ctx, !fy_empty(out), err_out,
			 "change '%s' has no key that a branch stores", id);
	c.changes = out;
	c.paths = paths;
	c.access = FYAI_MODEL_REVIEW;
	c.mark_id = id;
	c.mark_status = "kept";
	if (settings_change_build(&w, &c, why, sizeof(why))) {
		fyai_error(ctx, "change '%s' is not kept: %s", id, why);
		return -1;
	}
	stored0 = fy_is_mapping(ctx->arena_config) ? ctx->arena_config :
		  fy_map_empty;
	session0 = fy_is_mapping(ctx->cfg->config_session) ?
		   ctx->cfg->config_session : fy_map_empty;
	c.session = fy_compare(session, session0) ? session : fy_invalid;
	if ((fy_is_valid(c.session) &&
	     !fyai_config_session_layer_valid(ctx, session)) ||
	    settings_change_diff(&w, &c, stored0, session0)) {
		fyai_error(ctx, "change '%s' is not kept: the session layer "
			   "cannot give up its keys", id);
		return -1;
	}
	if (settings_apply(ctx, gb, &c, fy_sprintfa("Keep change %s.", id),
			   &cid, NULL, fy_invalid))
		return -1;
	*resultp = fy_mapping(gb, "id", id, "status", "kept", "change", cid,
			      "diff", c.diff);
	return 0;
err_out:
	return -1;
}

/* The proposals of this branch, as the model reads them. */
static fy_generic settings_proposals_run(struct settings_walk *w)
{
	fy_generic rows, item;

	rows = fy_sequence(w->gb);
	fy_foreach(item, fyai_settings_log(w->ctx, "config_proposals"))
		rows = fy_append(w->gb, rows, fy_mapping(w->gb,
			"id", fy_get(item, "name", ""),
			"status", fy_get(item, "status", ""),
			"paths", fy_get(item, "paths", fy_invalid),
			"changes", fy_get(item, "changes", fy_invalid)));
	return fy_mapping(w->gb, "proposals", rows);
}

/* A pending proposal that waits for the answer of the review panel. */
struct fyai_settings_review {
	struct fyai_ctx *ctx;
	struct fy_generic_builder *gb;
	struct settings_change c;
	const char *id;
	const char *explanation;
	fy_generic questions;
};

struct fyai_settings_review *
fyai_settings_review_open(struct fyai_ctx *ctx, struct fy_generic_builder *gb,
			  const char *id)
{
	struct fyai_settings_review *r;
	struct settings_walk w;

	fyai_error_check(ctx, ctx->gb, err_out, "no arena; run fyai init");
	r = calloc(1, sizeof(*r));
	fyai_error_check(ctx, r, err_out,
			 "cannot keep the review of proposal '%s'", id);
	settings_walk_init(&w, ctx, gb);
	r->ctx = ctx;
	r->gb = gb;
	r->id = fy_gb_intern_string(gb, id);
	if (!r->id ||
	    settings_proposal_prepare(&w, id, &r->c, &r->explanation)) {
		free(r);
		return NULL;
	}
	r->questions = settings_review_questions(gb, &r->c, r->explanation);
	if (!fy_is_valid(r->questions)) {
		fyai_error(ctx, "cannot build the review of proposal '%s'", id);
		free(r);
		return NULL;
	}
	return r;
err_out:
	return NULL;
}

fy_generic fyai_settings_review_questions(struct fyai_settings_review *r)
{
	return r->questions;
}

int fyai_settings_review_apply(struct fyai_settings_review *r,
			       const struct fyai_ask_reply *replies, size_t n,
			       bool notify, fy_generic *resultp)
{
	struct fyai_ctx *ctx = r->ctx;
	struct fy_generic_builder *gb = r->gb;
	fy_generic proposals, event;
	const char *cid = NULL;
	char *reply = NULL;

	/* No panel answers a verb: the user approved it by naming it. */
	if (replies && !settings_review_answer(replies, n, &reply)) {
		*resultp = fy_mapping(gb, "id", r->id, "status", "pending");
		if (reply)
			*resultp = fy_assoc(gb, *resultp, "reply",
					    fy_value(gb, reply));
		free(reply);
		return 0;
	}
	proposals = settings_log_status(gb, fyai_settings_log(ctx,
					"config_proposals"), r->id, "approved");
	if (settings_apply(ctx, gb, &r->c, r->explanation, &cid,
			   "config_proposals", proposals))
		return -1;
	*resultp = fy_mapping(gb, "id", r->id, "status", "approved",
			      "change", cid, "diff", r->c.diff);
	if (notify) {
		event = fy_mapping(gb, "id", r->id, "status", "approved",
				   "change", cid, "diff", r->c.unified);
		settings_proposal_event(ctx, gb, r->id, event);
	}
	return 0;
}

void fyai_settings_review_free(struct fyai_settings_review *r)
{
	free(r);
}

/* Present, review, and apply a change set of the model. */
static fy_generic settings_change_run(struct settings_walk *w, fy_generic args,
				      bool *okp)
{
	struct fyai_ctx *ctx = w->ctx;
	struct fyai_cfg *cfg = ctx->cfg;
	struct settings_change c;
	const char *explanation;
	char why[1024];

	*okp = false;
	memset(&c, 0, sizeof(c));
	if (!ctx->gb)
		return fy_value(w->gb, "settings: no arena; the change cannot "
				"be kept");
	if (cfg->model_access < FYAI_MODEL_REVIEW)
		return fy_value(w->gb, "settings: model_access allows reads "
				"only");
	explanation = fy_get(args, "explanation", "");
	if (strlen(explanation) > SETTINGS_EXPLANATION_MAX)
		return fy_value(w->gb, fy_sprintfa("settings: the explanation "
				"is longer than %d bytes",
				SETTINGS_EXPLANATION_MAX));
	explanation = settings_clean(w->gb, explanation);
	c.trial = fy_get(args, "trial", false);
	if (!explanation ||
	    settings_change_normalize(w, fy_get(args, "changes", fy_invalid),
				      &c, why, sizeof(why)) ||
	    settings_change_build(w, &c, why, sizeof(why)))
		return fy_value(w->gb, fy_sprintfa("settings: %s",
				explanation ? why : "the explanation could "
				"not be kept"));

	return settings_present(w, &c, explanation, okp);
}

static fy_generic settings_run_generic(struct fyai_ctx *ctx, fy_generic args,
				       bool *okp)
{
	struct settings_walk w;
	fy_generic action, result, node, value;
	const char *path, *layer;

	memset(&w, 0, sizeof(w));
	w.ctx = ctx;
	w.gb = fyai_ctx_transient_gb(ctx);
	w.hidden = fy_sequence(w.gb);
	w.keys = fy_sequence(w.gb);
	*okp = false;

	if (ctx->cfg->model_access < 0)
		return fy_value(w.gb, "settings: model_access is none");
	action = fy_get(args, "action", fy_invalid);
	path = fy_gb_intern_string(w.gb, fy_get(args, "path", ""));
	if (!path)
		return fy_value(w.gb, "settings: the path could not be kept");
	if (!settings_path_valid(path))
		return fy_value(w.gb, fy_sprintfa("settings: '%s' is not a "
				"slash path of the configuration", path));
	if (*path && fyai_config_model_access(path) == FYAI_MODEL_HIDDEN)
		return fy_value(w.gb, fy_sprintfa("settings: %s is hidden "
				"from the model", path));
	node = *path ? fyai_config_schema_node(path) :
	       fyai_config_schema(NULL);

	if (fy_any_equal(action, "change", "revert")) {
		result = fy_equal(action, "change") ?
			 settings_change_run(&w, args, okp) :
			 settings_revert_run(&w, args, okp);
		if (!fy_is_mapping(result))
			return result;
		result = fy_assoc(w.gb, result, "arena_protected",
				  settings_arena_protected(ctx));
		return result;
	} else if (fy_equal(action, "proposals")) {
		result = settings_proposals_run(&w);
	} else if (fy_equal(action, "search")) {
		if (!fy_is_mapping(node))
			return fy_value(w.gb, fy_sprintfa("settings: %s is not "
					"a key of the schema", path));
		result = settings_search(&w, path, node,
					 fy_get(args, "query", ""),
					 fy_get(args, "limit", 0LL));
		if (!fy_is_mapping(result))
			return result;
	} else if (fy_equal(action, "describe")) {
		result = settings_describe(&w, path);
	} else if (fy_equal(action, "get")) {
		value = settings_redact(&w, path,
					settings_value(&w, path, &layer), 0);
		result = fy_mapping(w.gb, "path", path,
			"access", fyai_model_access_name(
					fyai_config_model_access(path)),
			"layer", layer,
			"value", fy_is_valid(value) ? value : fy_null);
	} else if (fy_equal(action, "list")) {
		if (!fy_is_mapping(node))
			return fy_value(w.gb, fy_sprintfa("settings: %s is not "
					"a key of the schema", path));
		w.changed = fy_get(args, "changed", false);
		settings_list_walk(&w, path, node, 0);
		result = fy_mapping(w.gb, "path", path, "keys", w.keys);
		if (w.count >= SETTINGS_LIST_MAX)
			result = fy_assoc(w.gb, result, "truncated", true);
	} else {
		return fy_value(w.gb, "settings: action must be search, "
				"describe, get, list, change, revert or "
				"proposals");
	}
	if (!fy_empty(w.hidden))
		result = fy_assoc(w.gb, result, "hidden", w.hidden);
	result = fy_assoc(w.gb, result, "arena_protected",
			  settings_arena_protected(ctx));
	if (!fy_is_valid(result))
		return fy_value(w.gb,
				"settings: the answer could not be built");
	*okp = true;
	return result;
}

/*
 * The result of the tool is text, as every function result is: a structure
 * goes to the model as its compact JSON, which the formatter reads back for
 * the user.
 */
static fy_generic settings_run(struct fyai_ctx *ctx, fy_generic args,
			       bool *okp)
{
	struct fy_generic_builder *gb = fyai_ctx_transient_gb(ctx);
	fy_generic result;
	const char *text;

	result = settings_run_generic(ctx, args, okp);
	if (!fy_is_mapping(result))
		return result;
	text = emit_json_string(gb, result);
	if (!text) {
		*okp = false;
		return fy_value(gb, "settings: the answer could not be "
				"written");
	}
	return fy_value(gb, text);
}

/* The tool is not offered when model_access is none. */
static fy_generic settings_describe_tool(struct fyai_ctx *ctx,
					 struct fy_generic_builder *gb,
					 fy_generic tool)
{
	(void)gb;
	return ctx->cfg->model_access < 0 ? fy_invalid : tool;
}

/* The bound on the characters of a value or a query in a row. */
#define SETTINGS_SPAN_MAX	60
/* The bound on the keys that a result shows the user. */
#define SETTINGS_ROWS_MAX	8

/*
 * @text as a code span of one row: control bytes and line breaks become
 * blanks, a long text ends in an ellipsis, and the span is fenced with more
 * backticks than any run in it. The model or a configuration wrote it.
 */
static const char *settings_span(struct fy_generic_builder *gb,
				 const char *text)
{
	char buf[SETTINGS_SPAN_MAX * 4 + 8];
	const char *fence;
	size_t i, n, chars;

	for (i = n = chars = 0; text[i] && n < sizeof(buf) - 8; i++) {
		if (((unsigned char)text[i] & 0xc0) != 0x80 &&
		    ++chars > SETTINGS_SPAN_MAX)
			break;
		buf[n++] = (unsigned char)text[i] < 0x20 ||
			   (unsigned char)text[i] == 0x7f ? ' ' : text[i];
	}
	if (text[i]) {
		memcpy(buf + n, "\u2026", strlen("\u2026"));
		n += strlen("\u2026");
	}
	buf[n] = '\0';
	fence = settings_fence(gb, buf);
	if (!fence)
		return "`?`";
	/* A one-backtick span suffices unless the text holds a backtick. */
	if (!strchr(buf, '`'))
		fence = "`";
	return fy_gb_intern_string(gb, fy_sprintfa("%s%s%s%s%s", fence,
		buf[0] == '`' ? " " : "", buf,
		n && buf[n - 1] == '`' ? " " : "", fence));
}

/* A value as a span: a string as it is, any other value as flow YAML. */
static const char *settings_value_span(struct fy_generic_builder *gb,
				       fy_generic v)
{
	fy_generic text;

	if (fy_is_string(v))
		return settings_span(gb, fy_castp(&v, ""));
	text = fy_emit(gb, v, FYOPEF_DISABLE_DIRECTORY | FYOPEF_MODE_YAML_1_2 |
		       FYOPEF_STYLE_ONELINE | FYOPEF_WIDTH_INF |
		       FYOPEF_NO_ENDING_NEWLINE, NULL);
	return settings_span(gb, fy_is_string(text) ? fy_castp(&text, "") :
			     "?");
}

static void settings_head(struct fyai_ctx *ctx, FILE *mf,
			  struct fy_generic_builder *gb, fy_generic args,
			  int preview_lines, struct fyai_md_blocks *blocks)
{
	fy_generic action = fy_get(args, "action", fy_invalid);
	fy_generic changes = fy_get(args, "changes", fy_invalid);
	const char *path = fy_get(args, "path", "");
	const char *query = fy_get(args, "query", "");
	const char *id = fy_get(args, "id", "");
	const char *first;

	(void)ctx;
	(void)preview_lines;
	(void)blocks;
	/* The model wrote the path: one that is not valid is not shown. */
	if (!settings_path_valid(path))
		path = "?";
	if (fy_equal(action, "search")) {
		fprintf(mf, "**settings** search %s", settings_span(gb, query));
		if (*path)
			fprintf(mf, " in `%s`", path);
	} else if (fy_equal(action, "change")) {
		first = fy_get(fy_get_at(changes, 0, fy_invalid), "path", "");
		fprintf(mf, "**settings** change `%s`",
			settings_path_valid(first) && *first ? first : "?");
		if (fy_len(changes) > 1)
			fprintf(mf, " (+%zu more)", fy_len(changes) - 1);
		if (fy_get(args, "trial", false))
			fprintf(mf, " \u00b7 trial");
	} else if (fy_equal(action, "revert")) {
		fprintf(mf, "**settings** revert %s", settings_span(gb, id));
	} else if (fy_equal(action, "proposals")) {
		fprintf(mf, "**settings** proposals");
	} else {
		fprintf(mf, "**settings** %s `%s`",
			fy_any_equal(action, "describe", "get", "list") ?
				fy_castp(&action, "") : "?",
			*path ? path : "config");
	}
	fprintf(mf, "\n\n");
}

/* A row for each key of @rows, at most a bound, with what follows. */
static void settings_format_keys(FILE *mf, struct fy_generic_builder *gb,
				 fy_generic rows, bool values)
{
	fy_generic row;
	size_t n = 0;

	fy_foreach(row, rows) {
		if (n++ == SETTINGS_ROWS_MAX)
			break;
		fprintf(mf, "- %s \u00b7 %s", settings_span(gb,
			fy_get(row, "key", "")), fy_get(row, "access", ""));
		if (values)
			fprintf(mf, " \u00b7 %s", settings_value_span(gb,
				fy_get(row, "value", fy_null)));
		else
			fprintf(mf, " \u2014 %s", settings_span(gb,
				fy_get(row, "summary", "")));
		fprintf(mf, "\n");
	}
	if (fy_len(rows) > SETTINGS_ROWS_MAX)
		fprintf(mf, "- _%zu more_\n", fy_len(rows) - SETTINGS_ROWS_MAX);
	if (!n)
		fprintf(mf, "_No key._\n");
}

/*
 * The result of a call for the user: short rows for the reads, and for a
 * change the outcome and the whole diff that fyai made, so no change is
 * silent. The model gets the result as it is.
 */
static char *settings_format(struct fyai_ctx *ctx,
			     struct fy_generic_builder *gb, fy_generic args,
			     const char *result)
{
	fy_generic data, action, v;
	const char *status, *diff, *block;
	char *out = NULL;
	size_t len = 0;
	FILE *mf;

	(void)ctx;
	data = parse_json_string(gb, result);
	if (!fy_is_mapping(data))
		return NULL;
	action = fy_get(args, "action", fy_invalid);
	mf = open_memstream(&out, &len);
	if (!mf)
		return NULL;
	if (fy_equal(action, "search")) {
		fprintf(mf, "%lld found\n\n", fy_get(data, "found", 0LL));
		settings_format_keys(mf, gb, fy_get(data, "keys", fy_invalid),
				     false);
	} else if (fy_equal(action, "list")) {
		settings_format_keys(mf, gb, fy_get(data, "keys", fy_invalid),
				     true);
	} else if (fy_any_equal(action, "describe", "get")) {
		fprintf(mf, "%s \u00b7 %s", settings_span(gb,
			fy_get(data, "path", "")), fy_get(data, "access", ""));
		if (fy_is_string(fy_get(data, "scope", fy_invalid)))
			fprintf(mf, " \u00b7 %s", fy_get(data, "scope", ""));
		v = fy_get(data, "value", fy_invalid);
		if (fy_is_valid(v))
			fprintf(mf, " \u00b7 %s (%s)",
				settings_value_span(gb, v),
				fy_get(data, "layer", "?"));
		fprintf(mf, "\n");
	} else if (fy_any_equal(action, "change", "revert")) {
		status = fy_get(data, "status", "");
		if (!strcmp(status, "applied"))
			fprintf(mf, "**%s** as change %s\n",
				fy_equal(action, "revert") ? "Taken back" :
				"Applied",
				settings_span(gb, fy_get(data, "id", "")));
		else if (!strcmp(status, "pending"))
			fprintf(mf, "**Waits** as proposal %s for `config "
				"approve`\n", settings_span(gb,
						fy_get(data, "id", "")));
		else
			fprintf(mf, "**Rejected**\n");
		if (fy_is_string(fy_get(data, "reply", fy_invalid)))
			fprintf(mf, "\nThe user replied %s\n", settings_span(gb,
				fy_get(data, "reply", "")));
		diff = fy_get(data, "diff", "");
		block = *diff ? settings_diff_block(gb, diff) : NULL;
		if (block)
			fprintf(mf, "\n%s", block);
	} else if (fy_equal(action, "proposals")) {
		fy_foreach(v, fy_get(data, "proposals", fy_invalid))
			fprintf(mf, "- %s \u00b7 %s\n", settings_span(gb,
				fy_get(v, "id", "")), fy_get(v, "status", ""));
		if (fy_empty(fy_get(data, "proposals", fy_seq_empty)))
			fprintf(mf, "_No proposal._\n");
	} else {
		fclose(mf);
		free(out);
		return NULL;
	}
	if (fclose(mf)) {
		free(out);
		return NULL;
	}
	return out;
}

const struct fyai_tool_def fyai_settings_defs[] = {
	{ .name = "settings", .run = settings_run, .head = settings_head,
	  .format_result = settings_format,
	  .describe = settings_describe_tool,
	  .flags = FYAI_TOOL_PARENT | FYAI_TOOL_WHOLE_RESULT },
};
const size_t fyai_settings_defs_count = ARRAY_SIZE(fyai_settings_defs);
