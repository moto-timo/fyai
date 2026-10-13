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

The names of tools and the arguments in `tool_use` blocks are those of fyai,
for example `read_file` with `path`. They are not the names of Claude Code.

A turn that fails or is interrupted ends with a `result` that has `is_error`
set and the subtype `error_during_execution`. The process exits with status 1
after such a result, when the SDK closes standard input.

## Options

| SDK option | Effect in fyai |
| --- | --- |
| `system_prompt` (text or file) | Replaces the system prompt of a new session. fyai adds its guidance for parallel tool calls and the project instructions. |
| `system_prompt` (preset with `append`) | Appends the text to the system prompt of a new session. |
| `model` | Selects the model of the session. |
| `max_turns` | Sets `max_tool_iterations` for the session. |
| `tools` | Limits the built-in tools. Claude Code names map to fyai tools: `Bash` to the shell tools, `Read` to `read_file`, `Write` to `write_file`, `Edit` to `apply_patch`, `Task` to `agent`, `TodoWrite` to `todo_write`. A fyai tool name names the tool itself. An empty list turns tools off. |
| `disallowed_tools` | Removes tools, with the same names. |
| `allowed_tools`, `permission_mode` | Accepted. fyai runs tools in its sandbox and asks for no permission. |
| `resume`, `session_id` | Select the session. |
| `cwd`, `env` | Apply to the fyai process, as to any CLI. |

These options stop the session with an error, because they change what the
session does and fyai does not support them yet: `can_use_tool`, `hooks`,
`agents`, `mcp_servers`, `continue_conversation`, `fork_session`,
`max_budget_usd`, `output_format`, `plugins`, and the permission mode `plan`.
A permission rule in `disallowed_tools`, such as `Bash(rm:*)`, also stops it.

fyai ignores the options that change only what the SDK receives or that have
no meaning in fyai: `include_partial_messages`, `thinking`, `effort`,
`setting_sources`, `settings`, `add_dirs`, and `betas`.

## Control requests

fyai answers `initialize`, `interrupt`, and `set_permission_mode`. It
answers each other control request with an error.

## Standard input and output

Standard output carries only the JSON lines of the protocol. Diagnostics go
to standard error. Standard input and output must be pipes, as an SDK makes
them.
