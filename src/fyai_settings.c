/*
 * fyai_settings.c - the settings tool: the model reads the configuration
 *
 * SPDX-License-Identifier: MIT
 *
 * The model asks; fyai answers from the merged configuration by the access
 * that the schema states for each key (x-fyai-model, see
 * doc/declarative-state.md). A hidden key is left out of every answer and
 * named under `hidden`. Nothing here writes state: a change of the
 * configuration is presented by the model and applied by fyai, never written
 * by the model.
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fyai.h"
#include "fyai_config.h"
#include "fyai_tool_registry.h"
#include "utils.h"

#define FYAI_MODULE FYAIEM_CONFIG

/* The bound on the depth of a walk of the schema or of a value. */
#define SETTINGS_DEPTH_MAX	64
/* The bound on the keys that one list gives. */
#define SETTINGS_LIST_MAX	100
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
	bool changed;		/* list only keys that differ from the default */
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
		return fy_get(fyai_config_schema_node(path), "default",
			      fy_invalid);
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

static fy_generic settings_run(struct fyai_ctx *ctx, fy_generic args,
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

	if (fy_equal(action, "search")) {
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
				"describe, get or list");
	}
	if (!fy_empty(w.hidden))
		result = fy_assoc(w.gb, result, "hidden", w.hidden);
	result = fy_assoc(w.gb, result, "arena_protected",
			  settings_arena_protected(ctx));
	if (!fy_is_valid(result))
		return fy_value(w.gb, "settings: the answer could not be built");
	*okp = true;
	return result;
}

/* The tool is not offered when model_access is none. */
static fy_generic settings_describe_tool(struct fyai_ctx *ctx,
					 struct fy_generic_builder *gb,
					 fy_generic tool)
{
	(void)gb;
	return ctx->cfg->model_access < 0 ? fy_invalid : tool;
}

static void settings_head(struct fyai_ctx *ctx, FILE *mf,
			  struct fy_generic_builder *gb, fy_generic args,
			  int preview_lines, struct fyai_md_blocks *blocks)
{
	fy_generic action = fy_get(args, "action", fy_invalid);
	const char *path = fy_get(args, "path", "");

	(void)ctx;
	(void)gb;
	(void)preview_lines;
	(void)blocks;
	/* The model wrote the path: one that is not valid is not shown. */
	if (!settings_path_valid(path))
		path = "?";
	fprintf(mf, "**settings** %s `%s`\n\n",
		fy_any_equal(action, "search", "describe", "get", "list") ?
			fy_castp(&action, "") : "?",
		*path ? path : "config");
}

const struct fyai_tool_def fyai_settings_defs[] = {
	{ .name = "settings", .run = settings_run, .head = settings_head,
	  .describe = settings_describe_tool, .flags = FYAI_TOOL_PARENT },
};
const size_t fyai_settings_defs_count = ARRAY_SIZE(fyai_settings_defs);
