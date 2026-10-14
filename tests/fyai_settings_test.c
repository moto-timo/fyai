/*
 * fyai_settings_test.c - the settings tool reads by the access of the schema
 *
 * SPDX-License-Identifier: MIT
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fyai.h"
#include "fyai_config.h"
#include "fyai_tool_spec.h"
#include "fyai_tool_registry.h"
#include "fyai_tools.h"
#include "utils.h"

#include "fyai_test.h"
#include "fyai_test_registry.h"

FYAI_TEST_ENTRY(settings, read, settings_read)
FYAI_TEST_ENTRY(settings, search, settings_search)
FYAI_TEST_ENTRY(settings, offered, settings_offered)
FYAI_TEST_ENTRY(settings, format, settings_format)
FYAI_TEST_ENTRY(settings, catalog, settings_catalog)

static struct fyai_cfg test_cfg;
static struct fyai_ctx test_ctx;

static fy_generic doc(const char *text)
{
	return fy_parse(test_ctx.transient_gb, text,
			FYOPPF_DISABLE_DIRECTORY | FYOPPF_MODE_YAML_1_2 |
			FYOPPF_INPUT_TYPE_STRING, NULL);
}

/*
 * The branch stores the temperature and an MCP token reference; the
 * invocation sets the timeout of a shell call, and the session the theme.
 */
static int settings_setup(void)
{
	struct fy_generic_builder_cfg gb_cfg = {
		.flags = FYGBCF_SCOPE_LEADER | FYGBCF_DEDUP_ENABLED,
	};

	memset(&test_cfg, 0, sizeof(test_cfg));
	memset(&test_ctx, 0, sizeof(test_ctx));
	test_ctx.cfg = &test_cfg;
	test_ctx.transient_gb = fy_generic_builder_create(&gb_cfg);
	if (!test_ctx.transient_gb)
		return 1;
	test_ctx.durable_gb = test_ctx.transient_gb;
	test_ctx.gb = test_ctx.transient_gb;
	test_cfg.gb = test_ctx.transient_gb;
	test_ctx.tools_spec = fy_invalid;
	/* No catalogue in the branch: the embedded snapshot is read. */
	test_ctx.arena_catalog = fy_invalid;
	test_cfg.model_access = FYAI_MODEL_REVIEW;
	test_ctx.arena_config = doc(
		"{temperature: 0.5, "
		"mcp: {enabled: false, auth_token: {type: env, value: TOK}}}");
	test_cfg.config_session = doc("{display: {theme: ember}}");
	test_cfg.config_doc = doc(
		"{temperature: 0.5, shell: {timeout_ms: 5000}, "
		"display: {theme: ember}, "
		"mcp: {enabled: false, auth_token: {type: env, value: TOK}}, "
		"api_key: {type: env, value: KEY}}");
	return 0;
}

static void settings_teardown(void)
{
	fy_generic_builder_destroy(test_ctx.transient_gb);
}

/* The result is the JSON text the model gets; a refusal is plain text. */
static fy_generic run(const char *args, bool *okp)
{
	fy_generic r;

	r = fyai_tool_run_one(&test_ctx, "settings", doc(args), okp);
	if (fy_is_string(r) && *fy_castp(&r, "") == '{')
		r = parse_json_string(test_ctx.transient_gb, fy_castp(&r, ""));
	return r;
}

static bool seq_has(fy_generic seq, const char *s)
{
	fy_generic v;

	fy_foreach(v, seq)
		if (fy_equal(v, s))
			return true;
	return false;
}

static bool keys_has(fy_generic rows, const char *key)
{
	fy_generic row;

	fy_foreach(row, rows)
		if (fy_equal(fy_get(row, "key", fy_invalid), key))
			return true;
	return false;
}

static void check_refused(const char *args, const char *needle)
{
	fy_generic r;
	bool ok = true;

	r = run(args, &ok);
	FYAI_TCHECK(!ok);
	FYAI_TCHECK(fy_is_string(r) && strstr(fy_castp(&r, ""), needle));
}

/* Each answer names the layer of a value and leaves the hidden keys out. */
int settings_read(void)
{
	fy_generic r, v;
	bool ok;

	if (settings_setup())
		return 1;

	r = run("{action: describe, path: temperature}", &ok);
	FYAI_TCHECK(ok && fy_is_mapping(r));
	FYAI_TCHECK(fy_equal(fy_get(r, "access", fy_invalid), "write"));
	FYAI_TCHECK(fy_equal(fy_get(r, "layer", fy_invalid), "branch"));
	FYAI_TCHECK(fy_equal(fy_get(r, "scope", fy_invalid), "stored"));
	FYAI_TCHECK(fy_equal(fy_get(fy_get(r, "schema", fy_invalid), "type",
				    fy_invalid), "number"));
	/* No extension of fyai reaches the model. */
	FYAI_TCHECK(!fy_is_valid(fy_get(fy_get(r, "schema", fy_invalid),
					"x-fyai-model", fy_invalid)));
	FYAI_TCHECK(fy_equal(fy_get(r, "arena_protected", fy_invalid), false));

	r = run("{action: get, path: shell/timeout_ms}", &ok);
	FYAI_TCHECK(ok && fy_equal(fy_get(r, "layer", fy_invalid),
				   "invocation"));
	FYAI_TCHECK(fy_get(r, "value", 0LL) == 5000);

	r = run("{action: get, path: display/theme}", &ok);
	FYAI_TCHECK(ok && fy_equal(fy_get(r, "layer", fy_invalid), "session"));

	r = run("{action: get, path: reasoning/effort}", &ok);
	FYAI_TCHECK(ok && fy_equal(fy_get(r, "layer", fy_invalid), "default"));

	/* A mapping is given without its hidden members. */
	r = run("{action: get, path: mcp}", &ok);
	FYAI_TCHECK(ok);
	v = fy_get(r, "value", fy_invalid);
	FYAI_TCHECK(fy_is_mapping(v));
	FYAI_TCHECK(fy_is_valid(fy_get(v, "enabled", fy_invalid)));
	FYAI_TCHECK(!fy_is_valid(fy_get(v, "auth_token", fy_invalid)));
	FYAI_TCHECK(seq_has(fy_get(r, "hidden", fy_invalid), "mcp/auth_token"));

	r = run("{action: get}", &ok);
	FYAI_TCHECK(ok);
	v = fy_get(r, "value", fy_invalid);
	FYAI_TCHECK(!fy_is_valid(fy_get(v, "api_key", fy_invalid)));
	FYAI_TCHECK(!fy_is_valid(fy_get(fy_get(v, "mcp", fy_invalid),
					"auth_token", fy_invalid)));

	r = run("{action: list, path: shell}", &ok);
	FYAI_TCHECK(ok && keys_has(fy_get(r, "keys", fy_invalid),
				   "shell/shell"));
	r = run("{action: list, changed: true}", &ok);
	FYAI_TCHECK(ok);
	FYAI_TCHECK(keys_has(fy_get(r, "keys", fy_invalid),
			     "shell/timeout_ms"));
	FYAI_TCHECK(!keys_has(fy_get(r, "keys", fy_invalid),
			      "reasoning/effort"));

	check_refused("{action: get, path: api_key}", "hidden");
	check_refused("{action: describe, path: mcp/auth_token/value}",
		      "hidden");
	check_refused("{action: get, path: ../arena}", "not a slash path");
	check_refused("{action: get, path: 'display//theme'}",
		      "not a slash path");
	check_refused("{action: set, path: temperature}", "action must be");

	test_cfg.model_access = -1;
	check_refused("{action: get, path: temperature}", "none");

	settings_teardown();
	return 0;
}

/* A search gives a summary of each key, those it names first. */
int settings_search(void)
{
	fy_generic r, keys, first;
	bool ok;

	if (settings_setup())
		return 1;

	r = run("{action: search, query: 'preview lines'}", &ok);
	FYAI_TCHECK(ok);
	keys = fy_get(r, "keys", fy_invalid);
	first = fy_get_at(keys, 0, fy_invalid);
	FYAI_TCHECK(fy_equal(fy_get(first, "key", fy_invalid),
			     "display/tool_preview_lines"));
	FYAI_TCHECK(fy_equal(fy_get(first, "access", fy_invalid), "review"));
	/* The summary is the first sentence, not the whole description. */
	FYAI_TCHECK(fy_is_string(fy_get(first, "summary", fy_invalid)));

	/* A name of a mapping of names is the segment `*`. */
	r = run("{action: search, query: client id}", &ok);
	FYAI_TCHECK(ok && keys_has(fy_get(r, "keys", fy_invalid),
				   "mcp/servers/*/auth/client/id"));

	/* A hidden key is never found. */
	r = run("{action: search, query: secret}", &ok);
	FYAI_TCHECK(ok);
	FYAI_TCHECK(!keys_has(fy_get(r, "keys", fy_invalid),
			      "mcp/servers/*/auth/client/secret"));
	r = run("{action: search, query: api_key}", &ok);
	FYAI_TCHECK(ok && !keys_has(fy_get(r, "keys", fy_invalid), "api_key"));

	/* The path bounds the search, and the limit the answer. */
	r = run("{action: search, path: agent, query: timeout, limit: 2}", &ok);
	FYAI_TCHECK(ok);
	FYAI_TCHECK(fy_len(fy_get(r, "keys", fy_invalid)) == 2);
	FYAI_TCHECK(fy_get(r, "found", 0LL) > 2);
	FYAI_TCHECK(!keys_has(fy_get(r, "keys", fy_invalid),
			      "shell/timeout_ms"));

	check_refused("{action: search, query: ''}", "needs a query");

	settings_teardown();
	return 0;
}

static bool offers_settings(void)
{
	fy_generic tool;

	test_ctx.tools_spec = fy_invalid;
	fy_foreach(tool, make_tools_filtered(&test_ctx))
		if (fy_equal(fy_get(fy_get(tool, "function", fy_invalid),
				    "name", fy_invalid), "settings"))
			return true;
	return false;
}

/* model_access none offers no settings tool, nor does a sub-agent. */
int settings_offered(void)
{
	if (settings_setup())
		return 1;
	FYAI_TCHECK(offers_settings());
	test_cfg.model_access = -1;
	FYAI_TCHECK(!offers_settings());
	test_cfg.model_access = FYAI_MODEL_REVIEW;
	test_cfg.agent_child = true;
	test_cfg.agent_rpc = true;
	FYAI_TCHECK(!offers_settings());
	check_refused("{action: get, path: temperature}",
		      "only the session of the user");
	settings_teardown();
	return 0;
}

/* The user reads a short result; text the model wrote stays in a span. */
int settings_format(void)
{
	const struct fyai_tool_def *def = fyai_tool_find("settings");
	fy_generic r;
	char *text;
	bool ok;

	if (settings_setup())
		return 1;
	FYAI_TCHECK(def && def->format_result);
	FYAI_TCHECK(fyai_tool_has("settings", FYAI_TOOL_WHOLE_RESULT));
	FYAI_TCHECK(fyai_tool_has("settings", FYAI_TOOL_ROOT_ONLY));

	r = fyai_tool_run_one(&test_ctx, "settings",
			      doc("{action: describe, path: temperature}"),
			      &ok);
	FYAI_TCHECK(ok && fy_is_string(r));
	text = def->format_result(&test_ctx, test_ctx.transient_gb,
				  doc("{action: describe}"), fy_castp(&r, ""));
	FYAI_TCHECK(text && strstr(text, "`temperature`") &&
		    strstr(text, "write") && strstr(text, "(branch)"));
	free(text);

	/* A group shows the defaults of its members. */
	r = fyai_tool_run_one(&test_ctx, "settings",
			      doc("{action: get, path: retry}"), &ok);
	FYAI_TCHECK(ok && strstr(fy_castp(&r, ""), "max_attempts"));

	/* A value with backticks cannot close its span. */
	text = def->format_result(&test_ctx, test_ctx.transient_gb,
		doc("{action: get}"),
		"{\"path\": \"system_prompt\", \"access\": \"review\", "
		"\"layer\": \"branch\", \"value\": \"a ` b `` c\"}");
	FYAI_TCHECK(text && strstr(text, "```a ` b `` c```"));
	free(text);

	/* A change shows its outcome and the diff that fyai made. */
	text = def->format_result(&test_ctx, test_ctx.transient_gb,
		doc("{action: change}"),
		"{\"status\": \"pending\", \"id\": \"p1\", \"diff\": "
		"\"@@ -1 +1 @@\\n-a: 1\\n+a: 2\\n\"}");
	FYAI_TCHECK(text && strstr(text, "**Waits** as proposal `p1`") &&
		    strstr(text, "```diff\n@@ -1 +1 @@\n-a: 1\n+a: 2\n```"));
	free(text);

	settings_teardown();
	return 0;
}

static bool rows_have(fy_generic rows, const char *key, const char *value)
{
	fy_generic row;

	fy_foreach(row, rows)
		if (fy_equal(fy_get(row, key, fy_invalid), value))
			return true;
	return false;
}

/* The catalogue is read: search, get and list; nothing changes it. */
int settings_catalog(void)
{
	const struct fyai_tool_def *def = fyai_tool_find("settings");
	fy_generic r, row, v;
	char *text;
	bool ok;

	if (settings_setup())
		return 1;

	r = run("{document: catalog, action: search, query: opus}", &ok);
	FYAI_TCHECK(ok && fy_get(r, "found", 0LL) >= 1);
	FYAI_TCHECK(rows_have(fy_get(r, "models", fy_invalid), "path",
			      "models/claude-opus-5.5"));
	row = fy_get_at(fy_get(r, "models", fy_invalid), 0, fy_invalid);
	FYAI_TCHECK(fy_len(fy_get(row, "providers", fy_seq_empty)) >= 1);

	/* A word may name a capability or a provider instead. */
	r = run("{document: catalog, action: search, "
		"query: 'deepseek reasoning', limit: 50}", &ok);
	FYAI_TCHECK(ok && fy_get(r, "found", 0LL) >= 1);

	r = run("{document: catalog, action: list, path: providers}", &ok);
	FYAI_TCHECK(ok && fy_len(fy_get(r, "names", fy_seq_empty)) >= 2);
	v = fy_get(r, "names", fy_seq_empty);
	FYAI_TCHECK(fy_equal(fy_get_at(v, 0, fy_invalid), "anthropic"));

	/* A provider gives the ids of its models, not each offering. */
	r = run("{document: catalog, action: get, path: providers/openai}",
		&ok);
	FYAI_TCHECK(ok);
	v = fy_get(fy_get(r, "value", fy_invalid), "models", fy_invalid);
	FYAI_TCHECK(fy_is_sequence(v) &&
		    fy_is_string(fy_get_at(v, 0, fy_invalid)));

	check_refused("{document: catalog, action: get, path: providers/none}",
		      "nothing at providers/none");
	check_refused("{document: catalog, action: change, changes: []}",
		      "read only");
	check_refused("{document: skills, action: get}",
		      "document must be config or catalog");

	text = def->format_result(&test_ctx, test_ctx.transient_gb,
		doc("{document: catalog, action: search}"),
		"{\"document\": \"catalog\", \"found\": 1, \"models\": "
		"[{\"path\": \"models/m\", \"display_name\": \"M\", "
		"\"context_window\": 9, \"providers\": [\"p\"], "
		"\"current\": true}]}");
	FYAI_TCHECK(text && strstr(text, "`models/m`") &&
		    strstr(text, "9 tokens") && strstr(text, "**in use**"));
	free(text);

	settings_teardown();
	return 0;
}
