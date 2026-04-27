#!/bin/bash
# install-cli.sh — Compile and install the aki CLI to /usr/local/bin
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLI_SOURCE="$SCRIPT_DIR/aki-cli"
INSTALL_DIR="/usr/local/bin"
INSTALL_PATH="$INSTALL_DIR/aki"

if [ ! -f "$CLI_SOURCE" ]; then
    echo "error: aki-cli not found at $CLI_SOURCE" >&2
    exit 1
fi

# swiftc requires a .swift extension to recognise the input as Swift source.
TEMP_SOURCE="$(mktemp /tmp/aki-cli-XXXXXX.swift)"
trap 'rm -f "$TEMP_SOURCE"' EXIT

# Strip the shebang line (if present) so swiftc doesn't choke on it.
tail -n +2 "$CLI_SOURCE" > "$TEMP_SOURCE"

echo "Compiling aki CLI..."
swiftc -O "$TEMP_SOURCE" -o "$INSTALL_PATH"

chmod +x "$INSTALL_PATH"

echo "✅ Installed to $INSTALL_PATH"
echo "   Try: aki health"
