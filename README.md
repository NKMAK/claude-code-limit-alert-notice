# claude-usage-discord-alert

Claude Code の **5時間ローリング使用量**が一定の割合（既定では 50% / 80%）に達したら **Discord に通知**する仕組み。

- 監視は **launchd**（macOS標準のスケジューラ）が5分おきに実行
- 使用量の集計は **[ccusage](https://github.com/ryoppippi/ccusage)**（第三者製のnpmツール）を利用
- 同一マシン上の**全セッション分のログを合算**して評価する

> ⚠️ 仕組み・設計判断の詳細な経緯は [docs/article.md](docs/article.md) を参照。

---

## 構成

| ファイル | 役割 |
|---|---|
| `usage-alert.sh` | 本体。ccusageで5h消費トークンを取得→閾値判定→Discord通知 |
| `local.claude-usage-alert.plist.template` | launchd登録用テンプレート（install.shが実パスを埋めて生成） |
| `usage-alert.conf.example` | 設定テンプレート（Webhook URL・上限トークン） |
| `install.sh` | 設定配置＋launchd登録の自動化 |
| `docs/article.md` | 記事用のまとめ（背景・調査・設計判断） |

実行時のファイル（リポジトリ外 = `~/.claude/`）:

| パス | 役割 |
|---|---|
| `~/.claude/usage-alert.conf` | 設定の実体（**Webhook URLを含むので非git管理**） |
| `~/.claude/.usage-alert-state` | 通知済み閾値の記録（ブロックごとにリセット） |
| `~/.claude/.usage-alert.log` | 実行ログ |

---

## 前提条件

- **macOS**（スケジューラに launchd を使用）
- **Node.js / npx**（`ccusage` を `npx` 経由で実行。`node -v` で確認）
- **jq**（JSON処理。`jq --version` で確認。無ければ `brew install jq`）
- **curl**（macOS標準で同梱）
- **Claude Code** を当該マシンで使用していること（`~/.claude/projects/**` にログが溜まる）
- Discord の **Webhook URL**（通知先チャンネルの「連携サービス」→「ウェブフック」から作成）

> ビルド（コンパイル）は不要。POSIX shスクリプトなので、配置して権限を付けるだけで動く。

---

## 導入手順（build / install）

```sh
# 1. 取得（任意の場所へ）
git clone <このリポジトリのURL> claude-usage-discord-alert
cd claude-usage-discord-alert

# 2. インストール
#    - usage-alert.sh に実行権限付与
#    - ~/.claude/usage-alert.conf を雛形から作成（既存なら上書きしない）
#    - テンプレートから実パスを埋めた plist を ~/Library/LaunchAgents/ に生成し launchd へ登録
sh install.sh
```

`install.sh` 実行後、`launchctl list | grep claude-usage-alert` に `local.claude-usage-alert` が出れば登録成功（5分おきに自動実行される）。

---

## 設定（2方式・どちらか）

通知に必要な設定は **`DISCORD_WEBHOOK_URL`** と **`TOKEN_BUDGET`** の2つ。

### 方式A: 設定ファイル（launchd常駐ならこちら推奨）

`~/.claude/usage-alert.conf` を編集する（`install.sh` が雛形を作成済み）。

```sh
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."
TOKEN_BUDGET="32793246"      # ← 下記キャリブレーションで算出
THRESHOLDS="50 80"           # 通知する割合（%）
```

> launchd の定期実行はシェルの環境変数を引き継がないため、常駐運用では**この方式が確実**。
> 設定ファイルの場所を変えたい場合は環境変数 `USAGE_ALERT_CONF` でパス指定できる。

### 方式B: 環境変数（手動実行・CI向け）

設定ファイルを作らず、env で直接渡すことも可能。

```sh
export DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."
export TOKEN_BUDGET=32793246
export THRESHOLDS="50 80"
sh usage-alert.sh
```

### TOKEN_BUDGET のキャリブレーション（1回だけ）

%の分母にあたる「自分のプランの5h上限トークン数」はAnthropic側が非公開なので、実測で割り出す。

1. Claude Code で `/usage` を実行し、現在の5h使用率を確認（例: `30%`）
2. 現在の消費トークンを取得
   ```sh
   npx -y ccusage@latest blocks --active --json | jq '.blocks[0].totalTokens'
   ```
3. `TOKEN_BUDGET = totalTokens ÷ (％ / 100)` を設定
   例) `totalTokens=9837974`, `/usage=30%` → `9837974 / 0.30 ≒ 32793246`

---

## 使い方・動作確認

設定が済めば、あとは **launchd が5分おきに自動チェック**するので操作は不要。閾値（50% / 80%）に達した時点で Discord に通知が届く。各閾値は **5hブロックごとに1回だけ**通知し、ブロックが切り替われば自動でリセットされる。

手動で1回チェックする / 動作を確認する:

```sh
sh usage-alert.sh                       # 1回だけ判定を実行
cat ~/.claude/.usage-alert-state        # 「ブロックID 発火済み閾値」が記録される
tail ~/.claude/.usage-alert.log         # 実行ログ
```

通知をすぐ試したいとき（低い閾値で強制発火）:

```sh
THRESHOLDS="1" sh usage-alert.sh        # env方式。1%で発火するので必ず通知が飛ぶ
```

> 設定変更（Webhook・閾値・上限）は再読込不要。`usage-alert.conf` を保存すれば次回実行から反映される。

---

## 停止・アンインストール

```sh
launchctl unload ~/Library/LaunchAgents/local.claude-usage-alert.plist
rm ~/Library/LaunchAgents/local.claude-usage-alert.plist
```

---

## 既知の制約

- **このマシンのClaude Code消費のみ**カウント。Web版 / 別PC / デスクトップアプリ / API併用分は
  ローカルログに残らないため拾えず、そのぶん過少になる。
- %はキャリブレーション値に基づく**近似**であり、`/usage` の公式表示と完全一致はしない。
- ccusage は第三者ツール。仕様変更・非メンテのリスクはゼロではない（自前のjq集計に置換も可能）。
