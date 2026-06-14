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

if [ ! -f "$ENV_FILE" ]; then
  cp "$DIR/.env.example" "$ENV_FILE"
  echo "→ $ENV_FILE を作成しました。DISCORD_WEBHOOK_URL と TOKEN_BUDGET を設定してください。"
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

echo "完了。次の2つを設定してください:"
echo "  1) .env の DISCORD_WEBHOOK_URL に Discord Webhook URL を記入"
echo "  2) TOKEN_BUDGET を自動算出: /usage の%を見て  sh $DIR/calibrate.sh <%>"
echo "動作確認: sh $DIR/usage-alert.sh"
