#!/usr/bin/env bash
# Launch AgentTUI in an isolated WezTerm window
# This does NOT affect your existing WezTerm configuration

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/src/agenttui.lua"

if ! command -v wezterm &>/dev/null; then
    echo "Error: wezterm not found in PATH. Please install WezTerm first." >&2
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file not found: $CONFIG_FILE" >&2
    exit 1
fi

echo "Launching AgentTUI..."
echo "Config: $CONFIG_FILE"
echo "(Your existing WezTerm config is not affected)"

exec wezterm --config-file "$CONFIG_FILE" "$@"
