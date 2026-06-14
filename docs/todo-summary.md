# TODO サマリー（管理用インデックス）

このリポジトリの未対応タスク一覧。各項目の詳細は「詳細doc」のパスを参照。
完了したら `[ ]` を `[x]` にし、必要なら該当docも更新する。

> 作業ブランチ: `feature/trigger-switch`

## 一覧

| 状態 | タスク | 概要 | 詳細doc |
|---|---|---|---|
| [x] | トリガー方式の切替 | launchd(5分) と Stopフック(応答直後) を `.env` フラグ（`TRIGGER_LAUNCHD`/`TRIGGER_HOOK`）でON/OFF。`usage-alert.sh` に `--source` 引数を追加（実装完了・E2E通知テストとPRは残） | [docs/todo-trigger-switch.md](todo-trigger-switch.md) |
| [ ] | 通知メッセージ変更 | トークン数と「(閾値X%)」を削除し、「5hリセットまであと◯時間」を追加（`endTime`から計算） | [docs/todo-notification-message.md](todo-notification-message.md) |
| [ ] | メンション機能 | `DISCORD_MENTION` でユーザー/ロール/everyoneをメンション（`.env`で切替、`allowed_mentions`対応） | [docs/todo-notification-message.md](todo-notification-message.md) |
| [ ] | 通知閾値の整備 | `THRESHOLDS` は既にスペース区切りで設定可。カンマ許容・検証・ソート/重複除去・明文化を整備 | [docs/todo-notification-message.md](todo-notification-message.md) |

## 保留中（本筋とは別）

| 状態 | タスク | 概要 |
|---|---|---|
| [ ] | 実通知テスト | `.env` 設定済みの状態で `sh usage-alert.sh` を1回実行し、Discordへ実際に届くか確認 |
| [ ] | Webhook再作成（任意） | 設定中にWebhook URLがチャットに表示されたため、気になればDiscordで再作成→`.env`更新 |

## 凡例
- `[ ]` 未対応 / `[x]` 完了
- 詳細docには各タスクの設計案・実装ステップ・チェックリストあり
