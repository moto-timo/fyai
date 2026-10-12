#!/bin/bash
# SPDX-License-Identifier: MIT
# Fetch the pinned upstream kit and run both ACP protocol suites.
set -eu

FYAI_BIN="$(realpath "${1:?pass the fyai binary}")"
BUILD_DIR="$(realpath "${2:?pass the build directory}")"
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
TCK_REV="fa00ccdc13dfaa4b288a91877c1f3e468af4aa7d"
TCK_DIR="$BUILD_DIR/_deps/acp-tck"

command -v git >/dev/null || { echo "git is required" >&2; exit 2; }
command -v uv >/dev/null || { echo "uv is required" >&2; exit 2; }
if [ ! -d "$TCK_DIR/.git" ]; then
	mkdir -p "$(dirname "$TCK_DIR")"
	git clone --depth 1 https://github.com/agentclientprotocol/acp-tck.git "$TCK_DIR"
fi
if [ "$(git -C "$TCK_DIR" rev-parse HEAD)" != "$TCK_REV" ]; then
	git -C "$TCK_DIR" fetch --depth 1 origin "$TCK_REV"
	git -C "$TCK_DIR" checkout --detach "$TCK_REV"
fi

status=0
for version in 1 2; do
	echo "ACP v$version TCK ($TCK_REV)"
	if ! ACP_TCK_DIR="$TCK_DIR" ACP_TCK_VERSION="$version" \
		ACP_TCK_REPORT="$BUILD_DIR/acp-tck-v$version.json" \
		bash "$TESTS_DIR/acp_tck.sh" "$FYAI_BIN"; then
		status=1
	fi
done
exit "$status"
