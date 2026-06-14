# TODO: 通知メッセージの変更

> ハンドオフ用。`usage-alert.sh` が Discord に送る通知本文の仕様変更。

## 変更要件

1. **トークン数の記載を削除**（`トークン: X / Y` の行を消す）
2. **「(閾値 50%)」の表記を削除**
3. **「あと何時間で5hリセットがかかるか」を追加**
   - 現状の `残り: あと N% でリセットまで継続`（分かりにくい）を置き換える

## 現状のメッセージ

```
⚠️ Claude 5h使用量が **92%** に到達 (閾値 50%)
トークン: 24432551 / 26557120
残り: あと 8% でリセットまで継続
```

## 変更後の案

```
⚠️ Claude 5h使用量が 92% に到達
5hリセットまで あと約 2.3時間（19:09）
```

## 実装メモ

- リセット時刻は `ccusage blocks --active --json` の `.blocks[0].endTime`（5hブロック終了時刻）から取得できる。
  例: `"endTime": "2026-06-14T10:00:00.000Z"`
- 「あと何時間」= `endTime - 現在時刻`。表示はローカルタイム（Asia/Tokyo）の時刻も併記すると分かりやすい。
- `usage-alert.sh` の `msg=$(printf ...)` 部分を書き換える。`printf` のフォーマット文字列から
  トークン・閾値を外し、リセット残り時間を計算して埋める。
- 残り時間計算はsh+date/awkで。`date -j -f "%Y-%m-%dT%H:%M:%SZ"`（macOS, UTC）でepoch化して差分。

## チェックリスト

- [ ] `usage-alert.sh` のメッセージ生成を変更（トークン/閾値を削除、リセット残り時間を追加）
- [ ] リセット時刻を `endTime` から計算（残り時間＋ローカル時刻表示）
- [ ] 実際にDiscordへ飛ばして表示確認
- [ ] README / docs/article.md のメッセージ例を更新

---

## 追加TODO: メンション機能（`.env`で切替）

通知時に Discord で特定ユーザー/ロールをメンション（@）できるようにする。ON/OFFは `.env` で。

### 要件
- `.env` の設定だけでメンションの有無・対象を切替えられる。
- 未設定（空）ならメンションなし（現状どおり）。

### 設計案
- `.env` に追加:
  ```sh
  # メンション対象。空ならメンションなし。
  #   ユーザー: <@123456789012345678>
  #   ロール:   <@&123456789012345678>
  #   全員:     @everyone
  DISCORD_MENTION=""
  ```
- `usage-alert.sh` の送信時、`DISCORD_MENTION` が非空なら本文先頭に付与:
  `content = "$DISCORD_MENTION ⚠️ Claude 5h使用量が..."`
- **重要**: Webhookでロール/everyoneを実際にpingさせるには payload に `allowed_mentions` が要る。
  ```sh
  jq -nc --arg c "$msg" '{content:$c, allowed_mentions:{parse:["roles","users","everyone"]}}'
  ```
  （未指定だとロール/everyoneがpingされないことがある）
- 対象IDの調べ方: Discordで開発者モードON →ユーザ/ロールを右クリック→「IDをコピー」。

### 検討点（任意）
- 閾値ごとにメンションを変えたい場合（例: 50%は無し、80%だけ@me）は
  `DISCORD_MENTION_80` のように閾値別キーにする案も。まずは単一でよい。

### チェックリスト
- [ ] `.env` / `.env.example` に `DISCORD_MENTION` 追加
- [ ] `usage-alert.sh` で本文への付与＋`allowed_mentions` 対応
- [ ] ロール/ユーザー/everyone それぞれで実ping確認
- [ ] README に設定方法（ID取得手順含む）追記
