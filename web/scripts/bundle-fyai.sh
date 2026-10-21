#!/bin/bash
# SPDX-License-Identifier: MIT
#
# Put a standalone fyai beside the page, so that a packaged desktop app can
# carry it and run on a machine that has no fyai of its own.
#
#   scripts/bundle-fyai.sh                 # build a portable one with Docker
#   scripts/bundle-fyai.sh --from PATH     # copy an existing static binary
#   scripts/bundle-fyai.sh --check         # report what would be bundled
#
# The result is fyai-bundle/fyai. A fully static build is what travels: it
# needs no libc, no shared library and no toolchain on the machine that runs
# the app. Build it from the fyai repository (docker/Dockerfile.static).
#
# The default mode is `mostly`: static fyai dependencies over the host libc,
# which every glibc Linux has. Build the fully static musl binary with
# --mode musl, but see the note in README.md: it sends "stream": 1 where the
# provider requires a boolean.
set -eu

cd "$(dirname "$0")/.."

OUT="fyai-bundle"
FROM=""
REPO="${FYAI_SRC:-../}"
MODE="${FYAI_STATIC_MODE:-mostly}"

usage() {
	cat <<'EOF'
Bundle a standalone fyai for the desktop app.

  scripts/bundle-fyai.sh                build a portable fyai with Docker
  scripts/bundle-fyai.sh --from PATH    copy an existing binary
  scripts/bundle-fyai.sh --check        report what would be bundled

Options: --from PATH, --mode mostly|musl, --check, -h.
Environment: FYAI_SRC (the fyai repository, default the one above web/),
             FYAI_STATIC_MODE (mostly, the default, or musl).
The mode names the docker STATIC_MODE: `mostly` links the fyai dependencies
statically over the host libc; `musl` is fully static but bad JSON booleans.
EOF
	exit "${1:-0}"
}

CHECK=0
while [ $# -gt 0 ]; do
	case "$1" in
	--from)
		if [ $# -lt 2 ] || [ -z "$2" ]; then
			echo "bundle-fyai.sh: --from needs the path of a binary" >&2
			exit 1
		fi
		FROM="$2"
		shift 2
		;;
	--mode)
		if [ $# -lt 2 ] || [ -z "$2" ]; then
			echo "bundle-fyai.sh: --mode needs mostly or musl" >&2
			exit 1
		fi
		MODE="$2"
		shift 2
		;;
	--check) CHECK=1; shift ;;
	-h | --help) usage 0 ;;
	*) echo "bundle-fyai.sh: unknown option '$1'" >&2; usage 1 >&2 ;;
	esac
done

report() {
	local bin="$1"
	local other

	echo "bundle-fyai.sh: $bin"
	"$bin" --version 2>/dev/null | head -1 | sed 's/^/bundle-fyai.sh: /'
	if file "$bin" | grep -q "statically linked"; then
		echo "bundle-fyai.sh: static, so the app needs no fyai on the machine"
		return
	fi

	# The libc, libm and the loader are the host's; anything else must travel.
	other="$(ldd "$bin" 2>/dev/null |
		awk '{print $1}' |
		grep -vE '^(linux-vdso|libc|libm|ld-linux|/lib.*ld-linux)' || true)"

	if [ -z "$other" ]; then
		echo "bundle-fyai.sh: needs only the host libc, as every Linux has"
	else
		echo "bundle-fyai.sh: needs these libraries, which the app does not carry:" >&2
		printf '  %s\n' "$other" >&2
		echo "bundle-fyai.sh: bundle a mostly or musl static build instead" >&2
	fi
}

if [ "$CHECK" = 1 ]; then
	if [ -x "$OUT/fyai" ]; then
		report "$OUT/fyai"
	else
		echo "bundle-fyai.sh: no $OUT/fyai yet"
	fi
	exit 0
fi

mkdir -p "$OUT"

if [ -n "$FROM" ]; then
	if [ ! -x "$FROM" ]; then
		echo "bundle-fyai.sh: '$FROM' is not an executable" >&2
		exit 1
	fi
	cp "$FROM" "$OUT/fyai"
	chmod 755 "$OUT/fyai"
	report "$OUT/fyai"
	exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
	echo "bundle-fyai.sh: docker is needed to build a static fyai; use --from PATH" >&2
	exit 1
fi
if [ ! -f "$REPO/docker/Dockerfile.static" ]; then
	echo "bundle-fyai.sh: no fyai repository at '$REPO'; set FYAI_SRC" >&2
	exit 1
fi

IMAGE="fyai-$MODE-static"
echo "bundle-fyai.sh: building $IMAGE with STATIC_MODE=$MODE (this takes a while)"
docker build -f "$REPO/docker/Dockerfile.static" --build-arg "STATIC_MODE=$MODE" \
	-t "$IMAGE" "$REPO"

# Copy the binary out of the image without running it.
cid="$(docker create "$IMAGE")"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
docker cp "$cid:/usr/local/bin/fyai" "$OUT/fyai"
chmod 755 "$OUT/fyai"

report "$OUT/fyai"
