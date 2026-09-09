#!/bin/bash
set -euo pipefail

LABEL="local.claude-usage"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x ClaudeUsage 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/Claude Usage.app"
rm -rf "$HOME/Library/Application Support/Claude Usage"
rm -f "$HOME/Library/Logs/ClaudeUsage.log"

echo "Removed Claude Usage"
