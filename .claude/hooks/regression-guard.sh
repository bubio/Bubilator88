#!/bin/bash
# コミット前回帰ガード (警告型):
# コア (隣の clone ../Bubilator88Core) の Sources/ に変更がステージされた状態で
# git commit しようとしたとき、回帰テストのマーカーが staged ファイルより古ければ
# 確認を求める。コアは別リポジトリなので、コミット先がどちらでもコア側の index を見る。
INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
case "$CMD" in
  *"git commit"*|*"git -C "*" commit"*) ;;
  *) exit 0 ;;
esac
cd "$CLAUDE_PROJECT_DIR" || exit 0
CORE_DIR="${BUBILATOR88_CORE_DIR:-$CLAUDE_PROJECT_DIR/../Bubilator88Core}"
[ -d "$CORE_DIR/.git" ] || exit 0
STAGED=$(git -C "$CORE_DIR" diff --cached --name-only | grep '^Sources/' || true)
[ -z "$STAGED" ] && exit 0
MARKER=".claude/.last-regression-pass"
if [ -f "$MARKER" ]; then
  STALE=0
  while IFS= read -r f; do
    [ -f "$CORE_DIR/$f" ] && [ "$CORE_DIR/$f" -nt "$MARKER" ] && STALE=1
  done <<< "$STAGED"
  [ "$STALE" -eq 0 ] && exit 0
fi
cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"Bubilator88Core の Sources/ に変更がステージされていますが、回帰テスト (/regression) がその後実行されていません。先に /regression を実行することを推奨します (このまま続行も可能)。"}}
EOF
exit 0
