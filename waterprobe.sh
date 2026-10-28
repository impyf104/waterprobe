#!/bin/sh
set -eu

BASE="${WATERPROBE_BASE:-https://raw.githubusercontent.com/impyf104/waterprobe/main}"

if [ "$(uname -s)" != "Linux" ]; then
	echo "waterprobe: unsupported OS $(uname -s)" >&2
	exit 2
fi

case "$(uname -m)" in
	x86_64 | amd64) ARCH=amd64 ;;
	aarch64 | arm64) ARCH=arm64 ;;
	*)
		echo "waterprobe: unsupported arch $(uname -m)" >&2
		exit 2
		;;
esac

if command -v curl >/dev/null 2>&1; then
	fetch() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
	fetch() { wget -qO "$2" "$1"; }
else
	echo "waterprobe: need curl or wget" >&2
	exit 2
fi

DIR=$(mktemp -d 2>/dev/null || mktemp -d -t waterprobe)
if ! fetch "${BASE}/waterprobe-linux-${ARCH}" "${DIR}/waterprobe"; then
	echo "waterprobe: download failed" >&2
	exit 2
fi
chmod +x "${DIR}/waterprobe"
echo "waterprobe: ${DIR}/waterprobe"
exec "${DIR}/waterprobe" "$@"
