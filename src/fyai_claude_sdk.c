/*
 * fyai_claude_sdk.c - the Claude Agent SDK protocol on standard I/O
 *
 * SPDX-License-Identifier: MIT
 *
 * A Claude Agent SDK runs its CLI as a child and exchanges JSON lines with
 * it: user messages and control requests on standard input, conversation
 * messages, results and control responses on standard output. This front
 * end serves that protocol for one session, which is a branch sdk/<id>.
 * The process lives while the SDK keeps standard input open; each user
 * message runs one turn, which is published before its result is sent.
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <openssl/rand.h>

#include "fyai.h"
#include "fyai_branch.h"
#include "fyai_claude_sdk.h"
#include "fyai_cmd.h"
#include "fyai_cmd_int.h"
#include "fyai_config.h"
#include "fyai_event.h"
#include "fyai_jsonrpc.h"
#include "fyai_output.h"
#include "fyai_provider.h"
#include "fyai_storage.h"
#include "fyai_tool_registry.h"
#include "fyai_tool_spec.h"
#include "fyai_turn.h"
#include "utils.h"

#define FYAI_MODULE FYAIEM_UNKNOWN

#define SDK_BRANCH_PREFIX	"sdk/"
#define SDK_ID_MAX		64

/* One user message that waits for its turn. */
struct sdk_input {
	struct sdk_input *next;
	char *text;
};

struct sdk_server {
	struct fyai_ctx *ctx;
	struct jsonrpc_conn *conn;
	struct sdk_input *head;
	struct sdk_input **tail;
	const char *session_id;		/* the branch name without its prefix */
	const char *permission_mode;
	bool initialized;
	bool busy;
	bool failed;			/* a frame could not be queued */
	bool last_error;		/* the last result is an error */
	/* State of the running turn. */
	long long num_turns;
	char *result_text;		/* the text of the last answer */
};

/*
 * The fyai tools of a Claude Code tool name. A name of no entry names a fyai
 * tool or an MCP tool itself, or nothing.
 */
static const struct {
	const char *claude;
	const char *fyai[5];
} sdk_tool_map[] = {
	{ "Bash",		{ "exec_command", "shell_input", "shell_output",
				  "shell_close" } },
	{ "BashOutput",		{ "shell_output" } },
	{ "KillShell",		{ "shell_close" } },
	{ "KillBash",		{ "shell_close" } },
	{ "Read",		{ "read_file" } },
	{ "Write",		{ "write_file" } },
	{ "Edit",		{ "apply_patch" } },
	{ "MultiEdit",		{ "apply_patch" } },
	{ "NotebookEdit",	{ "apply_patch" } },
	{ "TodoWrite",		{ "todo_write" } },
	{ "Task",		{ "agent", "agent_message", "agent_input" } },
	{ "Agent",		{ "agent", "agent_message", "agent_input" } },
	{ "Skill",		{ "skill" } },
	{ "Monitor",		{ "monitor" } },
	{ "AskUserQuestion",	{ "ask_user" } },
	{ "WebSearch",		{ "web_search" } },
};

/* The MCP tools stay with any base set, as the MCP servers do. */
static bool sdk_tool_is_mcp(const char *name)
{
	return !strcmp(name, "tool_search") || !strcmp(name, "mcp_resource");
}

bool fyai_claude_sdk_argv(int argc, char *const argv[])
{
	const char *base;
	int i;

	if (argc < 1 || !argv[0])
		return false;
	/* A wrapper that gives global options names the command itself. */
	for (i = 1; i < argc; i++)
		if (!strcmp(argv[i], "claude-sdk"))
			return false;
	base = strrchr(argv[0], '/');
	base = base ? base + 1 : argv[0];
	if (!strcmp(base, "claude"))
		return true;
	for (i = 1; i < argc; i++)
		if (!strcmp(argv[i], "--input-format") ||
		    !strncmp(argv[i], "--input-format=", 15))
			return true;
	return false;
}

char **fyai_claude_sdk_args(int argc, char *argv[])
{
	char **args;
	int i;

	if (!fyai_claude_sdk_argv(argc, argv) ||
	    fyai_claude_sdk_version(argc, argv))
		return NULL;
	args = calloc((size_t)argc + 2, sizeof(*args));
	if (!args)
		return NULL;
	args[0] = argv[0];
	args[1] = (char *)"claude-sdk";
	for (i = 1; i < argc; i++)
		args[i + 1] = argv[i];
	return args;
}

const char *fyai_claude_sdk_version(int argc, char *const argv[])
{
	if (argc != 2 || (strcmp(argv[1], "-v") && strcmp(argv[1], "--version")))
		return NULL;
	return FYAI_CLAUDE_SDK_VERSION " (fyai " VERSION ")";
}

static bool sdk_uuid(char *out, size_t size)
{
	unsigned char b[16];

	if (size < 37 || RAND_bytes(b, sizeof(b)) != 1)
		return false;
	b[6] = (b[6] & 0x0f) | 0x40;
	b[8] = (b[8] & 0x3f) | 0x80;
	snprintf(out, size,
		 "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-"
		 "%02x%02x%02x%02x%02x%02x",
		 b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
		 b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]);
	return true;
}

static bool sdk_id_valid(const char *id)
{
	size_t len = strlen(id);
	const char *p;

	if (!len || len > SDK_ID_MAX)
		return false;
	for (p = id; *p; p++)
		if (!((*p >= '0' && *p <= '9') || (*p >= 'a' && *p <= 'z') ||
		      (*p >= 'A' && *p <= 'Z') || *p == '-' || *p == '_'))
			return false;
	return true;
}

/* Add the fyai tools of the Claude Code name @name to @set. */
static fy_generic sdk_tools_add(struct fy_generic_builder *gb, fy_generic set,
				const char *name, size_t len)
{
	const struct fyai_tool_def *def;
	size_t i, j;
	char word[128];

	if (!len || len >= sizeof(word))
		return set;
	memcpy(word, name, len);
	word[len] = '\0';
	for (i = 0; i < ARRAY_SIZE(sdk_tool_map); i++) {
		if (strcmp(sdk_tool_map[i].claude, word))
			continue;
		for (j = 0; j < ARRAY_SIZE(sdk_tool_map[i].fyai) &&
			    sdk_tool_map[i].fyai[j]; j++)
			set = fy_append(gb, set, sdk_tool_map[i].fyai[j]);
		return set;
	}
	def = fyai_tool_find(word);
	if (def)
		set = fy_append(gb, set, def->name);
	return set;
}

/* The fyai tools of a list of Claude Code names separated by commas. */
static fy_generic sdk_tools_list(struct fy_generic_builder *gb,
				 const char *list)
{
	fy_generic set = fy_seq_empty;
	const char *p, *end;

	for (p = list; *p; p = *end ? end + 1 : end) {
		while (*p == ' ')
			p++;
		end = strchr(p, ',');
		if (!end)
			end = p + strlen(p);
		set = sdk_tools_add(gb, set, p, (size_t)(end - p));
	}
	return set;
}

static bool sdk_tools_has(fy_generic set, const char *name)
{
	fy_generic item;

	fy_foreach(item, set)
		if (fy_equal(item, name))
			return true;
	return false;
}

/*
 * The tools that --tools and --disallowedTools leave. Returns fy_invalid when
 * they restrict nothing, else the names; an empty sequence leaves no tool.
 */
static fy_generic sdk_tools_allowed(struct fy_generic_builder *gb,
				    const char *tools, const char *disallowed)
{
	const struct fyai_tool_def *def;
	fy_generic base, removed, out;
	bool all, restricted;
	size_t i;

	all = !tools || !strcmp(tools, "default");
	base = all ? fy_seq_empty : sdk_tools_list(gb, tools);
	removed = disallowed ? sdk_tools_list(gb, disallowed) : fy_seq_empty;
	out = fy_seq_empty;
	restricted = false;
	for (i = 0; (def = fyai_tool_at(i)); i++) {
		if (!all && !sdk_tools_has(base, def->name) &&
		    !sdk_tool_is_mcp(def->name)) {
			restricted = true;
			continue;
		}
		if (sdk_tools_has(removed, def->name)) {
			restricted = true;
			continue;
		}
		if (!sdk_tools_has(out, def->name))
			out = fy_append(gb, out, def->name);
	}
	return restricted ? out : fy_invalid;
}

/* The options of the SDK that change what the session does, which fyai lacks. */
static const char *const sdk_refused[] = {
	"max_budget_usd", "permission_prompt_tool", "continue",
	"resume_session_at", "resume_drops_turn", "fork_session",
	"session_mirror", "plugin_dir", "mcp_config", "json_schema",
};

int fyai_cmd_claude_sdk_early(struct fyai_cfg *cfg, fy_generic args)
{
	fy_generic v, allowed, stored;
	const char *resume, *sid, *model, *mode, *tools, *disallowed;
	const char *prompt, *path, *encoded;
	char id[SDK_ID_MAX + 1], name[sizeof(SDK_BRANCH_PREFIX) + SDK_ID_MAX];
	char *file = NULL;
	char opt[64];
	long long turns;
	bool valid;
	size_t i;
	int rc;

	for (i = 0; i < ARRAY_SIZE(sdk_refused); i++) {
		v = fy_get(args, sdk_refused[i], fy_invalid);
		if (fy_is_invalid(v) || fy_equal(v, false))
			continue;
		fyai_cmd_long_name(sdk_refused[i], opt, sizeof(opt));
		fyai_cfg_error(cfg, "claude-sdk: --%s is not supported", opt);
		return -1;
	}
	mode = fy_get(args, "permission_mode", (const char *)NULL);
	fyai_cfg_error_check(cfg, !mode || strcmp(mode, "plan"), err,
			     "claude-sdk: permission mode plan is not supported");
	disallowed = fy_get(args, "disallowed_tools", (const char *)NULL);
	fyai_cfg_error_check(cfg, !disallowed || !strchr(disallowed, '('), err,
			     "claude-sdk: permission rules in --disallowedTools "
			     "are not supported");

	resume = fy_get(args, "resume", (const char *)NULL);
	sid = fy_get(args, "session_id", (const char *)NULL);
	fyai_cfg_error_check(cfg, !(resume && sid), err,
			     "claude-sdk: --resume and --session-id exclude "
			     "each other");
	if (resume || sid) {
		valid = sdk_id_valid(resume ? resume : sid);
		fyai_cfg_error_check(cfg, valid, err,
				     "claude-sdk: invalid session ID '%s'",
				     resume ? resume : sid);
		snprintf(id, sizeof(id), "%s", resume ? resume : sid);
	} else {
		valid = sdk_uuid(id, sizeof(id));
		fyai_cfg_error_check(cfg, valid, err,
				     "claude-sdk: cannot make a session ID");
	}
	snprintf(name, sizeof(name), "%s%s", SDK_BRANCH_PREFIX, id);
	if (resume) {
		/* A stored session has a configuration, as each branch has. */
		rc = fyai_peek_arena_config(cfg->arena_dir, name, cfg->root_spec,
					    cfg->gb, &stored, NULL, NULL, NULL);
		fyai_cfg_error_check(cfg, !rc && fy_is_valid(stored), err,
				     "claude-sdk: no session with ID '%s'", id);
		rc = fyai_cfg_set_branch(cfg, name);
		if (rc)		/* fyai_cfg_set_branch() says why */
			goto err;
	} else {
		cfg->fresh_session = true;
		cfg->fresh_session_name = strdup(name);
		fyai_cfg_error_check(cfg, cfg->fresh_session_name, err,
				     "claude-sdk: cannot keep the session name");
	}

	prompt = fy_get(args, "system_prompt", (const char *)NULL);
	path = fy_get(args, "system_prompt_file", (const char *)NULL);
	if (path) {
		file = read_text_file(path);
		fyai_cfg_error_check(cfg, file, err,
				     "claude-sdk: cannot read the system prompt "
				     "file '%s'", path);
		prompt = file;
	}
	if (prompt && *prompt) {
		/* A JSON string keeps the line breaks that YAML would fold. */
		encoded = emit_json_string(cfg->gb, fy_value(cfg->gb, prompt));
		rc = encoded ? fyai_config_queue_set(cfg, "system_prompt",
						     encoded, false) : -1;
		fyai_cfg_error_check(cfg, !rc, err,
				     "claude-sdk: cannot set the system prompt");
	}
	free(file);
	file = NULL;

	model = fy_get(args, "model", (const char *)NULL);
	if (model && *model) {
		rc = fyai_config_queue_set(cfg, "model", model, true);
		fyai_cfg_error_check(cfg, !rc, err,
				     "claude-sdk: cannot select model '%s'", model);
	}
	turns = fy_get(args, "max_turns", 0LL);
	if (turns > 0) {
		rc = fyai_config_queue_set(cfg, "max_tool_iterations",
					   fy_sprintfa("%lld", turns), false);
		fyai_cfg_error_check(cfg, !rc, err,
				     "claude-sdk: cannot limit the turns");
	}
	tools = fy_get(args, "tools", (const char *)NULL);
	/* The provider runs web search: the configuration turns it off. */
	if ((tools && strcmp(tools, "default") &&
	     !sdk_tools_has(sdk_tools_list(cfg->gb, tools), "web_search")) ||
	    (disallowed &&
	     sdk_tools_has(sdk_tools_list(cfg->gb, disallowed), "web_search"))) {
		rc = fyai_config_queue_set(cfg, "web_search", "false", false);
		fyai_cfg_error_check(cfg, !rc, err,
				     "claude-sdk: cannot turn web search off");
	}
	allowed = sdk_tools_allowed(cfg->gb, tools, disallowed);
	if (fy_is_sequence(allowed) && fy_empty(allowed)) {
		rc = fyai_config_queue_set(cfg, "tools", "false", false);
		fyai_cfg_error_check(cfg, !rc, err,
				     "claude-sdk: cannot turn the tools off");
	}
	return 0;
err:
	free(file);
	return -1;
}

int fyai_cmd_claude_sdk_prepare(struct fyai_cfg *cfg, fy_generic args)
{
	(void)args;
	cfg->interactive = false;
	cfg->protocol_stdout = true;
	return 0;
}

static void sdk_send(struct sdk_server *srv, fy_generic frame)
{
	if (srv->failed)
		return;
	if (fy_is_invalid(frame) || jsonrpc_conn_send_frame(srv->conn, frame)) {
		fyai_error(srv->ctx, "claude-sdk: cannot send a frame");
		srv->failed = true;
	}
}

static void sdk_respond(struct sdk_server *srv, fy_generic request_id,
			fy_generic response, const char *error)
{
	struct fy_generic_builder *gb = fyai_ctx_transient_gb(srv->ctx);

	if (error)
		sdk_send(srv, fy_mapping(gb,
			"type", "control_response",
			"response", fy_mapping(gb,
				"subtype", "error",
				"request_id", request_id,
				"error", error)));
	else
		sdk_send(srv, fy_mapping(gb,
			"type", "control_response",
			"response", fy_mapping(gb,
				"subtype", "success",
				"request_id", request_id,
				"response", fy_is_valid(response) ?
					response : fy_map_empty)));
}

static bool sdk_mapping_empty(fy_generic v)
{
	return fy_is_invalid(v) || fy_is_null(v) ||
	       (fy_is_mapping(v) && fy_empty(v)) ||
	       (fy_is_sequence(v) && fy_empty(v));
}

static void sdk_control(struct sdk_server *srv, fy_generic frame)
{
	struct fy_generic_builder *gb = fyai_ctx_transient_gb(srv->ctx);
	fy_generic id, req;
	const char *subtype, *mode;

	id = fy_get(frame, "request_id", fy_invalid);
	req = fy_get(frame, "request", fy_invalid);
	subtype = fy_get(req, "subtype", "");
	if (!fy_is_string(id)) {
		fyai_warning(srv->ctx, "claude-sdk: a control request has no ID");
		return;
	}
	if (!strcmp(subtype, "initialize")) {
		if (srv->initialized) {
			sdk_respond(srv, id, fy_invalid, "already initialized");
			return;
		}
		if (!sdk_mapping_empty(fy_get(req, "hooks", fy_invalid))) {
			sdk_respond(srv, id, fy_invalid,
				    "fyai does not support hooks yet");
			return;
		}
		if (!sdk_mapping_empty(fy_get(req, "agents", fy_invalid))) {
			sdk_respond(srv, id, fy_invalid,
				    "fyai does not support SDK agents yet");
			return;
		}
		srv->initialized = true;
		sdk_respond(srv, id, fy_mapping(gb,
			"commands", fy_seq_empty,
			"output_style", "default",
			"available_output_styles", fy_sequence(gb, "default"),
			"models", fy_seq_empty), NULL);
		return;
	}
	if (!strcmp(subtype, "interrupt")) {
		if (srv->busy)
			srv->ctx->interrupt_pending = true;
		sdk_respond(srv, id, fy_invalid, NULL);
		return;
	}
	if (!strcmp(subtype, "set_permission_mode")) {
		mode = fy_get(req, "mode", "");
		if (!strcmp(mode, "plan")) {
			sdk_respond(srv, id, fy_invalid,
				    "fyai does not support permission mode plan");
			return;
		}
		srv->permission_mode = fy_gb_intern_string(srv->ctx->cfg->gb,
							   mode);
		sdk_respond(srv, id, fy_invalid, NULL);
		return;
	}
	sdk_respond(srv, id, fy_invalid,
		    fy_sprintfa("fyai does not support the control request '%s'",
				subtype));
}

/* The text of the content of a user message, or NULL. Owned by the caller. */
static char *sdk_user_text(struct sdk_server *srv, fy_generic content)
{
	struct response_buffer out = { 0 };
	fy_generic block, type;
	const char *s;

	if (fy_is_string(content))
		return strdup(fy_castp(&content, ""));
	if (!fy_is_sequence(content))
		return NULL;
	fy_foreach(block, content) {
		type = fy_get(block, "type", fy_invalid);
		if (!fy_equal(type, "text")) {
			fyai_warning(srv->ctx,
				     "claude-sdk: a '%s' block of a user message "
				     "is not supported; it is left out",
				     fy_str(type) ? fy_str(type) : "?");
			continue;
		}
		s = fy_get(block, "text", "");
		if ((out.len && response_buffer_append_data(&out, "\n", 1)) ||
		    response_buffer_append_data(&out, s, strlen(s))) {
			free(out.data);
			return NULL;
		}
	}
	return out.data ? out.data : strdup("");
}

static void sdk_user(struct sdk_server *srv, fy_generic frame)
{
	struct sdk_input *in;
	char *text;

	text = sdk_user_text(srv,
		fy_get_at_path(frame, "message", "content"));
	if (!text || !*text) {
		fyai_warning(srv->ctx, "claude-sdk: a user message has no text");
		free(text);
		return;
	}
	in = calloc(1, sizeof(*in));
	if (!in) {
		fyai_error(srv->ctx, "claude-sdk: cannot queue a user message");
		free(text);
		srv->failed = true;
		return;
	}
	in->text = text;
	*srv->tail = in;
	srv->tail = &in->next;
}

static void sdk_frame(struct jsonrpc_conn *conn, fy_generic frame, void *data)
{
	struct sdk_server *srv = data;
	fy_generic type;

	(void)conn;
	type = fy_get(frame, "type", fy_invalid);
	if (fy_equal(type, "control_request"))
		sdk_control(srv, frame);
	else if (fy_equal(type, "user"))
		sdk_user(srv, frame);
	else if (!fy_any_equal(type, "control_response",
			       "control_cancel_request"))
		fyai_debug(srv->ctx, "claude-sdk: a '%s' frame is ignored",
			   fy_str(type) ? fy_str(type) : "?");
}

/* A new UUID in the transient builder: a frame takes it at once. */
static const char *sdk_new_uuid(struct sdk_server *srv)
{
	struct fy_generic_builder *gb = fyai_ctx_transient_gb(srv->ctx);
	const char *s;
	char id[40];

	if (!gb || !sdk_uuid(id, sizeof(id)))
		return "";
	s = fy_gb_intern_string(gb, id);
	return s ? s : "";
}

/* Usage as an Anthropic usage object, from fyai usage counts. */
static fy_generic sdk_usage(struct fy_generic_builder *gb, long long input,
			    long long output, long long cached,
			    long long cache_write)
{
	return fy_mapping(gb,
		"input_tokens", input,
		"output_tokens", output,
		"cache_read_input_tokens", cached,
		"cache_creation_input_tokens", cache_write);
}

/* Keep the text blocks of an answer as the text of the result. */
static void sdk_keep_text(struct sdk_server *srv, fy_generic content)
{
	struct response_buffer out = { 0 };
	fy_generic block;
	const char *s;

	fy_foreach(block, content) {
		if (!fy_equal(fy_get(block, "type", fy_invalid), "text"))
			continue;
		s = fy_get(block, "text", "");
		if (response_buffer_append_data(&out, s, strlen(s))) {
			free(out.data);
			return;
		}
	}
	if (!out.data)
		return;
	free(srv->result_text);
	srv->result_text = out.data;
}

static void sdk_observe(struct fyai_ctx *ctx, fy_generic turn, void *data)
{
	struct sdk_server *srv = data;
	struct fy_generic_builder *gb = fyai_ctx_transient_gb(ctx);
	fy_generic blocks, m, content, usage;
	char msgid[48];
	const char *role;

	blocks = fyai_messages_blocks(ctx, fy_get(turn, "messages", fy_seq_empty));
	if (fy_is_invalid(blocks)) {
		fyai_error(ctx, "claude-sdk: cannot convert a step of the turn");
		srv->failed = true;
		return;
	}
	usage = fy_get(fyai_turn_meta(turn), "usage", fy_invalid);
	fy_foreach(m, blocks) {
		role = fy_get(m, "role", "");
		content = fy_get(m, "content", fy_seq_empty);
		if (!strcmp(role, "assistant")) {
			srv->num_turns++;
			sdk_keep_text(srv, content);
			snprintf(msgid, sizeof(msgid), "msg_%s",
				 sdk_new_uuid(srv));
			sdk_send(srv, fy_mapping(gb,
				"type", "assistant",
				"message", fy_mapping(gb,
					"id", msgid,
					"type", "message",
					"role", "assistant",
					"model", ctx->cfg->model ?
						ctx->cfg->model : "",
					"content", content,
					"stop_reason", fy_null,
					"stop_sequence", fy_null,
					"usage", sdk_usage(gb,
						fy_get(usage, "input", 0LL),
						fy_get(usage, "output", 0LL),
						fy_get(usage, "cached", 0LL),
						fy_get(usage, "cache_write", 0LL))),
				"parent_tool_use_id", fy_null,
				"session_id", srv->session_id,
				"uuid", sdk_new_uuid(srv)));
		} else {
			sdk_send(srv, fy_mapping(gb,
				"type", "user",
				"message", fy_mapping(gb,
					"role", "user",
					"content", content),
				"parent_tool_use_id", fy_null,
				"session_id", srv->session_id,
				"uuid", sdk_new_uuid(srv)));
		}
	}
}

static void sdk_send_init(struct sdk_server *srv)
{
	struct fyai_ctx *ctx = srv->ctx;
	struct fy_generic_builder *gb = fyai_ctx_transient_gb(ctx);
	fy_generic tools, tool, names;
	char cwd[PATH_MAX];

	names = fy_seq_empty;
	tools = ctx->cfg->enable_tools ? make_tools_filtered(ctx) :
		fy_seq_empty;
	fy_foreach(tool, tools)
		names = fy_append(gb, names,
			fy_get_at_path(tool, "function", "name"));
	sdk_send(srv, fy_mapping(gb,
		"type", "system",
		"subtype", "init",
		"cwd", getcwd(cwd, sizeof(cwd)) ? cwd : "",
		"session_id", srv->session_id,
		"tools", names,
		"mcp_servers", fy_seq_empty,
		"model", ctx->cfg->model ? ctx->cfg->model : "",
		"permissionMode", srv->permission_mode,
		"slash_commands", fy_seq_empty,
		"apiKeySource", "none",
		"claude_code_version", FYAI_CLAUDE_SDK_VERSION,
		"output_style", "default",
		"agents", fy_seq_empty,
		"skills", fy_seq_empty,
		"plugins", fy_seq_empty,
		"uuid", sdk_new_uuid(srv)));
}

static long long sdk_elapsed_ms(const struct timespec *start)
{
	struct timespec now;

	clock_gettime(CLOCK_MONOTONIC, &now);
	return (long long)(now.tv_sec - start->tv_sec) * 1000 +
	       (now.tv_nsec - start->tv_nsec) / 1000000;
}

/* Run one turn for @text and send its result. */
static void sdk_turn(struct sdk_server *srv, const char *text)
{
	struct fyai_ctx *ctx = srv->ctx;
	struct fyai_cfg *cfg = ctx->cfg;
	struct fy_generic_builder *gb;
	struct timespec start;
	fy_generic user, turn, diag, value, frame;
	long long in0, out0, cached0, write0, ms;
	double cost0;
	char *cause = NULL;
	bool ok;
	int rc;

	clock_gettime(CLOCK_MONOTONIC, &start);
	in0 = ctx->usage_input;
	out0 = ctx->usage_output;
	cached0 = ctx->usage_cached;
	write0 = ctx->usage_cache_write;
	cost0 = ctx->usage_cost;
	srv->num_turns = 0;
	free(srv->result_text);
	srv->result_text = NULL;

	ok = false;
	rc = fyai_setup_transient_builder(ctx);
	fyai_error_check(ctx, !rc, done, "claude-sdk: cannot prepare the turn");
	gb = fyai_ctx_transient_gb(ctx);
	sdk_send_init(srv);

	user = fyai_make_user_message(ctx, text);
	turn = fyai_turn_append(ctx, ctx->last_message, fy_sequence(gb, user));
	turn = fyai_output_record(ctx, turn, FYAI_OUTPUT_USER, text);
	fyai_error_check(ctx, fy_is_valid(turn), done,
			 "claude-sdk: cannot add the user message");
	ctx->last_message = fy_gb_internalize(ctx->gb, turn);
	fyai_error_check(ctx, fy_is_valid(ctx->last_message), done,
			 "claude-sdk: cannot keep the user message");
	rc = fyai_publish_state(ctx);
	fyai_error_check(ctx, !rc, done,
			 "claude-sdk: cannot store the user message");

	srv->busy = true;
	turn = fyai_run_turn(ctx, ctx->last_message);
	srv->busy = false;
	diag = fy_generic_get_diag(turn);
	if (fy_is_valid(diag) && !fy_is_null(diag)) {
		cause = strdup(fy_castp(&diag, ""));
		fyai_error(ctx, "%s", cause ? cause : "the turn stopped");
		value = fy_generic_indirect_get_value(turn);
	} else {
		value = turn;
	}
	if (fy_is_valid(value)) {
		ctx->last_message = value;
		rc = fyai_publish_state(ctx);
		fyai_error_check(ctx, !rc, done,
				 "claude-sdk: cannot store the turn");
	}
	ok = fy_is_valid(value) && !cause;

done:
	if (!ok && !cause)
		cause = fyai_diag_string(&cfg->diag);
	ms = sdk_elapsed_ms(&start);
	gb = fyai_ctx_transient_gb(ctx);
	frame = fy_mapping(gb,
		"type", "result",
		"subtype", ok ? "success" : "error_during_execution",
		"is_error", (_Bool)!ok,
		"duration_ms", ms,
		"duration_api_ms", ms,
		"num_turns", srv->num_turns,
		"result", ok ? (srv->result_text ? srv->result_text : "") :
			(cause && *cause ? cause : "the turn did not complete"),
		"stop_reason", ok ? fy_value(gb, "end_turn") : fy_null,
		"session_id", srv->session_id,
		"total_cost_usd", ctx->usage_cost - cost0,
		"usage", sdk_usage(gb,
			ctx->usage_input - in0, ctx->usage_output - out0,
			ctx->usage_cached - cached0,
			ctx->usage_cache_write - write0),
		"permission_denials", fy_seq_empty,
		"uuid", sdk_new_uuid(srv));
	if (!ok)
		frame = fy_assoc(gb, frame, "errors", fy_sequence(gb,
			cause && *cause ? cause : "the turn did not complete"));
	sdk_send(srv, frame);
	srv->last_error = !ok;
	free(cause);
	fyai_diag_drain(&cfg->diag);
	fyai_cleanup_transient_builder(ctx);
}

/*
 * Append @append to the system prompt of a session that has no exchange. The
 * setup made that prompt, from the configuration, before this runs.
 */
static int sdk_system_append(struct sdk_server *srv, const char *append)
{
	struct fyai_ctx *ctx = srv->ctx;
	struct fy_generic_builder *gb;
	fy_generic turn;
	const char *text;
	int rc;

	if (!append || !*append)
		return 0;
	if (!ctx->session_unstored) {
		fyai_warning(ctx, "claude-sdk: a resumed session keeps its "
			     "system prompt");
		return 0;
	}
	text = fy_sprintfa("%s\n\n%s", ctx->cfg->system_prompt, append);
	rc = fyai_setup_transient_builder(ctx);
	fyai_error_check(ctx, !rc, err,
			 "claude-sdk: cannot prepare the system prompt");
	gb = fyai_ctx_transient_gb(ctx);
	turn = fyai_turn_append(ctx, fy_invalid,
		fy_sequence(gb, fyai_make_system_message(ctx, text)));
	turn = fyai_output_record(ctx, turn, FYAI_OUTPUT_SYSTEM, text);
	ctx->last_message = fy_gb_internalize(ctx->gb, turn);
	fyai_cleanup_transient_builder(ctx);
	fyai_error_check(ctx, fy_is_valid(ctx->last_message), err,
			 "claude-sdk: cannot keep the system prompt");
	return 0;
err:
	return -1;
}

int fyai_cmd_claude_sdk(struct fyai_cmd_call *call, fy_generic *result)
{
	struct fyai_ctx *ctx = call->ctx;
	struct fyai_event_loop *el = fyai_ctx_loop(ctx);
	struct sdk_server srv;
	struct sdk_input *in;
	const char *branch, *mode;
	fy_generic allowed;
	bool found;
	int rc = -1;

	(void)result;
	memset(&srv, 0, sizeof(srv));
	srv.ctx = ctx;
	srv.tail = &srv.head;
	fyai_error_check(ctx, el, out, "claude-sdk: no event loop");

	branch = fyai_ctx_branch(ctx);
	found = !strncmp(branch, SDK_BRANCH_PREFIX, strlen(SDK_BRANCH_PREFIX));
	fyai_error_check(ctx, found, out,
			 "claude-sdk: branch '%s' is not a session", branch);
	srv.session_id = branch + strlen(SDK_BRANCH_PREFIX);
	mode = fyai_cmd_arg_str(call, "permission_mode");
	srv.permission_mode = mode ? mode : "default";

	rc = sdk_system_append(&srv,
			       fyai_cmd_arg_str(call, "append_system_prompt"));
	if (rc)		/* sdk_system_append() says why */
		goto out;
	allowed = sdk_tools_allowed(ctx->cfg->gb,
				    fyai_cmd_arg_str(call, "tools"),
				    fyai_cmd_arg_str(call, "disallowed_tools"));
	if (fy_is_sequence(allowed) && !fy_empty(allowed)) {
		/* The tools of a request were made at setup: make them again. */
		ctx->tools_allow = allowed;
		rc = fyai_setup_transient_builder(ctx);
		if (!rc) {
			ctx->tools_spec = fy_invalid;
			rc = fyai_request_state_apply(ctx);
		}
		fyai_cleanup_transient_builder(ctx);
		fyai_error_check(ctx, !rc, out,
				 "claude-sdk: cannot limit the tools");
	}

	rc = -1;
	srv.conn = jsonrpc_conn_stdio(ctx, STDOUT_FILENO, STDIN_FILENO, 0,
				      "claude-sdk", NULL);
	fyai_error_check(ctx, srv.conn, out,
			 "claude-sdk: cannot open standard input and output");
	rc = jsonrpc_conn_frames(srv.conn, sdk_frame, &srv);
	fyai_error_check(ctx, !rc, out,
			 "claude-sdk: cannot read standard input");
	ctx->turn_observe = sdk_observe;
	ctx->turn_observe_data = &srv;

	while (!srv.failed) {
		if (srv.head) {
			in = srv.head;
			srv.head = in->next;
			if (!srv.head)
				srv.tail = &srv.head;
			sdk_turn(&srv, in->text);
			free(in->text);
			free(in);
			continue;
		}
		if (jsonrpc_conn_closed(srv.conn))
			break;
		rc = fyai_event_loop_step(el, -1);
		fyai_error_check(ctx, rc >= 0, out,
				 "claude-sdk: the event loop stopped");
	}
	while (jsonrpc_conn_has_output(srv.conn))
		if (fyai_event_loop_step(el, 1000) <= 0)
			break;
	ctx->cfg->exit_status = srv.last_error || srv.failed ? 1 : 0;
	rc = 0;
	goto done;
out:
	rc = -1;
done:
	ctx->turn_observe = NULL;
	ctx->turn_observe_data = NULL;
	while ((in = srv.head)) {
		srv.head = in->next;
		free(in->text);
		free(in);
	}
	free(srv.result_text);
	jsonrpc_conn_destroy(srv.conn);
	return rc;
}
