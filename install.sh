#!/bin/sh
# セットアップスクリプト:
#  - 設定ファイルを ~/.claude/usage-alert.conf に用意（env管理する場合は不要）
#  - テンプレートから実パスを埋めて plist を生成し launchd に登録（5分おきに監視）
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="local.claude-usage-alert"
CONF="${USAGE_ALERT_CONF:-$HOME/.claude/usage-alert.conf}"
TEMPLATE="$DIR/local.claude-usage-alert.plist.template"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"

chmod +x "$DIR/usage-alert.sh"

if [ ! -f "$CONF" ]; then
  cp "$DIR/usage-alert.conf.example" "$CONF"
  echo "→ $CONF を作成しました。DISCORD_WEBHOOK_URL と TOKEN_BUDGET を設定してください。"
else
  echo "→ $CONF は既に存在（上書きしません）。"
fi

# テンプレートのプレースホルダを実パスに置換して plist 生成
# （ユーザー名や絶対パスをリポジトリに残さないための仕組み）
sed -e "s|__INSTALL_DIR__|$DIR|g" -e "s|__HOME__|$HOME|g" "$TEMPLATE" > "$PLIST_DST"

launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST"
echo "→ launchd エージェント($LABEL)を登録しました。"
launchctl list | grep claude-usage-alert || echo "（登録確認に失敗）"

echo "完了。設定後の動作確認: sh $DIR/usage-alert.sh"
