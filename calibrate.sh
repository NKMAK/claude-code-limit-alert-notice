#!/bin/sh
# TOKEN_BUDGET 自動キャリブレーション。
# ユーザーは Claude Code の /usage に出ている現在の5h使用率(%)を1つ入力するだけ。
# 現在の消費トークンは ccusage から自動取得し、TOKEN_BUDGET を計算して .env に書き込む。
#
# 使い方:  sh calibrate.sh         （対話入力）
#          sh calibrate.sh 30      （%を引数で渡す）
set -e
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"

pct="$1"
if [ -z "$pct" ]; then
  echo "Claude Code で /usage を実行し、表示された 5h 使用率(%) を入力してください。"
  printf "現在の使用率(%%): "
  read -r pct
fi

# 入力検証: 1〜99 の整数
case "$pct" in ''|*[!0-9]*) echo "エラー: 1〜99 の整数で入力してください（例: 30）"; exit 1;; esac
[ "$pct" -ge 1 ] && [ "$pct" -le 99 ] || { echo "エラー: 1〜99 の範囲で入力してください"; exit 1; }

CCUSAGE="$DIR/node_modules/.bin/ccusage"
[ -x "$CCUSAGE" ] || { echo "エラー: ccusage未導入。$DIR で 'npm install' を実行してください"; exit 1; }
SINCE=$(date -v-1d +%Y%m%d 2>/dev/null || date +%Y%m%d)

echo "ccusage で現在の消費トークンを取得中..."
total=$("$CCUSAGE" blocks --active --json --offline --since "$SINCE" 2>/dev/null | jq -r '.blocks[0].totalTokens // empty')
[ -n "$total" ] || { echo "エラー: アクティブな5hブロックがありません。Claude Codeを少し使ってから再実行してください。"; exit 1; }

budget=$(awk -v t="$total" -v p="$pct" 'BEGIN{ printf "%d", t*100/p }')
echo "消費トークン=$total / 入力=${pct}%  →  TOKEN_BUDGET=$budget （これが100%の目安になります）"

# .env が無ければ雛形から作成
[ -f "$ENV_FILE" ] || cp "$DIR/.env.example" "$ENV_FILE"

# TOKEN_BUDGET 行を置換（無ければ追記）
if grep -q '^[[:space:]]*TOKEN_BUDGET=' "$ENV_FILE"; then
  tmp=$(mktemp)
  sed "s|^[[:space:]]*TOKEN_BUDGET=.*|TOKEN_BUDGET=\"$budget\"|" "$ENV_FILE" > "$tmp" && mv "$tmp" "$ENV_FILE"
else
  printf '\nTOKEN_BUDGET="%s"\n' "$budget" >> "$ENV_FILE"
fi

echo "→ $ENV_FILE に書き込みました。"
echo "  あとは DISCORD_WEBHOOK_URL を設定すれば完了です。"
