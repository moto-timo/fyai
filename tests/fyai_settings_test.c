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
#include "fyai_tools.h"

#include "fyai_test.h"
#include "fyai_test_registry.h"

FYAI_TEST_ENTRY(settings, read, settings_read)
FYAI_TEST_ENTRY(settings, search, settings_search)
FYAI_TEST_ENTRY(settings, offered, settings_offered)

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

static fy_generic run(const char *args, bool *okp)
{
	return fyai_tool_run_one(&test_ctx, "settings", doc(args), okp);
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

/* model_access none offers no settings tool. */
int settings_offered(void)
{
	if (settings_setup())
		return 1;
	FYAI_TCHECK(offers_settings());
	test_cfg.model_access = -1;
	FYAI_TCHECK(!offers_settings());
	settings_teardown();
	return 0;
}
