/*
 * launchd 用ラッパーバイナリ。usage-alert.sh を --source launchd で起動するだけ。
 *
 * なぜ必要か:
 *   macOS 26 の「アプリのデータ保護」(TCC) は、launchd ジョブでは
 *   「最初の非Apple製バイナリ」に許可を紐づける。/bin/sh 直起動だと
 *   帰属が claude 本体（~/.local/share/claude/versions/<ver> という
 *   バージョンごとに別ファイルの実行体）まで素通しされ、自動更新の
 *   たびに許可ダイアログが再出現する。この安定したラッパーを起点に
 *   すれば、許可は本バイナリに1回だけ紐づき恒久化される
 *   （システム設定でフルディスクアクセスを事前付与すればダイアログ自体出ない）。
 *
 * ビルド（install.sh が行う。手動なら）:
 *   cc -O2 -DSCRIPT_PATH='"/abs/path/to/usage-alert.sh"' \
 *      -o bin/usage-alert-runner launchd-runner.c
 *   codesign -s - bin/usage-alert-runner
 *
 * 注意: 再ビルドすると署名(cdhash)が変わり TCC 上は別バイナリ扱いに
 * なるため、許可の取り直しが必要。スクリプト側の変更では再ビルド不要。
 */
#include <stdio.h>
#include <unistd.h>

#ifndef SCRIPT_PATH
#error "compile with -DSCRIPT_PATH='\"/abs/path/to/usage-alert.sh\"'"
#endif

int main(void) {
    execl("/bin/sh", "sh", SCRIPT_PATH, "--source", "launchd", (char *)0);
    perror("execl");
    return 127;
}
