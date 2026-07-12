#!/bin/sh
# Claude Code の現在の5h(セッション)使用率を `claude -p "/usage"` から取得し、
# 設定した閾値(50/80%)を超えたら Discord Webhook に通知する。
# launchd（定期実行）または Stop フックから呼ばれる想定。
# どのトリガーで実際に動くかは .env の TRIGGER_LAUNCHD / TRIGGER_HOOK で切替える
# （呼び出し元は --source で受け取る）。
#
# データ源について:
#   `claude -p "/usage" --output-format json` は Claude Code 本体と同じ
#   サーバー側のレート制限値（セッション使用率・実リセット時刻・週間使用率）を
#   返す。これはローカル処理(synthetic)で課金トークンを消費しない。
#   以前は ccusage のトークン総数÷TOKEN_BUDGET で近似していたが、実上限は
#   トークン数に正比例せず校正がすぐズレたため、正確な /usage に全面移行した。
#
# 設定の渡し方（優先順位の高い順）:
#   1. 既に export 済みの環境変数（DISCORD_WEBHOOK_URL / THRESHOLDS / DISCORD_MENTION）
#   2. スクリプトと同じ場所の .env ファイル（.env.example をコピーして作る）
#   3. 互換: ~/.claude/usage-alert.conf（USAGE_ALERT_CONF で場所を変更可）
# .env / conf は .gitignore 済みでリポジトリに含めない。

# claude は ~/.local/bin に入ることが多いので PATH に含める。
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# 呼び出し元(source)を判定する。既定は manual（手動/テスト）。
#   --source launchd : 定期実行（.env の TRIGGER_LAUNCHD で有効/無効）
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
_pre_webhook="$DISCORD_WEBHOOK_URL"; _pre_th="$THRESHOLDS"; _pre_mention="$DISCORD_MENTION"
if [ -f "$ENV_FILE" ]; then . "$ENV_FILE"
elif [ -f "$CONF" ]; then . "$CONF"
fi
[ -n "$_pre_webhook" ] && DISCORD_WEBHOOK_URL="$_pre_webhook"
[ -n "$_pre_th" ]      && THRESHOLDS="$_pre_th"
[ -n "$_pre_mention" ] && DISCORD_MENTION="$_pre_mention"

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

# claude CLI から /usage の生テキストを取得する。
# --output-format json で機械可読化し、result フィールドの本文を取り出す。
command -v claude >/dev/null 2>&1 || exit 0
raw=$(claude -p "/usage" --output-format json 2>/dev/null \
  | jq -r '.[] | select(.type=="result") | .result' 2>/dev/null)
[ -n "$raw" ] || exit 0

# 例: "Current session: 82% used · resets Jun 21 at 7:30pm (Asia/Tokyo)"
sess_line=$(printf '%s\n' "$raw" | grep -i 'Current session:' | head -1)
# 例: "Current week (all models): 13% used · resets Jun 24 at 2pm (Asia/Tokyo)"
week_line=$(printf '%s\n' "$raw" | grep -i 'Current week'    | head -1)

# 使用率(整数%)を取り出す。取れなければ誤通知を避けて終了。
pct=$(printf '%s' "$sess_line"  | grep -oE '[0-9]+% used' | head -1 | grep -oE '[0-9]+')
case "$pct" in ''|*[!0-9]*) exit 0 ;; esac

week_pct=$(printf '%s' "$week_line" | grep -oE '[0-9]+% used' | head -1 | grep -oE '[0-9]+')

# 実リセット時刻（タイムゾーン括弧を落として表示用に整える）。
# 例: "Jun 21 at 7:30pm"
sess_reset=$(printf '%s' "$sess_line" | sed -E 's/.*· *resets +//; s/ *\(.*\)$//')

# リセット時刻を日本語・24時間表記へ整形する（例 "Jun 21 at 7:30pm" → "6月21日 19:30"）。
# /usage の英語表記は年を含まないため date は当年扱いになる。年跨ぎ（12/31深夜に
# 翌年1/1のリセットを見る場合）は約1年過去と誤解釈されるので、1日以上過去なら
# 翌年として取り直す。パースできなければ英語のまま返す（通知を壊さない）。
format_reset_ja() {
  # 分なし表記("7pm"等)は date が分を現在時刻で埋めてしまうため、先に ":00" を補う。
  _r=$(printf '%s' "$1" | sed -E 's/at ([0-9]{1,2})([AaPp][Mm])$/at \1:00\2/')
  _e=$(LC_ALL=C date -j -f "%b %d at %I:%M%p" "$_r" +%s 2>/dev/null) || _e=""
  if [ -n "$_e" ] && [ "$_e" -lt $(( $(date +%s) - 86400 )) ]; then
    _y=$(( $(date +%Y) + 1 ))
    _e=$(LC_ALL=C date -j -f "%Y %b %d at %I:%M%p" "$_y $_r" +%s 2>/dev/null) || _e=""
  fi
  if [ -n "$_e" ]; then date -r "$_e" "+%-m月%-d日 %H:%M"; else printf '%s' "$1"; fi
}
sess_reset_disp=$(format_reset_ja "$sess_reset")

# 通知済みかの判定単位(window)はリセット時刻。リセット時刻が変われば新しい5h
# ウィンドウ＝発火履歴をリセットする。ただし /usage の表示は分が±1分ゆらぐ
# こと(例 7:30pm⇔7:29pm)があるため、判定キーは「分」を落として時(hour)単位に
# 丸める（隣接ウィンドウは5h差なので時+日付の衝突は起きない）。表示用の
# sess_reset は分まで正確なまま使う。状態ファイルは空白区切り2列なので
# window_id は空白を含まないよう正規化する。
window_id=$(printf '%s' "$sess_reset" | sed -E 's/:[0-9]{2}//' \
  | tr ' ' '_' | tr -cd 'A-Za-z0-9:_')
[ -n "$window_id" ] || window_id="unknown"

# 状態ファイル形式: "<windowId> <発火済み閾値カンマ区切り>"
saved_id=$(cut -d' ' -f1 "$STATE" 2>/dev/null)
saved_fired=$(cut -d' ' -f2 "$STATE" 2>/dev/null)
[ "$saved_id" = "$window_id" ] || saved_fired=""   # 新ウィンドウなら発火履歴リセット

fired="$saved_fired"
for th in $THRESHOLDS; do
  if [ "$pct" -ge "$th" ] 2>/dev/null && ! printf ',%s,' "$fired" | grep -q ",$th,"; then
    # 本文: 正確なセッション使用率＋実リセット時刻＋（取れれば）週間使用率。
    msg="⚠️ Claude 5h使用量が ${pct}% に到達"
    [ -n "$sess_reset_disp" ] && msg="$msg
リセット: ${sess_reset_disp}"
    [ -n "$week_pct" ]   && msg="$msg
週(全モデル): ${week_pct}%"
    # メンション設定があれば本文先頭に付与。allowed_mentions を明示しないと
    # Webhook ではロール/@everyone が実際に ping されないため必ず付ける。
    [ -n "$DISCORD_MENTION" ] && msg="$DISCORD_MENTION $msg"
    curl -fsS -m 10 -H "Content-Type: application/json" \
      -d "$(jq -nc --arg c "$msg" '{content:$c, allowed_mentions:{parse:["roles","users","everyone"]}}')" \
      "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1
    fired="${fired:+$fired,}$th"
  fi
done

printf '%s %s\n' "$window_id" "$fired" > "$STATE"
