# claude-usage-discord-alert

Claude Code の **5時間ローリング使用量**が一定の割合（既定では 50% / 80%）に達したら **Discord に通知**する仕組み。

> 🚀 **セットアップは Claude Code にお任せできます** — clone してリポジトリ内で
> Claude Code を起動し **`/setup`** を実行すると、使い方のヒアリング（閾値・メンション・
> トリガー）から `.env` 生成・launchd 登録・実通知テストまで対話形式で完了します。
> 詳細は [導入手順](#導入手順build--install) を参照。

- 監視のトリガーは2種類。**`.env` のフラグで個別にON/OFF**できる（両方ON可）
  - **launchd**（macOS標準のスケジューラ）が5分おきに実行 … 長いターンの途中でも拾える
  - Claude Code の **Stop フック** … 応答が返り次第その場で判定（即時性が高い）
- 使用率は **`claude -p "/usage"`** から Claude Code 本体と同じ**サーバー側の正確な値**
  （セッション使用率・実リセット時刻・週間使用率）を取得する。この呼び出しは
  ローカル処理(synthetic)で**課金トークンを消費しない**
- 通知には**正確な使用率・実リセット時刻・週間使用率**を載せる

> ⚠️ 仕組み・設計判断の詳細な経緯は [docs/article.md](docs/article.md) を参照。

## 動作環境

| 項目 | 要件 |
|---|---|
| OS | **macOS**（スケジューラに launchd、ビルドに Xcode Command Line Tools を使用。Linux/Windows 非対応） |
| Claude | **Claude Code (`claude` CLI)** ログイン済み（サブスクの使用量制限がある Pro/Max プラン向け） |
| 通知先 | **Discord**（Webhook を作成できるサーバー/チャンネル） |
| その他 | `jq`（`brew install jq`）、`curl`（macOS 標準） |

対話セットアップ（`/setup` スキル）を使う場合も Claude Code 上で動くため、追加の環境は不要。
詳細は後述の[前提条件](#前提条件)を参照。

---

## 構成

| ファイル | 役割 |
|---|---|
| `usage-alert.sh` | 本体。`claude -p "/usage"` で使用率を取得→閾値判定→Discord通知 |
| `launchd-runner.c` | launchd起点の安定ラッパー（macOS 26 のTCC許可ダイアログ対策。詳細はファイル冒頭コメント） |
| `local.claude-usage-alert.plist.template` | launchd登録用テンプレート（install.shが実パスを埋めて生成） |
| `.env.example` | 設定サンプル（`.env` にコピーして使う / Webhook URL ほか） |
| `install.sh` | 設定配置＋launchd登録の自動化 |
| `docs/article.md` | 記事用のまとめ（背景・調査・設計判断） |

実行時に生成されるファイル（いずれも `.gitignore` 済み）:

| パス | 役割 |
|---|---|
| `.env` | 設定の実体（**Webhook URLを含むので非git管理**。`.env.example` からコピー） |
| `bin/usage-alert-runner` | launchd-runner.c のビルド成果物（install.sh が生成・ad-hoc署名） |
| `~/.claude/.usage-alert-state` | 通知済み閾値の記録（5hウィンドウごとにリセット） |
| `~/.claude/.usage-alert.log` | 実行ログ |

---

## 前提条件

- **macOS**（スケジューラに launchd を使用）
- **Claude Code (`claude` CLI)** に**ログイン済み**であること（`claude -p "/usage"` で
  使用率を取得するため。サブスク/トークン認証が有効な状態）
- **jq**（JSON処理。`jq --version` で確認。無ければ `brew install jq`）
- **curl**（macOS標準で同梱）
- **cc（Xcode Command Line Tools）**（launchd用ラッパーのビルドに使用。無ければ `xcode-select --install`）
- Discord の **Webhook URL**（通知先チャンネルの「連携サービス」→「ウェブフック」から作成）

> 本体は POSIX shスクリプト。コンパイルが要るのは launchd 用の小さなラッパー
> （`launchd-runner.c`）1ファイルだけで、`install.sh` が自動でビルドする。

---

## 導入手順（build / install）

### Claude Code で対話セットアップ（推奨）

このリポジトリを clone して Claude Code で開き、`/setup` を実行すると、
使い方のヒアリング（閾値・メンション・トリガー）→ `.env` 生成 → `install.sh` 実行 →
実通知テストまでを対話形式で進められる。Discord Webhook の作り方や
フルディスクアクセスの付与手順もその場で案内される。

```sh
git clone <このリポジトリのURL> claude-usage-discord-alert
cd claude-usage-discord-alert
claude   # Claude Code を起動して「/setup」を実行
```

### 手動セットアップ

```sh
# 1. 取得（任意の場所へ）
git clone <このリポジトリのURL> claude-usage-discord-alert
cd claude-usage-discord-alert

# 2. インストール
#    - 必要コマンド(claude/jq/curl)の存在チェック
#    - スクリプトに実行権限付与
#    - .env を .env.example から作成（既存なら上書きしない）
#    - launchd用ラッパー bin/usage-alert-runner をビルド＋ad-hoc署名
#    - テンプレートから実パスを埋めた plist を ~/Library/LaunchAgents/ に生成し launchd へ登録
#    - ~/.claude/settings.json の Stop フックに登録（TRIGGER_HOOK=true で有効化）
sh install.sh
```

`install.sh` 実行後、`launchctl list | grep claude-usage-alert` に `local.claude-usage-alert` が出れば登録成功（5分おきに自動実行される）。

### macOS 26 (Tahoe) 以降: フルディスクアクセスの付与（推奨）

macOS 26 の「アプリのデータ保護」により、launchd 経由の `claude -p` 実行時に
「**ほかのアプリからのデータへのアクセス**」の許可ダイアログが出ることがある。
出ないようにするには、**システム設定 → プライバシーとセキュリティ → フルディスクアクセス**
で「＋」→ `Cmd+Shift+G` でリポジトリ内の `bin/usage-alert-runner` を指定して追加・ONにする。

- launchd の起点をこの安定ラッパーにしているため、**許可は1回で恒久化**される。
  `/bin/sh` 起点だと許可が claude 本体（バージョンごとに別ファイル）に紐づき、
  Claude Code の自動更新のたびにダイアログが再出現してしまう
  （背景: [anthropics/claude-code#36832](https://github.com/anthropics/claude-code/issues/36832)）。
- 付与しない場合も、初回に出るダイアログ（要求元「usage-alert-runner」）を
  一度「許可」すれば以後は出ない。
- `.env` の `DISCORD_WEBHOOK_URL` が未設定の間は claude を呼ばないため、
  install 直後〜この付与までの間にダイアログが出ることはない。

---

## 設定（2方式・どちらか）

通知に必要な設定は **`DISCORD_WEBHOOK_URL`** だけ（使用率は `/usage` から取得するので
トークン上限の校正は不要）。

### 方式A: `.env` ファイル（launchd常駐ならこちら推奨）

プロジェクト直下の `.env` を編集する（`install.sh` が `.env.example` から作成済み）。

```sh
cp .env.example .env   # install.sh 実行済みなら作成済み
# .env を編集:
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."
THRESHOLDS="50 80"           # 通知する割合（%）。後述の書式参照
DISCORD_MENTION=""           # メンション対象。空ならなし。後述参照
TRIGGER_LAUNCHD="true"       # 5分ごとの定期実行で判定する
TRIGGER_HOOK="false"         # Stopフック（応答直後）で判定する
```

#### `THRESHOLDS`（通知する割合）の書式

- スペース区切り（推奨）かカンマ区切りのどちらでも可: `"50 80 95"` / `"50,80,95"`
- 各5hウィンドウで**各閾値につき1回ずつ**通知。3段階なら `THRESHOLDS="50 80 95"`。
- `1〜99` の整数のみ有効。範囲外・非数値は無視。自動で昇順ソート＆重複除去される。
- 空/未設定・全部不正なら既定の `"50 80"` にフォールバック。

#### `DISCORD_MENTION`（メンション・任意）

通知の先頭に `@` メンションを付けられる。空ならメンションなし（既定）。

```sh
DISCORD_MENTION="@everyone"                  # 全員
DISCORD_MENTION="<@123456789012345678>"      # 特定ユーザー
DISCORD_MENTION="<@&123456789012345678>"     # 特定ロール
```

対象IDは Discord の開発者モードをON（設定→詳細設定）にしてから、ユーザー/ロールを
右クリック →「IDをコピー」で取得する。ロール/@everyone を実際に ping させるための
`allowed_mentions` はスクリプト側で自動付与される。なお `@everyone` は受信側で
抑制されやすくデスクトップ通知が出ないことがあるため、自分宛て通知には
ユーザーメンション `<@自分のID>` が確実。

> launchd の定期実行はシェルの環境変数を引き継がないため、常駐運用では**この方式が確実**。
> `.env` はスクリプトと同じディレクトリに置く。`.gitignore` 済みなのでコミットされない。

### 方式B: 環境変数（手動実行・CI向け）

設定ファイルを作らず、env で直接渡すことも可能。

```sh
export DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."
export THRESHOLDS="50 80"
sh usage-alert.sh
```

> 使用率は `claude -p "/usage"` から取得する正確な値なので、以前必要だった
> `TOKEN_BUDGET` の校正（`calibrate.sh`）は不要になった。`.env` に `TOKEN_BUDGET` が
> 残っていても単に無視される。

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

設定が済めば、あとは **launchd が5分おきに自動チェック**するので操作は不要。閾値（50% / 80%）に達した時点で Discord に通知が届く。各閾値は **5hウィンドウごとに1回だけ**通知し、リセット時刻が変わって新しいウィンドウになれば自動でリセットされる。

手動で1回チェックする / 動作を確認する:

```sh
sh usage-alert.sh                       # 1回だけ判定を実行
cat ~/.claude/.usage-alert-state        # 「ウィンドウID 発火済み閾値」が記録される
tail ~/.claude/.usage-alert.log         # 実行ログ
```

通知をすぐ試したいとき（低い閾値で強制発火）:

```sh
THRESHOLDS="1" sh usage-alert.sh        # env方式。1%で発火するので必ず通知が飛ぶ
```

> 設定変更（Webhook・閾値）は再読込不要。`.env` を保存すれば次回実行から反映される。

---

## 停止・アンインストール

```sh
launchctl unload ~/Library/LaunchAgents/local.claude-usage-alert.plist
rm ~/Library/LaunchAgents/local.claude-usage-alert.plist
```

Stopフックも外す場合は `~/.claude/settings.json` の `hooks.Stop` から
`usage-alert.sh --source hook` のエントリを削除する（または一時的に止めたいだけ
なら `.env` で `TRIGGER_HOOK="false"`）。

フルディスクアクセスに `bin/usage-alert-runner` を追加していた場合は、
システム設定 → プライバシーとセキュリティ → フルディスクアクセス から削除する。

---

## 既知の制約

- 使用率・リセット時刻は `claude -p "/usage"` 由来＝**Claude Code 本体と同じサーバー側の値**
  なので、`/usage` の表示と一致する（旧方式のような校正ズレはない）。
- **`claude` CLI のログインが必要**。未ログイン/認証切れだと `/usage` を取得できず、
  その場合は誤通知を避けて黙って何もしない。
- `/usage` の出力テキスト書式に依存してパースしている。Claude Code の更新で書式が
  変わると拾えなくなる可能性がある（その場合も誤通知はせず無言終了）。
- 通知が出るタイミングは launchd の実行間隔（既定5分）に依存するため、閾値到達から
  最大で数分の遅れが出る。即時性を上げたい場合は Stop フック（`TRIGGER_HOOK`）を併用する。
- `launchd-runner.c` を変更して再ビルドすると署名（cdhash）が変わり、TCC 上は別バイナリ
  扱いになるため**フルディスクアクセスの付与し直しが必要**（`install.sh` はソース変更時
  のみ再ビルドし、無駄に署名を変えない）。スクリプト側の変更だけなら再ビルド不要。
