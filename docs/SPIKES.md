# M0 技術検証の結果

計画は [M0-PLAN.md](M0-PLAN.md)。確かめたのは macOS 27.2.1 だけである。

| ID | SPEC の節 | 判定 | 採った案 |
|---|---|---|---|
| S1 | 3.7 | 通過(2 台目のディスプレイを除く) | レベルは `.popUpMenu` |
| S2 | 3.5、4.1 | 目視は通過(数値の合成の確認は立ち会い B) | 縞は見えず、EDR で白より明るく出せた |
| S3 | 2.2、3.8 | 一部(動画と会議は立ち会い B) | 下記 |
| S4 | 3.9、5 | 未実施 | |
| S5 | 3.10 | 合格 | 許可なしで `CGWindowListCopyWindowInfo` から ID、矩形、前後の順序を取る |
| S6 | 2.5、3.7 | 未実施 | |
| S7 | 6.1 | 一部(S3 と S5 は Sandbox の下でも動いた) | S4 と S10 が残る |
| S8 | 4.2 | 不採用 | 濃いすりガラスで、屈折にならない |
| S9 | 3.2、3.12 | 合格 | SwiftPM の `.process` で metallib を作り、`Bundle.module` から読む |
| S10 | 6.1 | 未実施 | |

共通の環境: Mac mini(Mac16,11、M4 Pro)、macOS 27.2.1、Xcode 27.2(27B52)、Swift 6.4.2、Studio Display 1 台(5K、60 Hz)。

---

### S9 パッケージ内の Metal シェーダー

- 判定: 合格
- 手順: `Spikes/PackageProbe`。`ProbeShaders` ターゲットに `Shaders.metal` を `.process` で置き、`probe` が `device.makeDefaultLibrary(bundle: Bundle.module)` で読んで 2×2 の rgba16Float に書き、4 ピクセルの値を確かめる
- 結果:
  - `swift build`(Debug)と `swift build -c release`: どちらも PASS。リソースのバンドルの中に `default.metallib` ができた。Swift 6.4 の SwiftPM は成果物を `.build/out/Products/<構成>/` に置く
  - `xcodebuild -scheme probe -configuration Release`: PASS
  - 実行ファイルとリソースのバンドルを別のフォルダへ移し、元のバンドルを隠した場合: PASS(移した先のバンドルから読んだ)
  - デプロイメントターゲットは `.macOS(.v26)` でビルドが通った
  - Mac を再起動したあとの Metal ツールチェーンのマウント先の問題は、今回は起きなかった
  - .app の中: `Spikes/scripts/build-spikes.sh` が `swift build -c release` の成果物から .app を組み立て、リソースのバンドルを `Contents/Resources` に置いて Developer ID で署名した(`--deep` は使わず、バンドル、アプリの順)。Harness を `--run s9` で起動すると、Sandbox なしの版、ありの版のどちらも PASS した。metallib は .app の `Contents/Resources` の中から読まれ、ビルドしたフォルダの metallib には頼っていない(ログで確かめた)
- 仕様への反映: SPEC 3.2 の構成のまま、シェーダーは各パッケージに `.process` で置ける。ビルドは `swift build` でよく、`xcodebuild` も使える。`nagi-render` は `swift build` で作れる。アプリの .app は、HanaLima と同じく `swift build` の成果物をスクリプトで組み立てる。リソースのバンドルは `Contents/Resources` に置けば読める
- M1 への持ち込み: シェーダーをリソースとして置くパッケージの書き方と、.app を組み立てて署名するスクリプト

### S1 オーバーレイ

- 判定: 通過。ウインドウレベルは `.statusBar` では足りず、`.popUpMenu`(101)にする。2 台目のディスプレイの抜き差しと配置の変更、外したときの描画の負荷は確かめていない
- 前提: Dock は画面の下にある(この Mac の既定)。目印の 1 つは下端の中央に置いている
- 手順: `NagiSpike-plain.app --run overlay`。ウインドウレベルは `.statusBar`(25)、`collectionBehavior` は `canJoinAllSpaces`・`fullScreenAuxiliary`・`stationary`・`ignoresCycle`。`CAMetalLayer` は rgba16Float、拡張リニアの Display P3、`wantsExtendedDynamicRangeContent = true`、不透明でない。起動の 1〜3 秒後に `orderFrontRegardless()` で出す
- 結果:
  - フォーカス: 7 回とも、出す前と 1 秒後で手前のアプリが変わらず、Harness はアクティブにならず、キーウインドウも持たなかった。最後の 1 回はアプリのアクティブ化の通知も記録し、実行中に 1 件も届かなかった
  - 無入力の秒数: 出した 1 秒後の値が、入力がなかった場合の予想値と一致した(直前に作者の入力があった 1 回を除く 5 回)。オーバーレイを出しても、無入力の秒数は 0 に戻らない
  - 最初のフレーム: `orderFrontRegardless()` の直前から `presentedTime` まで 65〜77 ms(5 回中 4 回)。残る 1 回は `presentedTime` が 0 で、最初のフレームは表示されなかった。その後、落ちたら描き直すようにした版では、1 枚目が落ち、2 枚目が 83 ms で表示された。ウインドウを出した直後の 1 枚目は落ちることがある
  - **画面の設定の変更の通知は、EDR の余裕が変わるたびにも届く。** EDR の描画を求めるレイヤーを出すと、Studio Display の余裕(`maximumExtendedDynamicRangeColorComponentValue`)が約 2 秒かけて 1.0 から 2.0 へ上がり、その間 `didChangeScreenParametersNotification` が 1 フレームに 1 回(2 秒で約 120 回)届いた。最初の版の Harness は通知のたびにウインドウを作り直していて、フレームが表示されなかった。画面の位置・大きさ・倍率が変わったときだけ作り直すように直した
  - 立ち会い A(2026-11-18、作者の目視):
    - `.statusBar`(25)では、目印はメニューバーの上に出たが、Dock の下に回った。Dock のウインドウのレベルは 20 と返るので、数字の上では上に出るはずだが、Dock の帯は手前に描かれた。理由は確かめていない
    - `.popUpMenu`(101)では、Dock の上にも出た。このレベルでも、Dock とメニューバーの上でのクリックは下へ届いた
    - `.popUpMenu` でも、別の Space、他アプリのフルスクリーン、Mission Control、Stage Manager で目印は出て、Cmd-Tab と Cmd-` の候補に Harness は出なかった
    - `.popUpMenu` では、開いたメニュー(Chrome のタブの右クリックのメニュー)の上にも目印が重なった。凪が出るのは無入力のときだけだが、メニューを開いたまま手を離すと、メニューの上に効果が重なる
    - `.statusBar` の回で確かめたこと: 目印の上のクリック、スクロール、ドラッグは下のアプリへ届き、ホバーとカーソルの形は乱れなかった。別の Space、他アプリのフルスクリーン、Mission Control、Stage Manager でも目印は出た。Cmd-Tab と Cmd-` の候補に Harness は出なかった(Fixture は普通のアプリなので出る)。目印を出したあと、画面全体の明るさの変化は見えなかった
    - 無入力の秒数: 作者が手を離した状態でもう一度確かめ、出す直前 51.7 秒、1 秒後 52.7 秒で、予想値と 1 ms 以内で一致した
    - 標準のスクリーンショットには目印が写った(`sharingType` は既定のまま。S6 で扱う)
- 仕様への反映: SPEC 3.7 のウインドウレベルを `.popUpMenu` にする。SPEC 3.7 の「ディスプレイ構成の変化に追従する」に、画面の位置・大きさ・倍率が変わったときだけ作り直すことを書く。入場の最初のフレームは落ちることがあるので、入場は 1 フレーム目に頼らない
- M1 への持ち込み: ウインドウの設定、通知の絞り込み

### S2 合成、階調、EDR

- 判定: 目視の範囲は通過。合成の式の数値の確認(画面を撮って背景との差を求める)は、画面収録の許可が要るので立ち会い B で行う
- 手順: `NagiFixture --scene panels` の灰色のパネル 3 枚(sRGB の 0.1・0.5・1.0)の上に、Harness(`.popUpMenu`)を重ねた
  - `--run ramp`: 横長の帯 4 本。上から 8 ビット(`bgra8Unorm`、sRGB)、8 ビット＋ディザ、16 ビット浮動小数(`rgba16Float`、拡張リニアの Display P3)、16 ビット浮動小数＋ディザ。どれも乗算済みの黒で、アルファを左端の 0 から右端の `--max-alpha`(既定 0.08)まで上げる。ディザは 8 ビットの 1 段の ±0.5 のインターリーブド・グラディエント・ノイズをアルファに足す(本物のブルーノイズのテクスチャは試していない)。`--edr` で 16 ビットの帯が EDR を求めるかを切り替える。帯のあいだには、見分けるための 8 pt の隙間を置いた
  - `--run edr`: 白いパネルの上に、アルファ 0.3・色 0.6(白の 2 倍の色に 0.3 を掛けた乗算済みの値)のパッチ。白の上では、計算上 1.3 になる
- 結果(2026-11-18、作者の目視、Studio Display):
  - Studio Display の `maximumPotentialExtendedDynamicRangeColorComponentValue` は 2 だった。EDR の描画を求めるまでは余裕が 1 で、求めると約 2 秒かけて 2 まで上がった
  - 8 % までの減光のランプでは、EDR なしでもありでも、4 本とも段は見えなかった。8 ビットでディザなしの帯も含む。ディザのざらつきも気にならなかった
  - EDR を求めて余裕が 1 から 2 へ上がるとき、画面全体やパネルの明るさの変化は見えなかった(S1 の目印、S2 の帯の両方)
  - EDR のパッチは、隣の白より明るく見えた。半透明のまま、他アプリの白の上で紙の白より明るく出せる
  - 帯もパッチも、出した直後の 1 枚目は表示されず(`presentedTime` が 0)、0.5 秒後に描き直した 2 枚目で表示された。S1 と同じく、出した直後の 1 枚目は落ちることがある
- 仕様への反映: SPEC 3.5 の出力は 16 ビット浮動小数・拡張リニアの Display P3 で、日なたを白より明るくするために EDR を求めてよい(余裕の変化で画面の明るさが揺れて見えることはなかった)。この画面と 8 % までの減光では 8 ビットでも縞は見えなかったので、ディザは必須とせず、もっと淡い影や暗い背景で縞が見えたら足す。アルファ 0.3 のパッチで下の白より明るくなったので、色の成分は他アプリの上へ足されている。α ≈ 0 の純粋な加算は、立ち会い B の数値の確認で確かめる
- 確かめていないこと: 本物のブルーノイズ、8 % より強い減光、Studio Display 以外のディスプレイ

### S5 権限なしのウインドウ情報

- 判定: 合格
- 手順: Fixture(`--scene s5`)が重なった 2 枚のウインドウを 2 秒ごとに動かし(移動、リサイズ、前後の入れ替え、戻す)、操作の後のウインドウ番号と矩形(左上が原点の CG 座標)と順序を記録する。同時に `NagiSpike-plain.app --run s5` が 15 Hz で `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements])` を読み、Fixture のウインドウが変わったときに記録する。2 つのログを時刻で突き合わせた。`CGPreflightScreenCaptureAccess()` は false
- 結果:
  - Sandbox なし: 13 回の操作すべてで、ウインドウ番号、矩形(1 pt 以内)、前後の順序が一致した。操作から取得までの遅れは 53〜70 ms(取得の間隔 67 ms に収まる)
  - Sandbox あり(`NagiSpike-plain-sandboxed`): 7 回の操作すべてで一致した
  - 返ったキー: `kCGWindowAlpha`、`kCGWindowBounds`、`kCGWindowIsOnscreen`、`kCGWindowLayer`、`kCGWindowMemoryUsage`、`kCGWindowName`、`kCGWindowNumber`、`kCGWindowOwnerName`、`kCGWindowOwnerPID`、`kCGWindowSharingState`、`kCGWindowStoreType`。名前のキーも返ったが、値は読んでいない(SPEC 5 章)
  - 30 Hz(Sandbox なし): 7 回の操作すべてで一致した。操作から取得までの遅れは 28〜60 ms
  - 1 回の取得の時間(ログは `build/spikes/logs/` の `s5-harness.jsonl`、`s5sb-harness.jsonl`、`s5hz30-harness.jsonl`): Sandbox なし・15 Hz は中央値 3.1 ms、95 % 点 4.9 ms、最大 8.7 ms(374 回)。Sandbox なし・30 Hz は中央値 1.9 ms、95 % 点 2.2 ms、最大 3.4 ms(389 回)。Sandbox あり・15 Hz は中央値 9.4 ms、95 % 点 12.0 ms、最大 15.5 ms(194 回)。どれも 1 回ずつの測定で、Sandbox による差かどうかは S7 で繰り返して確かめる
  - 試験の道具の注意: 非アクティブなアプリの `orderFront(nil)` は、そのアプリの中のウインドウの並び(`NSApp.orderedWindows`)を変えるだけで、画面の上の順序を変えなかった。Fixture は `orderFrontRegardless()` で前に出す
- 仕様への反映: SPEC 3.10 の【要検証】を外し、「macOS 27.2.1 では許可なしで ID、矩形、前後の順序が取れる。Apple は許可なしで返すキーを文書化しておらず、将来変わりうる」と書く。取得は 1 回 2〜12 ms ほどなので、苔がオンのときだけ読む
- M1 への持ち込み: なし(M3 で使う)

### S3 無入力の時間と電源アサーション

- 判定: 一部。入力の種類、画面の状態の通知、Sandbox ありの版は通過。動画の再生と会議のアサーションを立ち会い B で確かめる
- 手順: Harness を `--run s3` で起動する。0.5 秒ごとに `CGEventSource.secondsSinceLastEventType` を `.hidSystemState` と `.combinedSessionState` で、`IOPMCopyAssertionsStatus` と `IOPMCopyAssertionsByProcess` を読む。画面の状態の通知も待ち受ける。権限は何も求めていない
- 結果:
  - 無入力の秒数は、権限なしの CLI で両方の状態 ID から取れた。2 つの値は同じだった
  - `caffeinate -d` を実行している間、そのプロセスの `PreventUserIdleDisplaySleep` が取れた。終了すると消えた
  - `caffeinate -i` は `PreventUserIdleSystemSleep` だけで、画面のスリープ防止としては拾われなかった
  - 注意: 利用者が操作したあと、powerd(システムのプロセス)が `InternalPreventDisplaySleep`(名前は `delayDisplayOff`)を持つ。ほかにも WindowServer がトラックパッドに触れるたびに `UserIsActive` を、Electron 製のアプリが `NoIdleSleepAssertion`(システムのスリープの防止)を持っていた。動画の検出では、他プロセスの画面のスリープの防止だけを数え、`Internal…` で始まる種類とシステムのスリープの防止は数えないことにする
  - 画面のスリープの防止には、`PreventUserIdleDisplaySleep` のほかに古い名前の `NoDisplaySleepAssertion` もある。Zoom がこちらを 26 分間持っていた。このとき作者は Zoom で会議中だった。会議が終わると、Zoom を起動したままでもこのアサーションは消えた。Zoom を起動しているだけでは凪は止まらない
  - 無入力の秒数の振る舞い: 入力のあと、値は 0 からではなく約 0.96 から増え始めた。入力が続いている間は 0.96 前後のまま止まり、入力が止むと 0.5 秒ごとに 0.5 ずつ増えた。値が 1 秒ほどの粒度で更新されている可能性がある。`caffeinate -d` の開始と終了の時刻には、値の変化が起きていない。測っている間は作者が Mac を使っていたので、入力していないときの振る舞いは立ち会い A で確かめる。凪の判定には「値が前回より減った」を入力として使えるので、0.96 の下限は退場の速さには響かない。`T_onset` が 1 秒ほど早まるだけと見込んでいる
  - 立ち会い A(2026-11-18、Sandbox ありの版 `NagiSpike-plain-sandboxed`):
    - 入力の種類: キー、修飾キーだけ、マウスの移動、クリック、ドラッグ、スクロールのどれでも、無入力の秒数が 0.88 秒まで戻った。入力が続く間は 0.88 で止まった(読む時刻の位相で 0.96 と違う値になる)。2 つの状態 ID の値はいつも同じだった
    - Sandbox の下でも、無入力の秒数と `IOPMCopyAssertionsStatus`・`IOPMCopyAssertionsByProcess` を読めた
    - 通知(Sandbox ありの版で全部届いた):
      - 画面のロックと解除: 分散通知の `com.apple.screenIsLocked`・`com.apple.screenIsUnlocked`
      - スクリーンセーバー: `com.apple.screensaver.didstart`・`didstop`。始まると同時に `screenIsLocked` も届き、止めると `screenIsUnlocked` が届いた
      - ディスプレイのスリープ(`pmset displaysleepnow`): `NSWorkspace.screensDidSleepNotification`・`screensDidWakeNotification`。ここでも `screenIsLocked`・`screenIsUnlocked` が続いた
      - `sessionDidResignActive` は届かなかった。これはユーザーの切り替えの通知なので、この試験では起きない
- 仕様への反映: SPEC 2.2 の止める条件は、`screenIsLocked`(スクリーンセーバーとディスプレイのスリープでも届く)と `screensDidSleep` で知る。SPEC 3.8 の検出の条件を「他プロセスの `PreventUserIdleDisplaySleep` または `NoDisplaySleepAssertion`」と書く
- M1 への持ち込み: アサーションの種類の絞り込み

### S8 NSGlassEffectView

- 判定: 不採用。雨粒の屈折の代わりにはならない
- 手順: `NagiSpike-plain --run glass`(`.popUpMenu`、アクティブにならずクリックを通すオーバーレイ)。`NagiFixture --scene panels` の文章の上に、`NSGlassEffectView` の丸(12・24・48・96 pt)とカプセル形を、`.regular` と `.clear` で 1 組ずつ並べた
- 結果(2026-11-18、作者の目視): 下の文字はかすかに透けるが、ごく濃いすりガラスのようで、ほとんど灰色のガラスに見えた。文字が雨粒を通したように歪んで見えることはなかった
- 仕様への反映: SPEC 4.2 の屈折は、画面の取り込み(S4)に頼る。許可がないときの代わりにガラスの部品は使わない

### 検証の道具の確認(Harness と Fixture)

- `open -n -g -W --stdout <ファイル> <app> --args …` で起動すると、アプリの標準出力がそのファイルに書かれる。Sandbox ありの版でも届いた。結果の受け渡しはこの形にする。アプリのコンテナをシェルから直接読む方法は使わない
- `tccutil reset ScreenCapture <バンドル ID>` は sudo なしで通った。ただし、一度も起動していない(LaunchServices に登録されていない)バンドル ID は「そのようなバンドル ID はない」と断られる。許可したあとで未許可に戻るかは立ち会い B で確かめる
- 署名のときにキーチェーンのダイアログは出なかった
