# TODO: トリガー方式を `.env` で切り替えられるようにする

> このファイルは作業ハンドオフ用。次セッションはこれを読めば文脈なしで再開できる。
> 作業ブランチ: `feature/trigger-switch`

## 背景（なぜやるか）

監視処理（`usage-alert.sh`）は **トークン消費ゼロ・ローカル完結・約0.05秒** になった。
そのため「5分ごとの定期実行(launchd)」だけでなく「AIの応答が返り次第(Stopフック)」で
動かす選択肢が現実的になった。両者には次の特性差がある:

| 方式 | 即時性 | 長いターンの途中で閾値通過を捕捉 | コスト |
|---|---|---|---|
| Stop hook のみ | ◎（応答直後） | ✕（ターン終了後にしか見ない＝飛び越え得る） | ~0 |
| launchd 5分 のみ（現状） | △（最大5分） | ◎ | ~0 |
| 両方 | ◎ | ◎ | ~0 |

- 使用量が増えるのは「Claudeがリクエストした時」だけ。Stopフックはまさにその直後に発火する。
- ただしサブエージェント多用の長いターンでは、
  1ターンで 40%→95% など一気に進み、Stopフックだと飛び越える。launchdは途中で拾える。
- 結論：**両方使えるようにしつつ、`.env`でON/OFFを切り替えられる**のが理想。

## ゴール

`.env` のフラグだけで、launchd / Stopフック の有効・無効を切り替えられる。
（launchdのload/unloadやsettings.jsonの編集を毎回しなくて済むようにする）

## 設計案

### 1. `.env` にフラグを追加
```sh
# どのトリガーで通知判定を走らせるか（true/false）
TRIGGER_LAUNCHD="true"   # 5分ごとの定期実行
TRIGGER_HOOK="false"     # Claude Code の Stop フック（応答が返り次第）
```
`.env.example` にも追記する。

### 2. `usage-alert.sh` に呼び出し元判定を追加
- 引数 `--source <launchd|hook|manual>` を受け取る（既定 `manual`）。
- スクリプト冒頭で `.env` を読んだ後、source に応じて早期 exit:
  - `--source launchd` かつ `TRIGGER_LAUNCHD != true` → 何もせず exit 0
  - `--source hook` かつ `TRIGGER_HOOK != true` → 何もせず exit 0
  - `manual`（手動/テスト）は常に実行
- これにより「両方が常にスクリプトを呼ぶが、.envのフラグで実際に動くかが決まる」形にできる。
- 既存の重複排除（状態ファイル＋mkdirロック）はそのままで、両方ONでも通知は各閾値1回。

### 3. 呼び出し側を source 付きにする
- launchd plist（テンプレート）: `usage-alert.sh --source launchd`
- Stopフック（`~/.claude/settings.json`）: `usage-alert.sh --source hook`
  ```json
  {
    "hooks": {
      "Stop": [
        { "hooks": [ { "type": "command",
          "command": "sh /Users/<user>/program/cli/claude-usage-discord-alert/usage-alert.sh --source hook" } ] }
      ]
    }
  }
  ```
  ※ ユーザー名を含むのでリポジトリには直接置かず、install.sh で生成 or 手順をREADMEに。

### 4. install.sh / README 更新
- install.sh: Stopフックの登録（settings.json へのマージ）を任意ステップで追加するか、手順を案内。
- README: `.env` のフラグ説明、両方/片方の使い分けを追記。
- `docs/article.md` にも「.envでトリガー切替」の節を追加（記事用）。

## 実装ステップ（チェックリスト）

- [x] `usage-alert.sh` に `--source` 引数と早期exitロジックを追加（stdin読み捨ても）
- [x] `.env` / `.env.example` に `TRIGGER_LAUNCHD` / `TRIGGER_HOOK` を追加
- [x] launchd テンプレートの ProgramArguments を `--source launchd` 付きに
- [x] `~/.claude/settings.json` に Stopフック追加（`--source hook`）。install.sh で冪等マージ実装
- [x] 動作確認: ゲート分岐を全パターンでテスト（launchd/hook/manual × フラグON/OFF）。
      settings.json マージの冪等性・既存設定保持もサンドボックスで確認。
      ※「実トリガーからのE2E通知（実際にDiscordへ飛ぶ）」は未実施＝下記の保留タスク。
- [x] README / docs/article.md 更新
- [ ] main へマージ（PR） … push/マージはユーザー判断

## 注意点 / 既知の論点

- Stopフックはセッション実行中のみ発火。複数セッションでも状態ファイル＋ロックで重複排除済み。
- launchd はシェルの環境変数を引き継がない → 設定は引き続き `.env`（スクリプト同階層）で読む。
- 完全ゼロ設定案（`ccusage --token-limit max`）は別途検討。今は `calibrate.sh` による較正方式。

## 保留中の未完タスク（本筋とは別）

- [ ] **実通知テスト未実施**: `.env` を設定した状態で
      `sh usage-alert.sh` を1回走らせると通知が実際にDiscordへ飛ぶはず。要確認。
- [ ] （セキュリティ）設定中に実Webhook URLがチャットに表示された。気になるなら
      Discord側でWebhook再作成→`.env`更新。

## 現在の状態（更新 2026-06-14）

- `feature/trigger-switch` でトリガー切替の実装が完了（コミット6本）。残るは
  実トリガーからのE2E通知テストと、main への PR/マージ（ユーザー判断）。
- main は通知ツール一式が完成・push済み（launchd 5分監視で稼働中）。
- `.env`（git管理外）に実Webhookと較正済みTOKEN_BUDGETを設定する。
- リモートURLは公開時のリポジトリ名に合わせる。
