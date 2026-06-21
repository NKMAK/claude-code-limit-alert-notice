# Claude Code の5時間使用量が50%/80%に達したらDiscordに通知する仕組みを作る

> **【重要な追記 / 設計変更】**
> 当初は ccusage でトークンを集計し `TOKEN_BUDGET` で校正して%を近似していたが、
> **実上限はトークン数に正比例せず校正がすぐズレる**問題があった。その後
> `claude -p "/usage" --output-format json` で **Claude Code 本体と同じサーバー側の
> 正確な値（セッション使用率・実リセット時刻・週間使用率）**を非対話で取得できると分かり、
> データ源を /usage に全面移行した（この呼び出しは synthetic 処理で課金トークンを消費しない）。
> これにより `TOKEN_BUDGET` 校正・`calibrate.sh`・ccusage 依存は廃止。リセット時刻も正確値で
> 通知に復活した。以下の本文は当初の調査経緯としてそのまま残す。経緯の詳細は
> `docs/decisions/` の意思決定記録を参照。

## やりたかったこと

Claude Code には「5時間のローリング使用制限」がある。これに **50% / 80% で気づきたい**。
検知さえできれば通知手段は何でもよい（今回は Discord Webhook）。

ゴールを2つに分けて検証した。

1. **特定の%を検知できるか？**
2. **検知できたら通知をフックできるか？**

---

## 調査：使用量はどこから取れるのか

### hook には「使用量◯%到達」イベントは無い

Claude Code の hook はライフサイクルイベント（SessionStart / Stop / PreToolUse など）のみで、
「使用量が閾値に達した」というトリガーは存在しない。

### `/usage` の正確な%はローカルに落ちていない

`~/.claude` を調べたが、`/usage` が表示する**サーバー側の正確な5h%をそのまま読めるファイルは無かった**。

- `~/.claude/.claude.json` … `organizationRateLimitTier` や `planLimitsEndDate` などプラン情報はあるが、ライブの消費カウンタは無い
- `~/.claude/usage-data/` … 過去のレポート（HTML）であり、リアルタイム値ではない

### ただしトークン実績は全部ログに残っている

`~/.claude/projects/**/*.jsonl` に、全リクエストの `usage`（input / output / cache 各トークン）が
タイムスタンプ付きで記録されている。**ここから5hウィンドウの消費を集計できる。**

その集計を一発でやってくれるのが **[ccusage](https://github.com/ryoppippi/ccusage)**（第三者製npmツール）。

```sh
npx -y ccusage@latest blocks --active --json
```

出力に `totalTokens`（現在の5hブロックの合計トークン）が含まれる。
ただし `usagePercent` のような%フィールドは無いので、%は自分で計算する。

---

## 検証ポイント：複数セッションを同時に動かしても正確か

**結論：同一マシンの複数セッションはむしろ正しく合算される。**

- 5h制限は**セッション単位ではなくアカウント単位**
- 各セッションは別々の `.jsonl` に書くが、ccusage は `~/.claude/projects/**` を全スキャンして
  時刻で5hブロックに束ねる → 全セッションのトークンが自動で合算される
- サブエージェント（Taskツール）の消費も `isSidechain` 付きでカウントされる

### 本当の死角は別経路の消費

| 消費経路 | ローカルログに残るか |
|---|---|
| 同マシンの別CCセッション | ✅ 残る（合算OK） |
| 別PCのClaude Code | ❌ 残らない |
| claude.ai(Web) / デスクトップ / モバイル | ❌ 残らない |
| API直叩き | ❌ 残らない |

これらは同じ5hアカウント制限を食うのにローカルに痕跡が残らないため、**併用していると過少カウント**になる。
これが「`/usage` と完全一致しない」理由でもある。

---

## %の分母問題とキャリブレーション

`%= totalTokens ÷ 5h上限トークン` で出すが、**分母（プランの実上限）はAnthropic非公開**。
そこで1回だけ実測で割り出す。

1. `/usage` で現在の使用率を見る（例: 30%）
2. `ccusage ... | jq '.blocks[0].totalTokens'` で現在の消費トークンを取る
3. `上限 = totalTokens ÷ (％/100)` を設定値にする

近似だが、50%/80%アラートには十分実用的。

---

## 設計判断：なぜ hook ではなく launchd か

最初は「Stop フック（応答ごとに発火）」を検討したが、launchd の定期実行に切り替えた。

| 観点 | Stopフック | launchd（採用） |
|---|---|---|
| 発火タイミング | 応答を受け取った瞬間のみ | 5分おきに常時 |
| 席を外して放置中 | ❌ 発火しない＝気づかず上限到達 | ✅ 検知できる |
| 応答速度 | hook内でccusage実行＝毎回の返答に遅延 | ✅ 裏で動くので無影響 |
| 複数セッション | 担当・重複通知の調整が要る | ✅ 監視役は1つでシンプル |

決め手は「**上限が近いときこそ席を外す / 長い処理を回しっぱなしにしがち**」という点。
その状況で沈黙する Stop フックはアラートの目的（事前に気づく）と噛み合わない。

> launchd … macOS標準のサービス/スケジューラ管理（Linuxのcron/systemd相当）。
> `~/Library/LaunchAgents/*.plist` に設定を置くと、指定スクリプトを定期実行・常駐させられる。

### 追記：結局「両方」を `.env` で切替できるようにした

当初 Stopフックを見送った最大の理由は「hook内で `npx ccusage` を毎回叩くと
返答が遅くなる」だった。だが後に **ccusage を固定バージョンでローカル導入し、
`--offline` で料金取得もやめた**結果、判定処理は**トークン消費ゼロ・ネット非依存・
約0.05秒**になった。こうなると Stopフックの遅延コストはほぼ無視できる。

そこで「どちらか択一」をやめ、**両方を用意して `.env` のフラグで切替える**形にした。

```sh
TRIGGER_LAUNCHD="true"   # 5分ごとの定期実行
TRIGGER_HOOK="false"     # 応答が返り次第
```

| 方式 | 即時性 | 長いターンの途中で閾値通過を捕捉 |
|---|---|---|
| Stopフックのみ | ◎ | ✕（ターン終了後にしか見ない＝飛び越え得る） |
| launchdのみ | △（最大5分） | ◎ |
| 両方 | ◎ | ◎ |

実装のキモは、launchd と Stopフックの**両方が常に同じスクリプトを叩く**が、
スクリプト側が `--source <launchd|hook|manual>` で呼び出し元を受け取り、
`.env` のフラグで「実際に判定まで進むか」を決める点。無効なトリガーからの起動は
何もせず `exit 0` する。手動実行(`manual`)だけはフラグに関係なく常に動く（テスト用）。
これで launchd の load/unload や settings.json の編集をやり直さずに、`.env` 一箇所で
切替えられる。

> なぜ「両方ON」が最も堅いか：サブエージェント多用の長いターンでは1ターンで
> 40%→95% のように一気に進み、ターン終了時にしか見ない Stopフックでは閾値を
> 飛び越え得る。launchd は途中の5分刻みで拾えるので、併用すると取りこぼしにくい。
> 重複は状態ファイル＋ロックで排除し、通知は各閾値1回に保たれる。

---

## 実装

### 1. 監視スクリプト `usage-alert.sh`（要点）

```sh
json=$(npx -y ccusage@latest blocks --active --json)
block_id=$(echo "$json" | jq -r '.blocks[0].id')
total=$(echo "$json" | jq -r '.blocks[0].totalTokens')
pct=$(awk -v t="$total" -v b="$TOKEN_BUDGET" 'BEGIN{printf "%.0f", t*100/b}')

# 状態ファイルでブロックごとに各閾値1回だけ通知（5hブロックが変わればリセット）
for th in $THRESHOLDS; do
  if [ "$pct" -ge "$th" ] && ! 既に発火済み; then
    curl -H "Content-Type: application/json" \
      -d "$(jq -nc --arg c "$msg" '{content:$c}')" "$DISCORD_WEBHOOK_URL"
  fi
done
```

通知本文はシンプルに、使用率だけを出す（トークン数や内部閾値は出さない）:

```
⚠️ Claude 5h使用量が 92% に到達
```

> 以前は `blocks[0].endTime` から「5hリセットまで あと約N時間」も表示していたが、これは
> ccusage の集計ブロック終端（最初の利用時刻を正時切り下げ + 5h）であって、Claude の
> サーバー側の実リセット時刻（分単位・ログには非保存）とは一致せず誤解を招くため廃止した。
> 実リセット時刻はローカルのどこにも保存されておらず、ログだけからは正確に再現できない。

`.env` の `DISCORD_MENTION`（例 `@everyone` / `<@&ロールID>`）を入れると本文先頭に
メンションが付く。Webhookでロール/@everyoneを実際にpingさせるため、payloadには
`allowed_mentions:{parse:["roles","users","everyone"]}` を併せて送る。

工夫した点:
- **多重通知の抑止**: 状態ファイル `~/.claude/.usage-alert-state` に「ブロックID＋発火済み閾値」を記録。
  5hブロックが切り替わったら自動リセット。
- **多重起動の抑止**: macOSに `flock` が無いので `mkdir`（アトミック）でロック。
- **誤通知防止**: Webhook URL や上限トークンが未設定なら何もせず終了。
- **秘匿情報の分離**: Webhook URL を含む設定は `.env`（`.gitignore` 済み）に置き、リポジトリに含めない。

### 2. launchd 登録 `*.plist`

`StartInterval = 300`（5分）、`RunAtLoad = true` で常駐。

```sh
launchctl load ~/Library/LaunchAgents/local.claude-usage-alert.plist
```

---

## まとめ

- **特定%の検知**：`claude -p "/usage"` でサーバー側の正確な5h使用率を非対話取得（旧: ccusage近似）
- **通知**：launchdで5分おきに監視し、閾値到達でDiscord Webhookへ
- **複数セッション**：サーバー側の値なのでアカウント単位で正確（別PC/Web/API分も含む）
- **限界**：`claude` のログインが必要／`/usage` 出力書式の変更に弱い／通知は監視間隔ぶん遅延

最終的に **公式 `/usage` と一致する正確な値**で事前アラートを出せるようになった。
当初の ccusage 近似からの移行経緯は冒頭の追記と `docs/decisions/` を参照。
