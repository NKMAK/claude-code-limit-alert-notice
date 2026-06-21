#!/bin/sh
# セットアップスクリプト:
#  - .env を雛形(.env.example)から用意（env変数で直接渡すなら不要）
#  - テンプレートから実パスを埋めて plist を生成し launchd に登録（5分おきに監視）
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="local.claude-usage-alert"
ENV_FILE="$DIR/.env"
TEMPLATE="$DIR/local.claude-usage-alert.plist.template"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"

chmod +x "$DIR/usage-alert.sh"

# 実行に必要なコマンドを確認（使用率は `claude -p "/usage"` から取得し、jq で整形）。
for cmd in claude jq curl; do
  command -v "$cmd" >/dev/null 2>&1 || echo "→ 警告: '$cmd' が見つかりません。$cmd を導入してください。"
done

if [ ! -f "$ENV_FILE" ]; then
  cp "$DIR/.env.example" "$ENV_FILE"
  echo "→ $ENV_FILE を作成しました。DISCORD_WEBHOOK_URL を設定してください。"
else
  echo "→ $ENV_FILE は既に存在（上書きしません）。"
fi

# テンプレートのプレースホルダを実パスに置換して plist 生成
# （ユーザー名や絶対パスをリポジトリに残さないための仕組み）
sed -e "s|__INSTALL_DIR__|$DIR|g" -e "s|__HOME__|$HOME|g" "$TEMPLATE" > "$PLIST_DST"

launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST"
echo "→ launchd エージェント($LABEL)を登録しました。"
launchctl list | grep claude-usage-alert || echo "（登録確認に失敗）"

# Claude Code の Stop フックに登録する（応答が返り次第ゲートを通す）。
# 登録しても TRIGGER_HOOK=false の間は何もしないので副作用なし。実際に効かせる
# には .env で TRIGGER_HOOK="true" にする。冪等（既登録ならスキップ）。
SETTINGS="$HOME/.claude/settings.json"
HOOK_CMD="sh $DIR/usage-alert.sh --source hook"
if command -v jq >/dev/null 2>&1; then
  [ -f "$SETTINGS" ] || { mkdir -p "$(dirname "$SETTINGS")"; echo '{}' > "$SETTINGS"; }
  if jq -e --arg c "$HOOK_CMD" \
       '[.. | objects | select(.type=="command") | .command] | index($c)' \
       "$SETTINGS" >/dev/null 2>&1; then
    echo "→ Stopフックは登録済み（スキップ）。"
  else
    cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
    tmp="$(mktemp)"
    jq --arg c "$HOOK_CMD" '
      .hooks //= {} | .hooks.Stop //= [] |
      .hooks.Stop += [ { "hooks": [ { "type": "command", "command": $c } ] } ]
    ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
    echo "→ $SETTINGS に Stopフックを登録しました（有効化は .env の TRIGGER_HOOK=true）。"
  fi
else
  echo "→ jq が無いため Stopフックの自動登録をスキップ。READMEの手順で手動登録してください。"
fi

echo "完了。次を設定してください:"
echo "  - .env の DISCORD_WEBHOOK_URL に Discord Webhook URL を記入"
echo "    （使用率は claude -p \"/usage\" から自動取得。TOKEN_BUDGET 校正は不要）"
echo "動作確認: sh $DIR/usage-alert.sh"
