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

/* @doc with @path set to @value, or removed for fy_invalid. */
static fy_generic settings_doc_set(struct fy_generic_builder *gb,
				   fy_generic doc, const char *path,
				   fy_generic value)
{
	if (fy_is_valid(value))
		return fy_set_at_pathstr(gb, doc, path,
					 fy_gb_internalize(gb, value));
	if (!fy_is_valid(fy_get_at_pathstr(gb, doc, path)))
		return doc;
	return fy_delete_at_pathstr(gb, doc, path);
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
	char *part, fence[64];
	size_t added = 0, removed = 0, run, longest = 0;
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
	for (p = c->unified; *p; p++) {
		for (run = 0; p[run] == '`'; run++)
			;
		if (run > longest)
			longest = run;
		if (run)
			p += run - 1;
	}
	if (longest >= sizeof(fence) - 1)
		goto out;
	memset(fence, '`', longest < 3 ? 3 : longest + 1);
	fence[longest < 3 ? 3 : longest + 1] = '\0';
	scope = c->trial ? "this session only, as a trial" :
		fy_is_valid(c->stored) && fy_is_valid(c->session) ?
			"the branch configuration and this session" :
		fy_is_valid(c->stored) ? "the branch configuration" :
			"this session";
	body = settings_diff_body(w->gb, c->unified);
	if (!body)
		goto out;
	c->diff = fy_gb_intern_string(w->gb, fy_sprintfa(
		"**%zu key%s \u00b7 +%zu \u2212%zu lines \u00b7 %s**\n\n"
		"%sdiff\n%s%s\n",
		fy_len(c->paths), fy_len(c->paths) == 1 ? "" : "s",
		added, removed, scope, fence, body, fence));
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
	return fy_mapping(gb,
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
	fy_generic entry;
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

int fyai_settings_proposal_decide(struct fyai_ctx *ctx,
				  struct fy_generic_builder *gb,
				  const char *id, bool approve,
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
		return 0;
	}
	proposals = settings_log_status(gb, proposals, id, "approved");
	if (settings_apply(ctx, gb, &c, explanation, &cid,
			   "config_proposals", proposals))
		return -1;
	*resultp = fy_mapping(gb, "id", id, "status", "approved",
			      "change", cid, "diff", c.diff);
	return 0;
err_out:
	return -1;
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
			       fy_generic *resultp)
{
	struct fyai_ctx *ctx = r->ctx;
	struct fy_generic_builder *gb = r->gb;
	fy_generic proposals;
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
	enum fyai_model_access access;
	const char *explanation, *id, *status;
	char why[1024], *reply = NULL;
	fy_generic result;
	int rc;

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

	/* A change of a write key is reviewed unless both the setting and
	 * the shell allow fyai to apply it unasked. */
	access = c.access;
	if (access == FYAI_MODEL_WRITE &&
	    (cfg->model_access < FYAI_MODEL_WRITE ||
	     !settings_arena_protected(ctx)))
		access = FYAI_MODEL_REVIEW;

	if (access == FYAI_MODEL_WRITE) {
		rc = settings_apply(ctx, w->gb, &c, explanation, &id, NULL,
				    fy_invalid);
		status = "applied";
	} else if (fyai_agent_delegated(ctx) || !fyai_ui_ask_available(ctx)) {
		rc = settings_propose(ctx, w->gb, &c, explanation, &id);
		status = "pending";
	} else {
		rc = settings_review(ctx, w->gb, &c, explanation, &reply);
		if (rc > 0) {
			rc = settings_apply(ctx, w->gb, &c, explanation, &id,
					    NULL, fy_invalid);
			status = "applied";
		} else if (!rc) {
			id = NULL;
			status = "rejected";
		}
	}
	if (rc < 0) {
		free(reply);
		return fy_value(w->gb, "settings: the change was not applied");
	}
	result = fy_mapping(w->gb, "status", status, "access",
			    fyai_model_access_name(access), "diff", c.unified);
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

	if (fy_equal(action, "change")) {
		result = settings_change_run(&w, args, okp);
		if (!fy_is_mapping(result))
			return result;
		result = fy_assoc(w.gb, result, "arena_protected",
				  settings_arena_protected(ctx));
		return result;
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
				"describe, get or list");
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
		fy_any_equal(action, "search", "describe", "get", "list",
			     "change") ?
			fy_castp(&action, "") : "?",
		*path ? path : "config");
}

const struct fyai_tool_def fyai_settings_defs[] = {
	{ .name = "settings", .run = settings_run, .head = settings_head,
	  .describe = settings_describe_tool, .flags = FYAI_TOOL_PARENT },
};
const size_t fyai_settings_defs_count = ARRAY_SIZE(fyai_settings_defs);
