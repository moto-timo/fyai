#!/bin/bash
# Start the mock provider and the bridge for one scenario, then a chat turn.
#
#   bash server/test-turn.sh [SCENARIO] [PROMPT|-] [CONVERSATION]
#
# PROMPT of "-" starts the provider and the bridge without a turn, for a test
# that drives the page. Give FYAI_BIN, or build fyai in the project above.
# The scratch directory is $TD, by default /tmp/fyai-bridge-test.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
FY="${FYAI_BIN:-$REPO/build/fyai}"
[ -x "$FY" ] || FY="$(command -v fyai)" || {
	echo "test-turn.sh: set FYAI_BIN to the fyai program" >&2
	exit 1
}
TD=${TD:-/tmp/fyai-bridge-test}
SCENARIO=${1:-chat_stream.json}
PROMPT=${2:-hi}
SESSION=${3:-conv-1}

export HOME=$TD/home XDG_CONFIG_HOME=$TD/home/.config FYAI_AUTH_STORAGE=file
export MOCK_API_KEY=test-key
# A run starts clean: the catalogue and the configuration of an earlier run name
# the port of an earlier mock.
rm -rf "$TD/home" "$TD/work" "$TD/mock"
mkdir -p "$HOME" "$TD/work" "$TD/mock"

pkill -f "__mock-server" 2>/dev/null || true
pkill -f "server/bridge.mjs" 2>/dev/null || true
sleep 0.2
rm -f "$TD/mock/port"

cd "$TD/work"
[ -d .fyai ] || "$FY" init >/dev/null 2>&1

"$FY" __mock-server "$REPO/tests/scenarios/$SCENARIO" "$TD/mock" >"$TD/mock.log" 2>&1 &
for _ in $(seq 100); do [ -f "$TD/mock/port" ] && break; sleep 0.05; done
PORT=$(cat "$TD/mock/port")

cat >cat.yaml <<EOF
models:
- name: cat-model
  context_window: 32000
  max_output_tokens: 1234
  capabilities: [tool_calling]
providers:
- name: mock
  root_url: http://127.0.0.1:$PORT
  endpoints:
  - protocol: chat_completions
    endpoint: /v1/chat/completions
  models:
  - canonical_id: cat-model
    provider_model_id: mock-model
EOF
"$FY" catalog import cat.yaml >/dev/null 2>&1 || true
"$FY" --set api=chat-completions --set api_url="http://127.0.0.1:$PORT/v1/chat/completions" --set 'api_key={type: env, value: MOCK_API_KEY}' >/dev/null 2>&1 || true

export FYAI_BRIDGE_TOKEN=${FYAI_BRIDGE_TOKEN:-test-token}
FYAI_BIN=$FY FYAI_BRIDGE_CWD=$TD/work FYAI_BRIDGE_STATIC=$REPO/web/dist \
	FYAI_BRIDGE_PORT=9331 node "$REPO/web/server/bridge.mjs" --model cat-model \
	>"$TD/bridge.log" 2>&1 &
for _ in $(seq 100); do curl -sf -H "x-fyai-token: $FYAI_BRIDGE_TOKEN" http://127.0.0.1:9331/props >/dev/null && break; sleep 0.05; done

if [ "$PROMPT" = "-" ]; then
	echo "--- ready (no turn) ---"
	exit 0
fi

echo "--- turn ---"
curl -sS -N -X POST http://127.0.0.1:9331/api/fyai/chat \
	-H 'content-type: application/json' \
	-H "x-fyai-token: $FYAI_BRIDGE_TOKEN" \
	-d "{\"conversationId\":\"$SESSION\",\"fresh\":${FRESH:-true},\"model\":\"cat-model\",\"prompt\":\"$PROMPT\"}" |
	sed 's/^data: //' | grep -v '^$'
