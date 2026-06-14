#!/bin/sh
# Claude Code の直近5hブロック使用量を ccusage で集計し、
# 設定した閾値(50/80%)を超えたら Discord Webhook に通知する。
# launchd から定期実行される想定。全セッション分のログを合算するため
# 同一マシン上の複数セッションはまとめて評価される。
#
# 設定: 環境変数で直接渡すか、設定ファイル(既定 ~/.claude/usage-alert.conf)で渡す。
#   - DISCORD_WEBHOOK_URL / TOKEN_BUDGET / THRESHOLDS を env で export しておけばそれを使う
#   - 設定ファイルの場所は USAGE_ALERT_CONF で上書き可能
# 秘匿情報(Webhook URL)はリポジトリに含めない。

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

CONF="${USAGE_ALERT_CONF:-$HOME/.claude/usage-alert.conf}"
STATE="$HOME/.claude/.usage-alert-state"
LOCKDIR="$HOME/.claude/.usage-alert.lock.d"

# 設定ファイルがあれば読む（無ければ環境変数だけで動作）
[ -f "$CONF" ] && . "$CONF"

# 設定が未完なら何もしない（誤通知防止）
[ -n "$DISCORD_WEBHOOK_URL" ] || exit 0
case "$TOKEN_BUDGET" in ''|*[!0-9]*) exit 0 ;; esac
[ "$TOKEN_BUDGET" -gt 0 ] || exit 0
: "${THRESHOLDS:=50 80}"

# 多重起動防止（macOSにflockが無いのでmkdirで排他）
mkdir "$LOCKDIR" 2>/dev/null || exit 0
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT INT TERM

json=$(npx -y ccusage@latest blocks --active --json 2>/dev/null)
[ -n "$json" ] || exit 0

block_id=$(printf '%s' "$json" | jq -r '.blocks[0].id // empty')
total=$(printf '%s' "$json" | jq -r '.blocks[0].totalTokens // 0')
[ -n "$block_id" ] || exit 0   # アクティブな5hブロックなし

pct=$(awk -v t="$total" -v b="$TOKEN_BUDGET" 'BEGIN{ printf "%.0f", t*100/b }')

# 状態ファイル形式: "<blockId> <発火済み閾値カンマ区切り>"
saved_id=$(cut -d' ' -f1 "$STATE" 2>/dev/null)
saved_fired=$(cut -d' ' -f2 "$STATE" 2>/dev/null)
[ "$saved_id" = "$block_id" ] || saved_fired=""   # 新ブロックならリセット

fired="$saved_fired"
for th in $THRESHOLDS; do
  if [ "$pct" -ge "$th" ] 2>/dev/null && ! printf ',%s,' "$fired" | grep -q ",$th,"; then
    msg=$(printf '⚠️ Claude 5h使用量が **%s%%** に到達 (閾値 %s%%)\nトークン: %s / %s\n残り: あと %s%% でリセットまで継続' \
      "$pct" "$th" "$total" "$TOKEN_BUDGET" "$((100 - pct))")
    curl -fsS -m 10 -H "Content-Type: application/json" \
      -d "$(jq -nc --arg c "$msg" '{content:$c}')" \
      "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1
    fired="${fired:+$fired,}$th"
  fi
done

printf '%s %s\n' "$block_id" "$fired" > "$STATE"
