# M0 技術検証の結果

計画は [M0-PLAN.md](M0-PLAN.md)。確かめたのは macOS 27.2.1 だけである。

| ID | SPEC の節 | 判定 | 採った案 |
|---|---|---|---|
| S1 | 3.7 | 一部(Claude の分) | 下記 |
| S2 | 3.5、4.1 | 未実施(EDR の余裕だけ読んだ) | |
| S3 | 2.2、3.8 | 一部(Claude の分) | 下記 |
| S4 | 3.9、5 | 未実施 | |
| S5 | 3.10 | 合格 | 許可なしで `CGWindowListCopyWindowInfo` から ID、矩形、前後の順序を取る |
| S6 | 2.5、3.7 | 未実施 | |
| S7 | 6.1 | 一部(S5 だけ) | |
| S8 | 4.2 | 未実施 | |
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

- 判定: 一部。Claude が 1 人で確かめられる範囲(フォーカス、無入力の秒数、最初のフレーム、画面の設定の変更の通知)だけ。Space、フルスクリーン、メニューバーと Dock の上に見えるか、クリックが通るかは立ち会い A で確かめる
- 前提: Dock は画面の下にある(この Mac の既定)。目印の 1 つは下端の中央に置いている
- 手順: `NagiSpike-plain.app --run overlay`。ウインドウレベルは `.statusBar`(25)、`collectionBehavior` は `canJoinAllSpaces`・`fullScreenAuxiliary`・`stationary`・`ignoresCycle`。`CAMetalLayer` は rgba16Float、拡張リニアの Display P3、`wantsExtendedDynamicRangeContent = true`、不透明でない。起動の 1〜3 秒後に `orderFrontRegardless()` で出す
- 結果:
  - フォーカス: 7 回とも、出す前と 1 秒後で手前のアプリが変わらず、Harness はアクティブにならず、キーウインドウも持たなかった。最後の 1 回はアプリのアクティブ化の通知も記録し、実行中に 1 件も届かなかった
  - 無入力の秒数: 出した 1 秒後の値が、入力がなかった場合の予想値と一致した(直前に作者の入力があった 1 回を除く 5 回)。オーバーレイを出しても、無入力の秒数は 0 に戻らない
  - 最初のフレーム: `orderFrontRegardless()` の直前から `presentedTime` まで 65〜77 ms(5 回中 4 回)。残る 1 回は `presentedTime` が 0 で、最初のフレームは表示されなかった。その後、落ちたら描き直すようにした版では、1 枚目が落ち、2 枚目が 83 ms で表示された。ウインドウを出した直後の 1 枚目は落ちることがある
  - **画面の設定の変更の通知は、EDR の余裕が変わるたびにも届く。** EDR の描画を求めるレイヤーを出すと、Studio Display の余裕(`maximumExtendedDynamicRangeColorComponentValue`)が約 2 秒かけて 1.0 から 2.0 へ上がり、その間 `didChangeScreenParametersNotification` が 1 フレームに 1 回(2 秒で約 120 回)届いた。最初の版の Harness は通知のたびにウインドウを作り直していて、フレームが表示されなかった。画面の位置・大きさ・倍率が変わったときだけ作り直すように直した
- 仕様への反映(立ち会いのあとで確定): SPEC 3.7 の「ディスプレイ構成の変化に追従する」に、画面の位置・大きさ・倍率が変わったときだけ作り直すことを書く。入場の最初のフレームは落ちることがあるので、入場は 1 フレーム目に頼らない
- M1 への持ち込み: ウインドウの設定、通知の絞り込み

### S2 合成、階調、EDR(読んだ値だけ)

- Studio Display の `maximumPotentialExtendedDynamicRangeColorComponentValue` は 2 だった。EDR の描画を求めるまでは余裕が 1 で、求めると約 2 秒かけて 2 まで上がった
- 余裕が上がるとき、画面全体の明るさが変わって見えるか(バックライトを上げ、SDR の内容を相対的に下げる動き)は、作者の目で確かめる。見えて変わるなら、凪に入るたびに画面の明るさが揺れることになるので、EDR は日なたを白より明るくするときだけ求め、それ以外は `wantsExtendedDynamicRangeContent` を付けない

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

- 判定: 一部。Claude が 1 人で確かめられる範囲だけ。入力の種類ごとの確認、動画と Zoom、ロックなどの通知は立ち会い A・B で行う
- 手順: `Spikes/IdleProbe/main.swift`(`swiftc` でビルド)。0.5 秒ごとに `CGEventSource.secondsSinceLastEventType` を `.hidSystemState` と `.combinedSessionState` で、`IOPMCopyAssertionsStatus` と `IOPMCopyAssertionsByProcess` を読む。画面の状態の通知も待ち受ける。権限は何も求めていない
- 結果:
  - 無入力の秒数は、権限なしの CLI で両方の状態 ID から取れた。2 つの値は同じだった
  - `caffeinate -d` を実行している間、そのプロセスの `PreventUserIdleDisplaySleep` が取れた。終了すると消えた
  - `caffeinate -i` は `PreventUserIdleSystemSleep` だけで、画面のスリープ防止としては拾われなかった
  - 注意: 利用者が操作したあと、powerd(システムのプロセス)が `InternalPreventDisplaySleep`(名前は `delayDisplayOff`)を持つ。ほかにも WindowServer がトラックパッドに触れるたびに `UserIsActive` を、Electron 製のアプリが `NoIdleSleepAssertion`(システムのスリープの防止)を持っていた。動画の検出では、他プロセスの画面のスリープの防止だけを数え、`Internal…` で始まる種類とシステムのスリープの防止は数えないことにする
  - 画面のスリープの防止には、`PreventUserIdleDisplaySleep` のほかに古い名前の `NoDisplaySleepAssertion` もある。Zoom がこちらを 26 分間持っていた。このとき作者は Zoom で会議中だった。会議が終わると、Zoom を起動したままでもこのアサーションは消えた。Zoom を起動しているだけでは凪は止まらない
  - 無入力の秒数の振る舞い: 入力のあと、値は 0 からではなく約 0.96 から増え始めた。入力が続いている間は 0.96 前後のまま止まり、入力が止むと 0.5 秒ごとに 0.5 ずつ増えた。値が 1 秒ほどの粒度で更新されている可能性がある。`caffeinate -d` の開始と終了の時刻には、値の変化が起きていない。測っている間は作者が Mac を使っていたので、入力していないときの振る舞いは立ち会い A で確かめる。凪の判定には「値が前回より減った」を入力として使えるので、0.96 の下限は退場の速さには響かない。`T_onset` が 1 秒ほど早まるだけと見込んでいる
- 仕様への反映(立ち会いのあとで確定): SPEC 3.8 の検出の条件を「他プロセスの `PreventUserIdleDisplaySleep` または `NoDisplaySleepAssertion`」と書く
- M1 への持ち込み: アサーションの種類の絞り込み

### 検証の道具の確認(Harness と Fixture)

- `open -n -g -W --stdout <ファイル> <app> --args …` で起動すると、アプリの標準出力がそのファイルに書かれる。Sandbox ありの版でも届いた。結果の受け渡しはこの形にする。アプリのコンテナをシェルから直接読む方法は使わない
- `tccutil reset ScreenCapture <バンドル ID>` は sudo なしで通った。ただし、一度も起動していない(LaunchServices に登録されていない)バンドル ID は「そのようなバンドル ID はない」と断られる。許可したあとで未許可に戻るかは立ち会い B で確かめる
- 署名のときにキーチェーンのダイアログは出なかった
