#!/bin/bash
#
# Convenience: prints (does not apply) the Claude Code hook configuration that
# wires the approval bridge into ~/.claude/settings.json.
#
# This deliberately does not edit the file for you. NotchScotch writing into
# another tool's config behind your back is exactly the kind of thing you should
# not accept from a utility app -- and it would be clobbered the moment you
# hand-edit that file yourself.
set -euo pipefail

SCRIPT_PATH="$HOME/.notchscotch/nb-approve"

if [ ! -x "$SCRIPT_PATH" ]; then
  echo "The bridge script isn't there yet. Launch NotchScotch once -- it writes"
  echo "$SCRIPT_PATH on startup -- then run this again."
  exit 1
fi

echo "Bridge script:  $SCRIPT_PATH"
echo ""
echo "Read it first (it's 20 lines of shell):"
echo "    cat $SCRIPT_PATH"
echo ""
echo "Then add this to ~/.claude/settings.json:"
echo ""
cat <<JSON
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|Write|Edit|MultiEdit",
        "hooks": [
          { "type": "command", "command": "$SCRIPT_PATH" }
        ]
      }
    ]
  }
}
JSON
echo ""
echo "The matcher controls which tools ask. Widen or narrow it to taste."
