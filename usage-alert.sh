#!/bin/sh
# Claude Code の直近5hブロック使用量を ccusage で集計し、
# 設定した閾値(50/80%)を超えたら Discord Webhook に通知する。
# launchd（定期実行）または Stop フック（応答直後）から呼ばれる想定。
# どのトリガーで実際に動くかは .env の TRIGGER_LAUNCHD / TRIGGER_HOOK で切替える
# （呼び出し元は --source で受け取る）。全セッション分のログを合算するため
# 同一マシン上の複数セッションはまとめて評価される。
#
# 設定の渡し方（優先順位の高い順）:
#   1. 既に export 済みの環境変数（DISCORD_WEBHOOK_URL / TOKEN_BUDGET / THRESHOLDS）
#   2. スクリプトと同じ場所の .env ファイル（.env.example をコピーして作る）
#   3. 互換: ~/.claude/usage-alert.conf（USAGE_ALERT_CONF で場所を変更可）
# .env / conf は .gitignore 済みでリポジトリに含めない。

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# 呼び出し元(source)を判定する。既定は manual（手動/テスト）。
#   --source launchd : 5分ごとの定期実行（.env の TRIGGER_LAUNCHD で有効/無効）
#   --source hook    : Claude Code の Stop フック（.env の TRIGGER_HOOK で有効/無効）
#   --source manual  : 人間が直接実行。フラグに関係なく常に動く（テスト用の抜け道）
SOURCE="manual"
while [ $# -gt 0 ]; do
  case "$1" in
    --source) SOURCE="$2"; shift 2 ;;
    --source=*) SOURCE="${1#*=}"; shift ;;
    *) shift ;;
  esac
done

# Stopフックは stdin に JSON を渡してくる。本ツールは使わないので読み捨てる
# （端末からの手動実行時は stdin がttyなので読まない）。
[ -t 0 ] || cat >/dev/null 2>&1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
CONF="${USAGE_ALERT_CONF:-$HOME/.claude/usage-alert.conf}"
STATE="$HOME/.claude/.usage-alert-state"
LOCKDIR="$HOME/.claude/.usage-alert.lock.d"

# 既存の環境変数を最優先にしつつ、未設定分を .env → conf の順で補完する
_pre_webhook="$DISCORD_WEBHOOK_URL"; _pre_budget="$TOKEN_BUDGET"; _pre_th="$THRESHOLDS"
if [ -f "$ENV_FILE" ]; then . "$ENV_FILE"
elif [ -f "$CONF" ]; then . "$CONF"
fi
[ -n "$_pre_webhook" ] && DISCORD_WEBHOOK_URL="$_pre_webhook"
[ -n "$_pre_budget" ]  && TOKEN_BUDGET="$_pre_budget"
[ -n "$_pre_th" ]      && THRESHOLDS="$_pre_th"

# トリガー別のON/OFFを .env のフラグで判定する。
# 未設定時の既定: launchd=ON（従来動作の互換）, hook=OFF。
# 該当トリガーが無効なら、判定すらせず黙って終了する（呼び出し側は両方が常に
# このスクリプトを叩くが、実際に動くかはここで決まる）。manual は常に実行。
: "${TRIGGER_LAUNCHD:=true}"
: "${TRIGGER_HOOK:=false}"
case "$SOURCE" in
  launchd) [ "$TRIGGER_LAUNCHD" = "true" ] || exit 0 ;;
  hook)    [ "$TRIGGER_HOOK" = "true" ]    || exit 0 ;;
esac

# 設定が未完なら何もしない（誤通知防止）
[ -n "$DISCORD_WEBHOOK_URL" ] || exit 0
case "$TOKEN_BUDGET" in ''|*[!0-9]*) exit 0 ;; esac
[ "$TOKEN_BUDGET" -gt 0 ] || exit 0

# 閾値の正規化: カンマ区切りも許容(→空白化)、1〜99の整数のみ採用し、
# 昇順ソート＋重複除去する。不正値・範囲外は黙って捨てる。
# 結果が空(未設定/全部不正)なら従来どおり既定 "50 80" にフォールバック。
THRESHOLDS=$(printf '%s' "${THRESHOLDS:-}" | tr ',' ' ' | tr ' ' '\n' \
  | grep -E '^[0-9]+$' | awk '$1>=1 && $1<=99' | sort -n -u | tr '\n' ' ')
THRESHOLDS="${THRESHOLDS% }"
[ -n "$THRESHOLDS" ] || THRESHOLDS="50 80"

# メンション対象(.env の DISCORD_MENTION)。空ならメンションなし(従来動作)。
DISCORD_MENTION="${DISCORD_MENTION:-}"

# 多重起動防止（macOSにflockが無いのでmkdirで排他）
mkdir "$LOCKDIR" 2>/dev/null || exit 0
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT INT TERM

# 固定バージョンのローカル ccusage を使用（npxの毎回更新・ネット問い合わせを排除）。
# --offline: 料金データ取得をしない（本ツールはtotalTokensしか使わない）
# --since 昨日: 走査対象を直近に限定（履歴肥大対策）
CCUSAGE="$SCRIPT_DIR/node_modules/.bin/ccusage"
[ -x "$CCUSAGE" ] || { echo "ccusage未導入: $SCRIPT_DIR で 'npm install' を実行してください" >&2; exit 0; }
SINCE=$(date -v-1d +%Y%m%d 2>/dev/null || date +%Y%m%d)

json=$("$CCUSAGE" blocks --active --json --offline --since "$SINCE" 2>/dev/null)
[ -n "$json" ] || exit 0

block_id=$(printf '%s' "$json" | jq -r '.blocks[0].id // empty')
total=$(printf '%s' "$json" | jq -r '.blocks[0].totalTokens // 0')
end_time=$(printf '%s' "$json" | jq -r '.blocks[0].endTime // empty')
[ -n "$block_id" ] || exit 0   # アクティブな5hブロックなし

pct=$(awk -v t="$total" -v b="$TOKEN_BUDGET" 'BEGIN{ printf "%.0f", t*100/b }')

# 5hブロック終了(=リセット)までの残り時間を計算する。
# endTime は UTC の ISO8601 (例 "2026-06-14T10:00:00.000Z")。ミリ秒/Zを落として
# UTC としてepoch化し、現在との差から「あと約N時間」とローカル時刻(Asia/Tokyo)を作る。
reset_info=""
if [ -n "$end_time" ]; then
  end_base="${end_time%.*}"; end_base="${end_base%Z}"
  end_epoch=$(date -ju -f "%Y-%m-%dT%H:%M:%S" "$end_base" +%s 2>/dev/null)
  now_epoch=$(date +%s)
  if [ -n "$end_epoch" ] && [ "$end_epoch" -gt "$now_epoch" ]; then
    remain_h=$(awk -v e="$end_epoch" -v n="$now_epoch" 'BEGIN{ printf "%.1f", (e-n)/3600 }')
    local_hm=$(date -r "$end_epoch" +%H:%M 2>/dev/null)
    reset_info="5hリセットまで あと約 ${remain_h}時間（${local_hm}）"
  fi
fi

# 状態ファイル形式: "<blockId> <発火済み閾値カンマ区切り>"
saved_id=$(cut -d' ' -f1 "$STATE" 2>/dev/null)
saved_fired=$(cut -d' ' -f2 "$STATE" 2>/dev/null)
[ "$saved_id" = "$block_id" ] || saved_fired=""   # 新ブロックならリセット

fired="$saved_fired"
for th in $THRESHOLDS; do
  if [ "$pct" -ge "$th" ] 2>/dev/null && ! printf ',%s,' "$fired" | grep -q ",$th,"; then
    # 本文: 使用率＋（取得できれば）リセットまでの残り時間。
    # トークン数・閾値の表記は出さない。
    msg="⚠️ Claude 5h使用量が ${pct}% に到達"
    [ -n "$reset_info" ] && msg="$msg
$reset_info"
    # メンション設定があれば本文先頭に付与。allowed_mentions を明示しないと
    # Webhook ではロール/@everyone が実際に ping されないため必ず付ける。
    [ -n "$DISCORD_MENTION" ] && msg="$DISCORD_MENTION $msg"
    curl -fsS -m 10 -H "Content-Type: application/json" \
      -d "$(jq -nc --arg c "$msg" '{content:$c, allowed_mentions:{parse:["roles","users","everyone"]}}')" \
      "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1
    fired="${fired:+$fired,}$th"
  fi
done

printf '%s %s\n' "$block_id" "$fired" > "$STATE"
