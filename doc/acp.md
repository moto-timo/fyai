# Agent Client Protocol

`fyai acp` serves Agent Client Protocol versions 1 and 2 over newline-delimited
JSON-RPC 2.0 on standard input and output. An editor starts the command as a
subprocess. The process owns its sessions until the editor closes the pipe;
each prompt runs in a separate short-lived worker process. There is no daemon.

Start the adapter with the same model, provider, and credential options used
for a normal `fyai` invocation. For example:

```sh
fyai -m MODEL acp
```

For VS Code, install an ACP client extension that can launch custom agents,
such as [ACP Client].
Add an agent in VS Code settings, replacing the executable path and model:

[ACP Client]:
  https://marketplace.visualstudio.com/items?itemName=formulahendry.acp-client

```json
{
  "acp.agents": {
    "fyai": {
      "command": "/absolute/path/to/fyai/build/fyai",
      "args": ["-m", "MODEL", "acp"],
      "env": {}
    }
  }
}
```

Configure fyai's provider credentials before connecting. Open a workspace in
VS Code, connect to the `fyai` agent, and start a conversation. The extension's
ACP Traffic output channel shows the `initialize` exchange if setup fails.

The adapter supports `initialize`, `session/new`, `session/list`,
`session/resume`, `session/prompt`, `session/cancel`, and `session/close`.
Version 1 also supports `session/load`. The client selects a major version
through `initialize.params.protocolVersion`; fyai uses the matching wire
format. Version 1 completes `session/prompt` with a `stopReason`. Version 2
acknowledges insertion with a `messageId` and ends the turn with an idle
`state_update`.
Sessions are durable `acp/` branches in the fyai arena. A later adapter
process can list and resume them. `session/resume` accepts a
`replayFrom: {"type":"start"}` cursor to replay stored conversation updates.

Prompts accept `text` and `resource_link` content blocks. A resource link is
passed to the model as its name and URI; the original block is retained with
the stored user message. Client-supplied MCP servers are rejected. Configure
MCP servers through fyai's configuration before starting the adapter.

Each session permits one active prompt. The prompt response acknowledges that
the user message was committed. Subsequent `session/update` notifications
carry the user message, running state, assistant text, and final idle state.
Cancellation interrupts the active turn. Standard output contains only
JSON-RPC frames; diagnostics go to standard error.

## Compatibility suite

From the repository root, run:

```sh
ninja -C build acp-testsuite
```

The target requires `git` and `uv`. It downloads a pinned revision of the
[ACP Test Compatibility Kit](https://github.com/agentclientprotocol/acp-tck)
into `build/_deps/acp-tck` on first use. `uv` installs its Python runtime and
dependencies. The target builds fyai, initializes a private arena, starts a
local mock model provider, runs the complete v1 and v2 suites, and writes
`build/acp-tck-v1.json` and `build/acp-tck-v2.json`. It does not use a real
provider key. The target fails if either suite gives a nonconformant verdict.

The kit is experimental and its verdict is limited to the requirements that
its pinned revision tests. The regular integration cases are
`fyai/case_acp_v1` and `fyai/case_acp_v2`.
