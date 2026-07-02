#!/bin/bash
# コミット前回帰ガード (警告型):
# EmulatorCore/Sources の変更がステージされたコミットで、
# 回帰テストのマーカーが staged ファイルより古い場合に確認を求める。
INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
case "$CMD" in
  *"git commit"*) ;;
  *) exit 0 ;;
esac
cd "$CLAUDE_PROJECT_DIR" || exit 0
STAGED=$(git diff --cached --name-only | grep '^Packages/EmulatorCore/Sources/' || true)
[ -z "$STAGED" ] && exit 0
MARKER=".claude/.last-regression-pass"
if [ -f "$MARKER" ]; then
  STALE=0
  while IFS= read -r f; do
    [ -f "$f" ] && [ "$f" -nt "$MARKER" ] && STALE=1
  done <<< "$STAGED"
  [ "$STALE" -eq 0 ] && exit 0
fi
cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"EmulatorCore/Sources の変更がステージされていますが、回帰テスト (/regression) がその後実行されていません。先に /regression を実行することを推奨します (このまま続行も可能)。"}}
EOF
exit 0
