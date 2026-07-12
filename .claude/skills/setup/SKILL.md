---
name: setup
description: このリポジトリ(claude-usage-discord-alert)の初期セットアップを対話形式で行う。使い方をヒアリングして .env を生成し、install.sh を実行し、ユーザー側で必要な手作業(Discord Webhook作成・フルディスクアクセス付与)を案内する。「セットアップ」「初期設定」「導入」「インストール」と言われたら使う。
---

# 対話セットアップ

このツール(Claude Code の5h使用量を Discord に通知する仕組み)を、ユーザーの使い方に
合わせて初期設定する。**ヒアリング → .env 生成 → install.sh 実行 → 実通知テスト →
手作業の案内** の順で進める。

## 進め方の原則

- 質問は AskUserQuestion を使い、選択肢に推奨を明示する。一度に全部聞かず、
  ステップごとに進める。
- **Webhook URL は秘匿情報**。`.env` に書き込んだ後、会話や出力にフルURLを
  エコーバックしない(確認は末尾数文字か「設定済み」表現で)。
- ユーザーにしかできない作業(Discord での Webhook 作成、システム設定での
  フルディスクアクセス付与)は、手順を具体的に示して完了を待ってから次へ進む。

## Step 1: 前提チェック

以下を確認し、足りないものがあれば導入方法を伝えて待つ:

```sh
sw_vers -productVersion            # macOS であること(launchd 前提)
command -v claude && claude -p "/usage" --output-format json | jq -r '.[]|select(.type=="result").result' | head -3
                                   # claude CLI ログイン済みで使用率が取れること
command -v jq                      # 無ければ: brew install jq
command -v cc                      # 無ければ: xcode-select --install
```

- `claude -p "/usage"` が空を返す場合はログイン(`claude` を起動して認証)を案内。
- 既に `.env` が存在する場合は「再設定(上書き)か中止か」を必ず確認する。

## Step 2: ヒアリング

AskUserQuestion で以下を聞く(1回にまとめてよい):

1. **通知の閾値** — 何%到達で通知するか
   - `50 80`(既定・2段階) / `50 80 95`(3段階・上限直前も) / カスタム入力
   - 各5hウィンドウで各閾値1回ずつ通知される、と説明を添える
2. **メンション** — 通知時に誰を ping するか
   - なし(既定) / 自分宛て `<@ユーザーID>`(推奨・macのバナー通知が確実) /
     `@everyone`(受信側で抑制されやすくバナーが出ないことがある) / ロール `<@&ロールID>`
   - ID の取得方法: Discord の設定→詳細設定→開発者モードON → ユーザー/ロールを
     右クリック→「IDをコピー」
3. **トリガー** — いつ判定を走らせるか
   - 両方ON(推奨・取りこぼし最小) / launchd のみ(5分おき) / Stopフックのみ(応答直後)
   - 長いターンでは Stop フック単体だと閾値を飛び越えることがある、と説明を添える

## Step 3: Discord Webhook URL の用意(ユーザー作業)

URL を既に持っているか聞き、無ければ以下を案内して作成を待つ:

> Discord の通知先チャンネルがあるサーバーで
> **サーバー設定 → 連携サービス → ウェブフック → 新しいウェブフック** を作成し、
> 投稿先チャンネルを選んで「ウェブフックURLをコピー」。

受け取った URL は `https://discord.com/api/webhooks/` で始まることを確認する。

## Step 4: .env 生成

`cp .env.example .env` してから、ヒアリング結果を Edit で反映する:

- `DISCORD_WEBHOOK_URL="<受け取ったURL>"`
- `THRESHOLDS="<選択値>"`(スペース区切り)
- `DISCORD_MENTION="<選択値>"`(なしなら空のまま)
- `TRIGGER_LAUNCHD` / `TRIGGER_HOOK` を選択に合わせて `"true"`/`"false"`

`.env` は .gitignore 済みでコミットされないことを一言添える。

## Step 5: install.sh 実行

```sh
sh install.sh
```

やってくれること(ユーザーに要約して伝える): 実行権限付与 / launchd用ラッパー
`bin/usage-alert-runner` のビルド+ad-hoc署名 / plist 生成と launchd 登録(5分おき) /
`~/.claude/settings.json` への Stop フック冪等登録(有効化は TRIGGER_HOOK フラグ)。

確認: `launchctl list | grep claude-usage-alert` に出れば登録成功。

## Step 6: フルディスクアクセスの付与(macOS 26+ / ユーザー作業)

macOS 26 (Tahoe) 以降では launchd 経由の `claude -p` 実行時に
「ほかのアプリからのデータへのアクセス」ダイアログが出ることがある。以下を案内する:

> **システム設定 → プライバシーとセキュリティ → フルディスクアクセス** で「＋」→
> `Cmd+Shift+G` でこのリポジトリの `bin/usage-alert-runner` を指定して追加・ON。
> 許可はこの安定ラッパーに紐づくので1回で恒久化される(claude 本体の自動更新の
> 影響を受けない)。

- 付与しない選択でもよい(初回ダイアログを一度「許可」すれば以後出ない)。
- macOS 25 以前ならこのステップはスキップしてよい。
- 注意: `launchd-runner.c` を変更して再ビルドすると署名が変わり付与し直しになる。

## Step 7: 実通知テスト

低い閾値で強制発火させ、Discord に届いたかユーザーに確認する:

```sh
THRESHOLDS="1" sh usage-alert.sh
```

- 通知文の例: `⚠️ Claude 5h使用量が NN% に到達` + リセット時刻 + 週間%。
  メンション設定があれば先頭に付く。
- 届かない場合の切り分け: `.env` の URL 再確認 → `claude -p "/usage"` が値を
  返すか → `tail ~/.claude/.usage-alert.log`。
- テストで状態ファイル(`~/.claude/.usage-alert-state`)に閾値 `1` が記録されるが、
  通常運用の閾値判定には影響しない(ウィンドウが変われば自動リセット)。

## Step 8: 完了の案内

最後に以下を伝える:

- 以後は自動で動く。設定変更は `.env` を編集するだけで次回実行から反映
  (launchd の再登録は不要)。
- 状態: `~/.claude/.usage-alert-state`、ログ: `~/.claude/.usage-alert.log`
- 停止・アンインストールは README の該当セクション参照。
