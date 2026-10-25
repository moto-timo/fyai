# Claude Agent SDK compatibility

fyai can be the CLI of the Claude Agent SDK. The SDK for Python and the SDK
for TypeScript do not run an agent in their own process. They start the
`claude` program and exchange JSON lines with it on standard input and
output. fyai serves the same protocol. An SDK program then runs its agent
loop on fyai, with each provider and model that fyai supports.

fyai does not contain code of the SDK. The user installs the SDK. Use of the
SDK is under the terms of its publisher.

## Use fyai from an SDK program

Give the path of fyai as the CLI of the SDK:

```python
from claude_agent_sdk import query, ClaudeAgentOptions

options = ClaudeAgentOptions(cli_path="/usr/local/bin/fyai")
async for message in query(prompt="What is in README.md?", options=options):
    print(message)
```

In TypeScript, set `pathToClaudeCodeExecutable`.

An SDK finds a program named `claude` on `PATH` when no path is given. A
symbolic link named `claude` to fyai thus serves an unchanged program:

```sh
ln -s /usr/local/bin/fyai ~/bin/claude
```

fyai serves the protocol when it runs as `claude`, or when its arguments
include `--input-format`. The hidden command `claude-sdk` serves it
explicitly. Use that command in a wrapper that gives global options of
fyai:

```sh
#!/bin/sh
exec fyai -m openai/gpt-5 claude-sdk "$@"
```

A `--set` option in a wrapper is stored, as it is for each command.

`claude -v` prints `2.0.0 (fyai VERSION)`. The SDK reads this version.

## Configuration

The SDK gives the options of the Claude CLI only. The session therefore
takes its provider, its model and its other configuration from fyai: from
the branch that `HEAD` names. A new session does not take the configuration
of the session that ran last in its directory, as an interactive session
does, so a change that one program makes does not reach the next. The `model`
option of the SDK selects the model for the session only.

The SDK gives no credential. Configure the key of the provider in fyai, or
pass its environment variable through the `env` option of the SDK.

## Sessions

Each SDK session is a branch `sdk/ID`, where ID is the `session_id` that the
SDK reports. The session is stored when its first exchange is stored. The
`resume` option continues the session, and `session_id` names a new
session. `continue_conversation` continues the session of the working
directory that changed last, else starts a new one. `fork_session` with
`resume` starts a new session from the conversation and configuration of
the resumed one, which does not change. Use `fyai branch list` and
`fyai -b sdk/ID history` to examine a session.

A branch that `-b` names (or `$FYAI_BRANCH`) is the session, whatever its name.
A branch that exists continues, and one that does not starts at that name with
the configuration of `HEAD`. The `session_id` that the SDK reports is then the
name of the branch, and no `sdk/` branch is made. A front that is not the SDK,
such as the web page, uses this to work on the branches of the CLI.

A prompt that names a file as `@PATH` carries the content of the file, as
in Claude Code: fyai adds the call of `Read` and its result to the text of
the prompt, after the `UserPromptSubmit` hooks. PATH is absolute, relative
to the working directory, or starts with `~/`. A message that the SDK
marks `client_composed`, as `verbatim_prompts` does, goes as written.

A user message can carry images as blocks, `{type: image, source: {type:
base64, media_type, data}}`. fyai attaches each one to that message as an
image part (`doc/media.md`), so the request carries it in the form of the API
and the session stores its bytes. A message of image blocks alone is a prompt.
The types are PNG, JPEG, GIF and WebP, and the model must take images. A
block that fyai cannot attach, such as bytes of no image type, ends the turn
with an error result that names the image. A block with another source type
is left out with a warning.

A prompt that is `/clear` starts a new session with the configuration of
the session and no conversation, as in Claude Code. A `conversation_reset`
message names the session that ends, and a `result` gives the new one.

## Messages

fyai sends the messages that the SDK parses:

- `system` with subtype `init` at the start of each turn, with the names of
  the tools of the session;
- `assistant` with the content blocks of each model response: `text` and
  `tool_use`;
- `user` with the `tool_result` blocks of each tool call; and
- `result` at the end of each turn, with the text of the last answer, the
  number of model responses, the token usage, the cost, and the `origin`
  that the SDK stamped on the user message; and
- with `include_partial_messages`, `stream_event` with the text of each
  response as it arrives: `message_start`, `content_block_start`,
  `content_block_delta` with a `text_delta` for each chunk,
  `content_block_stop`, `message_delta` and `message_stop`. The text of a
  response streams; its tool calls come in its `assistant` message.

The SDK sees three tools under the names and inputs of Claude Code: the
shell tool as `Bash` with `command` and `timeout`, `read_file` as `Read` with
`file_path`, `offset` and `limit`, and `write_file` as `Write` with
`file_path` and `content`. The sub-agent tool is `Task`, with
`description`, `prompt` and `subagent_type`, and the tool of structured
output is `StructuredOutput`. These names appear in `tool_use` blocks, in
the tools of `init`, in permission requests and in hook inputs. An input
that the SDK changes goes back to the fyai arguments of the call. Each
other tool keeps its fyai name and arguments.

A turn that fails or is interrupted ends with a `result` that has `is_error`
set. Its subtype says why: `error_max_turns` for the limit of `max_turns`,
`error_max_budget_usd` for the limit of `max_budget_usd`,
`error_max_structured_output_retries` for a turn that ended without the
structured output that it was asked for, and `error_during_execution` for
each other cause. A failed provider request is the exception, as in Claude
Code: the subtype is `success`, `terminal_reason` is `api_error`,
`api_error_status` gives the HTTP status, and the text gives the reason. The
process exits with status 1 after such a result, when the SDK closes
standard input. The `result` lists the tool calls that were denied in
`permission_denials`. A turn that succeeds has the `terminal_reason`
`completed`, and a turn at the limit of `max_turns` has `max_turns`.

## Options

| SDK option | Effect in fyai |
| --- | --- |
| `system_prompt` (text or file) | Replaces the system prompt of a new session. fyai adds its guidance for parallel tool calls and the project instructions. |
| `system_prompt` (preset with `append`) | Appends the text to the system prompt of a new session. |
| `model` | Selects the model of the session. |
| `max_turns` | Sets `max_tool_iterations` for the session. |
| `max_budget_usd` | Stops a turn before its next model request once the cost of the process reaches the budget. The cost is the cost that the provider reports, else the estimate from the prices of the catalogue; a model with no price costs nothing. |
| `output_format` | Asks for structured output. See [Structured output](#structured-output). |
| `include_partial_messages` | Sends `stream_event` messages. |
| `agents` | Personas of the `agent` tool, with their description, prompt and model. See [Agents](#agents). |
| `continue_conversation`, `fork_session` | See [Sessions](#sessions). |
| `tools` | Limits the built-in tools. Claude Code names map to fyai tools: `Bash` to the shell tools, `Read` to `read_file`, `Write` to `write_file`, `Edit` to `apply_patch`, `Task` to `agent`, `TodoWrite` to `todo_write`. A fyai tool name names the tool itself. An empty list turns tools off. MCP tools stay. |
| `disallowed_tools` | Removes the tools that it names, MCP tools included. A rule with parentheses denies the calls that it covers. |
| `allowed_tools` | Rules of the calls that run without a permission request. |
| `permission_mode` | See [Permissions](#permissions). |
| `can_use_tool` | Asks the SDK before a call that no rule allows. |
| `hooks` | See [Hooks](#hooks). |
| `mcp_servers` | Starts the servers for the session. See [MCP servers](#mcp-servers). |
| `resume`, `session_id` | Select the session. |
| `cwd`, `env` | Apply to the fyai process, as to any CLI. |

These options stop the session with an error, because they change what the
session does and fyai does not support them yet: `plugins`, `session_store`,
`resume_session_at`, an agent that limits its `tools`, and the permission
mode `plan`.

fyai ignores the options that change only what the SDK receives or that have
no meaning in fyai: `thinking`, `effort`, `setting_sources`, `settings`,
`add_dirs`, and `betas`.

## Structured output

With `output_format` of type `json_schema`, the model gets the tool
`StructuredOutput`, whose parameters are the schema. A call whose arguments
match the schema is the answer: the `result` gives it as
`structured_output`, and the turn ends without a further model request. A
call that does not match gets the problems as its result, and the model
can correct it. A model that answers in prose instead is reminded to call
the tool, up to three times.

## Agents

Each agent of `agents` is a persona of the `agent` tool for the session: its
`description` is what the model chooses by, its `prompt` is its system
prompt, `tools` limits the tools that it is offered and can call, and its
`model` selects its model. The model aliases of Claude Code, `inherit`,
`sonnet`, `opus` and `haiku`, name no model of fyai: the agent then takes the
model of the session. The personas are not stored.

A sub-agent asks the session about each of its tool calls: the rules, the
permission mode, the hooks and `can_use_tool` decide on them as on a call of
the session, and a denial is in `permission_denials` of the result. Its
`tool_use` and `tool_result` blocks come in `assistant` and `user` messages
whose `parent_tool_use_id` is the `Task` call that started it. Its text
comes too when `initialize` gives `forwardSubagentText`. A sub-agent of a
sub-agent asks the session too, but its messages do not come.

## Permissions

fyai decides on each tool call of a response before any of the calls runs.
It stops at the first step that decides:

1. A rule of `disallowed_tools` that covers the call denies it.
2. The `PreToolUse` hooks decide with `permissionDecision`: `deny` denies the
   call, `allow` runs it, and `ask` goes to `can_use_tool` whatever the rules
   say. An `updatedInput` replaces the input of the call.
3. The permission mode `bypassPermissions` runs the call.
4. A rule of `allowed_tools` that covers the call runs it.
5. A tool that changes nothing runs: the entry of the tool in the registry
   of fyai gives it no effect. Examples are `Read`, `list`, `time`, `wait`,
   `todo_write`, `tool_search`, `mcp_resource`, and `shell_output`.
6. The mode `acceptEdits` runs a tool that writes project files: `Write` and
   `apply_patch`.
7. The mode `dontAsk` denies the call.
8. `can_use_tool` decides. A denial with `interrupt` stops the turn.
9. Without `can_use_tool`, the call is denied, as in Claude Code.

Thus a call of `Bash`, of `Task`, or of an MCP tool runs only when a rule,
the permission mode, a hook, or `can_use_tool` allows it. The calls of a
sub-agent go through the same steps.

The provider runs web search, and no one can be asked about a search. Thus
web search is on only when the session starts with the mode
`bypassPermissions` or with `WebSearch` in `allowed_tools`.

A rule is a tool name, a Claude Code name or an MCP tool name, alone or with
text in parentheses. The text of a `Bash` rule is a command: `git log:*`
covers each command that starts with `git log`, and other text is a shell
pattern of the whole command. The text of a `Read` or `Write` rule is a
shell pattern of the path. Text for another tool covers no call.

A denied call gets the reason as its result, and the model goes on.

## Hooks

fyai calls the hooks of these events:

| Event | When | What the output does |
| --- | --- | --- |
| `UserPromptSubmit` | before the turn of a prompt | `additionalContext` follows the prompt; `decision: block` or `continue: false` stops the prompt with an error result. |
| `PreToolUse` | before a tool call | See [Permissions](#permissions). `continue: false` stops the turn. |
| `PostToolUse` | after a tool call that succeeded | `additionalContext`, and the `reason` of `decision: block`, go to the model before its next request; `continue: false` stops the turn. |
| `PostToolUseFailure` | after a tool call that failed | As `PostToolUse`. |
| `Stop` | when the model ends the turn | `decision: block` sends the `reason` to the model, which goes on; the next `Stop` input has `stop_hook_active` set. |

A matcher is a regular expression of the tool name; an empty matcher, `*`, or
none matches each tool. fyai accepts the hooks of other events and does not
call them. `updatedToolOutput` is not applied.

## MCP servers

`mcp_servers` can give three kinds of server:

- a server of the SDK, from `create_sdk_mcp_server()`: it runs in the SDK
  process, and fyai sends it each message through the `mcp_message` control
  request;
- a program (`type: stdio`, or a `command`), with `args` and `env`; and
- an HTTP server (`type: http`) with a `url` and no `headers`. fyai takes the
  credentials of a server from its configuration, so a server that needs a
  header is configured in fyai.

Their tools are named `mcp__SERVER__TOOL`, as in Claude Code. fyai answers
`initialize` when each server has connected or failed, so the first turn has
their tools. The MCP servers of the fyai
configuration also start, unless the SDK gives `--strict-mcp-config`.

## Control requests

fyai answers these control requests of the SDK:

- `initialize`, which brings the hooks;
- `interrupt`, which stops the running turn;
- `set_permission_mode`;
- `set_model`, which changes the model for the process, as in Claude Code,
  from the next turn: nothing stores it. A model that fyai cannot use leaves
  the session as it was, and no model returns to the model that the session
  started with;
- `mcp_status`; and
- `get_context_usage`, with the tokens of the last model request and the
  context window of the model from the catalogue.

It answers each other control request with an error.

## Compatibility suite

The target `claude-agent-sdk-testsuite` runs the end-to-end suite of the
SDK for Python, at a pinned revision, with fyai as its CLI:

```sh
export ANTHROPIC_API_KEY=...
ninja -C build claude-agent-sdk-testsuite
```

The suite calls a real model and costs money. Each session runs on
`FYAI_SDK_MODEL`, by default `anthropic/claude-haiku-5.5`, with the key in
the variable that `FYAI_SDK_KEY_ENV` names, by default `ANTHROPIC_API_KEY`:
the suite names Anthropic models, and a wrapper replaces them. A name that
is not a Claude model goes through, so a test of a bad model fails. Give more
pytest arguments in `FYAI_SDK_PYTEST`, for example `-k hooks`. It needs git
and uv, and writes a JUnit report to `claude-sdk-e2e.xml` in the build
directory.

A test of a feature that fyai does not support fails: plugins, session
stores, the files of Claude Code (transcripts, settings and agents), and
extended thinking.

## Standard input and output

Standard output carries only the JSON lines of the protocol. Diagnostics go
to standard error. Standard input and output must be pipes, as an SDK makes
them.
