# 引き継ぎ: statusline に 5h(セッション)使用率を公式値で表示する

- ステータス: 未着手（別セッションへ引き継ぎ）
- 作成日: 2026-06-21
- 関連: `usage-alert.sh`, `~/.claude/statusline-command.sh`, `~/.claude/settings.json`,
  `install.sh`, `docs/decisions/0001-use-claude-usage-as-data-source.md`

## ゴール

Claude Code の statusline（チャット下部UI）に **5h セッション使用率の正確な%** を表示する。
現状は `Model | Ctx XX%`。ここに `5h NN%` を足して `Model | Ctx XX% | 5h NN%` にする。

## なぜこの方式か（経緯）

- 以前は statusline で「トークン量から%を推測」していたが、**セッションを複数立てると
  破綻し精度も出ない**ため、ユーザーが表示を削除済み。
- 正確な値は `claude -p "/usage" --output-format json` から得られる。これは Claude Code 本体と
  同じ**サーバー側の正規値**（セッション5h%・実リセット時刻・週間%）を返し、
  `model:"<synthetic>"` のローカル処理で**課金トークンを消費しない**（実測 ~0.8s）。
  → 詳細は ADR `docs/decisions/0001-use-claude-usage-as-data-source.md`。
- ただし statusline コマンドは**再描画ごとに実行**される。そこで `claude -p` を直叩きすると
  毎回 ~0.8s のラグ＋プロセス起動で重い。**キャッシュ方式**にする:
  定期的に `/usage` を取得して値をファイルへ書き、statusline はそのファイルを読むだけにする。
- 本リポジトリの `usage-alert.sh` は **既に `/usage` を取得・パース済み**
  （`usage-alert.sh` L85-101 で session%/week%/reset を抽出）。これを launchd が
  5分おきに実行している。**この既存fetchに相乗りしてキャッシュを書く**のがDRYで、
  `/usage` 呼び出しを二重化せずに済む。

## 設計（推奨）

### 1. キャッシュ書き出し（`usage-alert.sh` を拡張）

`usage-alert.sh` が `/usage` を正常にパースできた直後に、キャッシュファイルへ書く。
**通知が発火するか否かに関係なく、パース成功時は毎回書く**こと（statusline は常に最新を見たい）。

- 出力先（案）: `~/.claude/usage-cache.json`
- 形式（案・jqで読みやすいJSON）:
  ```json
  {"session":89,"week":14,"reset":"Jun 21 at 7:29pm","ts":1750000000}
  ```
  `ts` は `date +%s`（鮮度判定用のepoch秒）。
- 書き込みは**アトミック**に（temp に書いて `mv`）。statusline が読みかけを掴まないように。

#### 注意（ゲートの位置）

`usage-alert.sh` は複数の早期 return がある:
- `TRIGGER_LAUNCHD`/`TRIGGER_HOOK` が false → fetch 前に無言終了
- claude 未ログイン/認証切れ・パース失敗 → 無言終了
- 閾値未満 → 通知せず終了（ここは**fetch成功後**なのでキャッシュは書ける）

キャッシュ書き込みは「**パース成功直後・閾値判定の前**」に置く。
ただし `TRIGGER_LAUNCHD=false` で運用している場合は fetch 自体が走らないため、その場合は
別途キャッシュ用の経路が必要（下の代替案を参照）。現状の launchd 既定は ON 前提で進めてよい。

### 2. statusline スクリプト（`~/.claude/statusline-command.sh` を編集）

末尾の `printf "%s | %s" "$model" "$ctx_str"` を拡張し、キャッシュから 5h% を読んで付ける。

- キャッシュが**無い/壊れている** → `5h --`
- キャッシュが**古い**（`now - ts` が閾値超、例: 15分=launchdが5分間隔なので余裕を見て）
  → 古い印を付ける（例 `5h 89%?` や薄色）。launchd 停止に気づける。
- jq で `~/.claude/usage-cache.json` を読む。ファイルが無い時にエラーを出さないこと。

最終形（例）:
```
claude-opus-4-8 | Ctx 42% | 5h 89%
```

### 3. 配布（`install.sh`）

- statusline スクリプトはユーザーの `~/.claude/statusline-command.sh`（リポジトリ外）。
  本リポジトリで管理するか、install.sh で配置するかを決める。
  → 既存の install.sh が settings.json をどう触っているか確認し、方針を合わせる。
- 既に `~/.claude/settings.json` の `statusLine.command` は
  `sh /Users/nakamuraakira/.claude/statusline-command.sh` を指している。**設定変更は不要**、
  スクリプト本体を編集すればよい。

## 代替案（TRIGGER_LAUNCHD を OFF で使う場合など）

- statusline 側に **TTLガード付きの自前fetch**を持たせる: キャッシュが古い時だけ
  `claude -p "/usage"` をバックグラウンドで叩いて更新（描画はブロックしない）。
  ただし実装が増える。まずは「launchd相乗り＋キャッシュ読むだけ」で十分。

## 受け入れ基準

- [ ] launchd 実行後、`~/.claude/usage-cache.json` に session/week/reset/ts が書かれる
- [ ] statusline に `5h NN%` が出る。NN は `claude -p "/usage"` の Current session と一致
- [ ] キャッシュ欠落時に statusline がエラーを吐かず `5h --` を出す
- [ ] キャッシュが古い時に「古い」と分かる表示になる
- [ ] 再描画のたびに `claude -p` が走らない（プロセスは launchd 側のみ）
- [ ] README / docs/article.md に statusline 表示の項を追記

## 検証コマンド

```sh
# 公式の現在値（答え合わせ用）
claude -p "/usage" --output-format json \
  | jq -r '.[]|select(.type=="result").result' | grep -i 'current session'

# キャッシュ内容
cat ~/.claude/usage-cache.json

# statusline の出力を手元で確認（stdinに最小JSONを渡す）
echo '{"model":{"display_name":"opus"},"transcript_path":""}' \
  | sh ~/.claude/statusline-command.sh
```
