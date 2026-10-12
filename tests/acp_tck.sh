#!/bin/bash
# SPDX-License-Identifier: MIT
# Run the upstream ACP compatibility kit against an isolated fyai arena.
set -eu

FYAI_BIN="$(realpath "${1:?pass the fyai binary}")"
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ACP_TCK_DIR="${ACP_TCK_DIR:?set ACP_TCK_DIR to an acp-tck checkout}"
ACP_TCK_DIR="$(realpath "$ACP_TCK_DIR")"
ACP_TCK_VERSION="${ACP_TCK_VERSION:-1}"
case "$ACP_TCK_VERSION" in 1|2) ;; *) echo "ACP_TCK_VERSION must be 1 or 2" >&2; exit 2 ;; esac
command -v uv >/dev/null || { echo "uv is required" >&2; exit 2; }
test -f "$ACP_TCK_DIR/pyproject.toml" || { echo "ACP_TCK_DIR is not an acp-tck checkout" >&2; exit 2; }

. "$TESTS_DIR/harness.sh"
fyai_test_setup
trap 'mock_stop_quiet; rm -rf "$TEST_DIR"' EXIT

"$PYTHON" - > acp-tck-scenario.json <<'PYEOF'
import json
import sys

reply = {
    "id": "chatcmpl-acp-tck",
    "object": "chat.completion",
    "created": 1735689600,
    "model": "mock-model",
    "choices": [{"index": 0, "message": {"role": "assistant", "content": "ACP test reply."},
                 "finish_reason": "stop"}],
    "usage": {"prompt_tokens": 12, "completion_tokens": 4, "total_tokens": 16},
}
steps = [{"match": {"body_contains": "ACP cancellation probe"},
          "delay": 8, "response": reply} for _ in range(32)]
steps.extend({"match": {}, "response": reply} for _ in range(1024))
json.dump({"steps": steps}, sys.stdout)
PYEOF
mock_start acp-tck-scenario.json

report="${ACP_TCK_REPORT:-/tmp/fyai-acp-tck-v${ACP_TCK_VERSION}.json}"
filter=()
if [ -n "${ACP_TCK_FILTER:-}" ]; then
	filter=(-k "$ACP_TCK_FILTER")
fi
set +e
uv --project "$ACP_TCK_DIR" run acp-tck \
	--protocol-version "$ACP_TCK_VERSION" \
	--agent-cwd "$TEST_DIR" \
	--timeout 20 --test-timeout 60 \
	--cancel-prompt "ACP cancellation probe" \
	--report-json "$report" \
	"${filter[@]}" \
	-- "$FYAI_BIN" -k test-key \
	--set api=chat-completions \
	--set display/stream=false \
	--set "api_url=$MOCK_URL/v1/chat/completions" \
	-m mock-model acp
status=$?
set -e
mock_stop_quiet
echo "ACP TCK report: $report"
exit "$status"
