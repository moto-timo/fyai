#!/bin/bash
# SPDX-License-Identifier: MIT
# The Claude Agent SDK for Python, unchanged, runs a session on fyai. The case
# runs when $PYTHON can import claude_agent_sdk.
set -eu
. "$(dirname "$0")/../harness.sh"

"$PYTHON" -c 'import claude_agent_sdk' 2>/dev/null ||
	skip "the Python package claude_agent_sdk is not installed"

fyai_test_setup
printf 'hello\n' > notes.txt
mock_start claude_sdk.json

export MOCK_KEY=test-key
"$FYAI_BIN" --set api=chat-completions --set display/stream=false \
	--set "api_url=$MOCK_URL/v1/chat/completions" --set model=mock-model \
	--set 'api_key={type: env, value: MOCK_KEY}' >/dev/null 2>&1 ||
	fail "configure the project"

"$PYTHON" - "$FYAI_BIN" "$TEST_DIR" <<'PYEOF' || fail "Python SDK session"
import sys

import anyio
from claude_agent_sdk import (AssistantMessage, ClaudeAgentOptions,
                              ClaudeSDKClient, ResultMessage, SystemMessage,
                              ToolUseBlock, UserMessage, query)

binary, cwd = sys.argv[1], sys.argv[2]

async def main():
    options = ClaudeAgentOptions(cli_path=binary, cwd=cwd,
                                 system_prompt="Answer briefly.")
    kinds = []
    result = None
    async for message in query(prompt="read the notes", options=options):
        kinds.append(type(message).__name__)
        if isinstance(message, AssistantMessage):
            for block in message.content:
                if isinstance(block, ToolUseBlock):
                    assert block.name == "Read", block
                    assert block.input == {"file_path": "notes.txt"}, block
        if isinstance(message, ResultMessage):
            result = message
    assert kinds == ["SystemMessage", "AssistantMessage", "UserMessage",
                     "AssistantMessage", "ResultMessage"], kinds
    assert not result.is_error and result.result == "The notes say hello.", result

    options = ClaudeAgentOptions(cli_path=binary, cwd=cwd,
                                 resume=result.session_id)
    async with ClaudeSDKClient(options=options) as client:
        await client.query("again")
        async for message in client.receive_response():
            if isinstance(message, ResultMessage):
                assert message.result == "Resumed.", message
                assert message.session_id == result.session_id, message

anyio.run(main)
PYEOF

mock_stop 3
assert_request 0 'r["body"]["messages"][0]["content"].startswith("Answer briefly.")'

mock_start claude_sdk_control.json
"$FYAI_BIN" --set "api_url=$MOCK_URL/v1/chat/completions" >/dev/null 2>&1 ||
	fail "point the project at the second mock"

"$PYTHON" - "$FYAI_BIN" "$TEST_DIR" <<'PYEOF' || fail "Python SDK control"
import os
import sys
from typing import Any

import anyio
from claude_agent_sdk import (ClaudeAgentOptions, ClaudeSDKClient, HookMatcher,
                              PermissionResultAllow, ResultMessage,
                              create_sdk_mcp_server, tool)

binary, cwd = sys.argv[1], sys.argv[2]
log = []

@tool("add", "Add two numbers", {"a": int, "b": int})
async def add(args: dict[str, Any]) -> dict[str, Any]:
    log.append("add")
    return {"content": [{"type": "text", "text": str(args["a"] + args["b"])}]}

async def can_use_tool(name, tool_input, context):
    log.append(("ask", name, tool_input["command"]))
    return PermissionResultAllow(updated_input={"command": "echo changed > b.txt"})

async def prompt_hook(hook_input, tool_use_id, context):
    return {"hookSpecificOutput": {"hookEventName": "UserPromptSubmit",
                                   "additionalContext": "prompt-ctx"}}

async def post_hook(hook_input, tool_use_id, context):
    log.append(("post", hook_input["tool_name"]))
    return {"hookSpecificOutput": {"hookEventName": "PostToolUse",
                                   "additionalContext": "after-bash"}}

async def stop_hook(hook_input, tool_use_id, context):
    if hook_input["stop_hook_active"]:
        return {}
    return {"decision": "block", "reason": "keep going"}

async def main():
    server = create_sdk_mcp_server(name="calc", version="1.0", tools=[add])
    options = ClaudeAgentOptions(
        cli_path=binary, cwd=cwd, can_use_tool=can_use_tool,
        mcp_servers={"calc": server},
        allowed_tools=["mcp__calc__add"],
        disallowed_tools=["Bash(echo one:*)"],
        hooks={"UserPromptSubmit": [HookMatcher(hooks=[prompt_hook])],
               "PostToolUse": [HookMatcher(matcher="Bash", hooks=[post_hook])],
               "Stop": [HookMatcher(hooks=[stop_hook])]})
    async with ClaudeSDKClient(options=options) as client:
        await client.query("go")
        async for message in client.receive_response():
            if isinstance(message, ResultMessage):
                result = message
        status = await client.get_mcp_status()
    assert result.result == "second done" and not result.is_error, result
    assert [d["tool_name"] for d in result.permission_denials] == ["Bash"], result
    assert log == [("ask", "Bash", "echo two > b.txt"), ("post", "Bash"),
                   "add"], log
    assert status["mcpServers"][0]["status"] == "connected", status
    assert not os.path.exists(os.path.join(cwd, "a.txt"))
    assert open(os.path.join(cwd, "b.txt")).read() == "changed\n"

anyio.run(main)
PYEOF

mock_stop 5
assert_request 4 'r["body"]["messages"][-1]["content"] == "keep going"'

mock_start claude_sdk_extra.json
"$FYAI_BIN" --set "api_url=$MOCK_URL/v1/chat/completions" >/dev/null 2>&1 ||
	fail "point the project at the third mock"

"$PYTHON" - "$FYAI_BIN" "$TEST_DIR" <<'PYEOF' || fail "Python SDK structured output"
import sys

import anyio
from claude_agent_sdk import (ClaudeAgentOptions, ClaudeSDKClient,
                              ResultMessage, StreamEvent, query)

binary, cwd = sys.argv[1], sys.argv[2]

async def main():
    schema = {"type": "object", "properties": {"answer": {"type": "integer"}},
              "required": ["answer"]}
    options = ClaudeAgentOptions(
        cli_path=binary, cwd=cwd, include_partial_messages=True,
        output_format={"type": "json_schema", "schema": schema})
    events = []
    async with ClaudeSDKClient(options=options) as client:
        await client.query("answer")
        async for message in client.receive_response():
            if isinstance(message, StreamEvent):
                events.append(message.event["type"])
            if isinstance(message, ResultMessage):
                result = message
        usage = await client.get_context_usage()
    assert result.structured_output == {"answer": 42}, result
    assert events[0] == "message_start" and events[-1] == "message_stop", events
    assert usage["totalTokens"] == 24, usage

    options = ClaudeAgentOptions(cli_path=binary, cwd=cwd,
                                 resume=result.session_id, fork_session=True)
    async for message in query(prompt="fork it", options=options):
        if isinstance(message, ResultMessage):
            fork = message
    assert fork.result == "forked", fork
    assert fork.session_id != result.session_id, fork

    options = ClaudeAgentOptions(cli_path=binary, cwd=cwd,
                                 continue_conversation=True)
    async for message in query(prompt="go on", options=options):
        if isinstance(message, ResultMessage):
            assert message.session_id == fork.session_id, message
            assert message.result == "continued", message

anyio.run(main)
PYEOF

mock_stop
pass
