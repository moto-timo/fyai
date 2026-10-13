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
session. Use `fyai branch list` and `fyai -b sdk/ID history` to examine a
session.

## Messages

fyai sends the messages that the SDK parses:

- `system` with subtype `init` at the start of each turn, with the names of
  the tools of the session;
- `assistant` with the content blocks of each model response: `text` and
  `tool_use`;
- `user` with the `tool_result` blocks of each tool call; and
- `result` at the end of each turn, with the text of the last answer, the
  number of model responses, the token usage, and the cost.

The SDK sees three tools under the names and inputs of Claude Code: the
shell tool as `Bash` with `command` and `timeout`, `read_file` as `Read` with
`file_path`, `offset` and `limit`, and `write_file` as `Write` with
`file_path` and `content`. These names appear in `tool_use` blocks, in the
tools of `init`, in permission requests and in hook inputs. An input that
the SDK changes goes back to the fyai arguments of the call. Each other
tool keeps its fyai name and arguments.

A turn that fails or is interrupted ends with a `result` that has `is_error`
set and the subtype `error_during_execution`. The process exits with status 1
after such a result, when the SDK closes standard input. The `result` lists
the tool calls that were denied in `permission_denials`.

## Options

| SDK option | Effect in fyai |
| --- | --- |
| `system_prompt` (text or file) | Replaces the system prompt of a new session. fyai adds its guidance for parallel tool calls and the project instructions. |
| `system_prompt` (preset with `append`) | Appends the text to the system prompt of a new session. |
| `model` | Selects the model of the session. |
| `max_turns` | Sets `max_tool_iterations` for the session. |
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
session does and fyai does not support them yet: `agents`,
`continue_conversation`, `fork_session`, `max_budget_usd`, `output_format`,
`plugins`, and the permission mode `plan`.

fyai ignores the options that change only what the SDK receives or that have
no meaning in fyai: `include_partial_messages`, `thinking`, `effort`,
`setting_sources`, `settings`, `add_dirs`, and `betas`.

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
the permission mode, a hook, or `can_use_tool` allows it. A sub-agent of an
allowed `Task` call runs its own calls without a question.

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
  started with; and
- `mcp_status`.

It answers each other control request with an error.

## Standard input and output

Standard output carries only the JSON lines of the protocol. Diagnostics go
to standard error. Standard input and output must be pipes, as an SDK makes
them.
