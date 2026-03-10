#!/usr/bin/env bash
# Sync skills/verify/SKILL.md to ~/.claude/skills/verify/SKILL.md after any edit.
# Triggered by PostToolUse hook for Write and Edit tools.

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input', {}).get('file_path', ''))" 2>/dev/null)

case "$FILE_PATH" in
  *skills/verify/SKILL.md)
    cp "$FILE_PATH" ~/.claude/skills/verify/SKILL.md
    echo "synced skills/verify/SKILL.md → ~/.claude/skills/verify/SKILL.md" >&2
    ;;
  *skills/verify-setup/SKILL.md)
    cp "$FILE_PATH" ~/.claude/skills/verify-setup/SKILL.md
    echo "synced skills/verify-setup/SKILL.md → ~/.claude/skills/verify-setup/SKILL.md" >&2
    ;;
esac
