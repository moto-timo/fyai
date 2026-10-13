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
                    assert block.name == "read_file", block
                    assert block.input == {"path": "notes.txt"}, block
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
pass
