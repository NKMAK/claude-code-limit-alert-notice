# claude-usage-discord-alert

Claude Code の **5時間ローリング使用量**が一定の割合（既定では 50% / 80%）に達したら **Discord に通知**する仕組み。

- 監視のトリガーは2種類。**`.env` のフラグで個別にON/OFF**できる（両方ON可）
  - **launchd**（macOS標準のスケジューラ）が5分おきに実行 … 長いターンの途中でも拾える
  - Claude Code の **Stop フック** … 応答が返り次第その場で判定（即時性が高い）
- 使用量の集計は **[ccusage](https://github.com/ryoppippi/ccusage)**（第三者製のnpmツール）を利用
- 同一マシン上の**全セッション分のログを合算**して評価する

> ⚠️ 仕組み・設計判断の詳細な経緯は [docs/article.md](docs/article.md) を参照。

---

## 構成

| ファイル | 役割 |
|---|---|
| `usage-alert.sh` | 本体。ccusageで5h消費トークンを取得→閾値判定→Discord通知 |
| `local.claude-usage-alert.plist.template` | launchd登録用テンプレート（install.shが実パスを埋めて生成） |
| `.env.example` | 設定サンプル（`.env` にコピーして使う / Webhook URL・上限トークン） |
| `install.sh` | 設定配置＋launchd登録の自動化 |
| `calibrate.sh` | `TOKEN_BUDGET` を自動算出して `.env` に書き込む（`/usage` の数字を1つ渡すだけ） |
| `package.json` | `ccusage` を**固定バージョン**で管理（`npm install` で初回取得） |
| `docs/article.md` | 記事用のまとめ（背景・調査・設計判断） |

実行時に生成されるファイル（いずれも `.gitignore` 済み）:

| パス | 役割 |
|---|---|
| `.env` | 設定の実体（**Webhook URLを含むので非git管理**。`.env.example` からコピー） |
| `~/.claude/.usage-alert-state` | 通知済み閾値の記録（ブロックごとにリセット） |
| `~/.claude/.usage-alert.log` | 実行ログ |

---

## 前提条件

- **macOS**（スケジューラに launchd を使用）
- **Node.js / npm**（`ccusage` を**固定バージョンでローカル導入**。`node -v` で確認）
  - 初回 `npm install`（= `install.sh`）で1度だけ取得。以後はネット不要・自動更新なし。
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
#    - 固定バージョンの ccusage を npm install（初回のみネット使用）
#    - スクリプトに実行権限付与
#    - .env を .env.example から作成（既存なら上書きしない）
#    - テンプレートから実パスを埋めた plist を ~/Library/LaunchAgents/ に生成し launchd へ登録
#    - ~/.claude/settings.json の Stop フックに登録（TRIGGER_HOOK=true で有効化）
sh install.sh
```

`install.sh` 実行後、`launchctl list | grep claude-usage-alert` に `local.claude-usage-alert` が出れば登録成功（5分おきに自動実行される）。

---

## 設定（2方式・どちらか）

通知に必要な設定は **`DISCORD_WEBHOOK_URL`** と **`TOKEN_BUDGET`** の2つ。

### 方式A: `.env` ファイル（launchd常駐ならこちら推奨）

プロジェクト直下の `.env` を編集する（`install.sh` が `.env.example` から作成済み）。

```sh
cp .env.example .env   # install.sh 実行済みなら作成済み
# .env を編集:
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."
TOKEN_BUDGET="32793246"      # ← 下記キャリブレーションで算出
THRESHOLDS="50 80"           # 通知する割合（%）。後述の書式参照
TRIGGER_LAUNCHD="true"       # 5分ごとの定期実行で判定する
TRIGGER_HOOK="false"         # Stopフック（応答直後）で判定する
```

#### `THRESHOLDS`（通知する割合）の書式

- スペース区切り（推奨）かカンマ区切りのどちらでも可: `"50 80 95"` / `"50,80,95"`
- 各5hブロックで**各閾値につき1回ずつ**通知。3段階なら `THRESHOLDS="50 80 95"`。
- `1〜99` の整数のみ有効。範囲外・非数値は無視。自動で昇順ソート＆重複除去される。
- 空/未設定・全部不正なら既定の `"50 80"` にフォールバック。

> launchd の定期実行はシェルの環境変数を引き継がないため、常駐運用では**この方式が確実**。
> `.env` はスクリプトと同じディレクトリに置く。`.gitignore` 済みなのでコミットされない。

### 方式B: 環境変数（手動実行・CI向け）

設定ファイルを作らず、env で直接渡すことも可能。

```sh
export DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."
export TOKEN_BUDGET=32793246
export THRESHOLDS="50 80"
sh usage-alert.sh
```

### TOKEN_BUDGET のキャリブレーション（1回だけ）

`TOKEN_BUDGET` は **「5hで使い切れるトークン数の目安」＝あなたにとっての100%**。
使用率は `消費トークン ÷ TOKEN_BUDGET × 100` で計算される。本物の5h上限は
Anthropic非公開なので、`/usage` の表示と実トークンを1回だけ突き合わせて逆算する。

#### かんたん: `calibrate.sh`（推奨）

数字を1つ入れるだけ。計算と `.env` への書き込みは自動。

```sh
# 1. Claude Code で /usage を実行し、5h使用率(%)を確認（例: 30）
# 2. その数字を渡す（対話入力でも可: 引数なしで sh calibrate.sh）
sh calibrate.sh 30
# → 現在の消費トークンを ccusage から取得し、TOKEN_BUDGET を計算して .env に保存
```

#### 手動でやる場合

```sh
node_modules/.bin/ccusage blocks --active --json --offline --since $(date -v-1d +%Y%m%d) | jq '.blocks[0].totalTokens'
# TOKEN_BUDGET = totalTokens ÷ (％ / 100)
# 例) totalTokens=9837974, /usage=30% → 9837974 / 0.30 ≒ 32793246 を .env に記入
```

> 体感とズレてきたら、また `/usage` を見て `calibrate.sh` を再実行すれば直る。

---

## トリガーの切替（launchd / Stopフック）

判定スクリプトを「いつ」走らせるかを、`.env` のフラグで切り替えられる。
`install.sh` は launchd と Stopフックの**両方を登録**するが、実際に動くかは
このフラグで決まる（設定変更のたびに launchd の load/unload や settings.json の
編集をやり直さなくて済む）。

```sh
TRIGGER_LAUNCHD="true"    # 5分ごとの定期実行（launchd）
TRIGGER_HOOK="false"      # Claude Code の Stop フック（応答が返り次第）
```

| 方式 | 即時性 | 長いターンの途中で閾値通過を捕捉 | コスト |
|---|---|---|---|
| `TRIGGER_LAUNCHD` のみ | △（最大5分） | ◎ | ~0 |
| `TRIGGER_HOOK` のみ | ◎（応答直後） | ✕（ターン終了後にしか見ない＝飛び越え得る） | ~0 |
| 両方ON | ◎ | ◎ | ~0 |

- サブエージェント多用の長いターンでは1ターンで一気に%が進み、Stopフック単体だと
  飛び越えることがある。launchd は途中でも拾えるので、**両方ON が最も取りこぼしにくい**。
- 両方ONでも、状態ファイル＋ロックにより通知は**各閾値につき1回**。
- フラグ変更は再読込不要。`.env` を保存すれば次回起動から反映される。
- 手動実行（`sh usage-alert.sh`）はフラグに関係なく常に判定する（テスト用）。

> Stopフックは `install.sh` が `~/.claude/settings.json` の `hooks.Stop` に
> `usage-alert.sh --source hook` を冪等に登録する。手動で登録する場合は次を追記:
>
> ```json
> {
>   "hooks": {
>     "Stop": [
>       { "hooks": [ { "type": "command",
>         "command": "sh /path/to/claude-usage-discord-alert/usage-alert.sh --source hook" } ] }
>     ]
>   }
> }
> ```

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

> 設定変更（Webhook・閾値・上限）は再読込不要。`.env` を保存すれば次回実行から反映される。

---

## 停止・アンインストール

```sh
launchctl unload ~/Library/LaunchAgents/local.claude-usage-alert.plist
rm ~/Library/LaunchAgents/local.claude-usage-alert.plist
```

Stopフックも外す場合は `~/.claude/settings.json` の `hooks.Stop` から
`usage-alert.sh --source hook` のエントリを削除する（または一時的に止めたいだけ
なら `.env` で `TRIGGER_HOOK="false"`）。

---

## 既知の制約

- **このマシンのClaude Code消費のみ**カウント。Web版 / 別PC / デスクトップアプリ / API併用分は
  ローカルログに残らないため拾えず、そのぶん過少になる。
- %はキャリブレーション値に基づく**近似**であり、`/usage` の公式表示と完全一致はしない。
- ccusage は第三者ツール。仕様変更・非メンテのリスクはゼロではない（自前のjq集計に置換も可能）。
