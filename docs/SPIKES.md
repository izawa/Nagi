# M0 技術検証の結果

計画は [M0-PLAN.md](M0-PLAN.md)。確かめたのは macOS 27.2.1 だけである。

| ID | SPEC の節 | 判定 | 採った案 |
|---|---|---|---|
| S1 | 3.7 | 未実施 | |
| S2 | 3.5、4.1 | 未実施 | |
| S3 | 2.2、3.8 | 一部(Claude の分) | 下記 |
| S4 | 3.9、5 | 未実施 | |
| S5 | 3.10 | 未実施 | |
| S6 | 2.5、3.7 | 未実施 | |
| S7 | 6.1 | 未実施 | |
| S8 | 4.2 | 未実施 | |
| S9 | 3.2、3.12 | 条件付きで合格(.app は S1 で確かめる) | SwiftPM の `.process` で metallib を作り、`Bundle.module` から読む |
| S10 | 6.1 | 未実施 | |

共通の環境: Mac mini(Mac16,11、M4 Pro)、macOS 27.2.1、Xcode 27.2(27B52)、Swift 6.4.2、Studio Display 1 台(5K、60 Hz)。

---

### S9 パッケージ内の Metal シェーダー

- 判定: 条件付きで合格。.app に入れた場合は未確認で、S1 の Harness で確かめてから合格にする
- 手順: `Spikes/PackageProbe`。`ProbeShaders` ターゲットに `Shaders.metal` を `.process` で置き、`probe` が `device.makeDefaultLibrary(bundle: Bundle.module)` で読んで 2×2 の rgba16Float に書き、4 ピクセルの値を確かめる
- 結果:
  - `swift build`(Debug)と `swift build -c release`: どちらも PASS。リソースのバンドルの中に `default.metallib` ができた。Swift 6.4 の SwiftPM は成果物を `.build/out/Products/<構成>/` に置く
  - `xcodebuild -scheme probe -configuration Release`: PASS
  - 実行ファイルとリソースのバンドルを別のフォルダへ移し、元のバンドルを隠した場合: PASS(移した先のバンドルから読んだ)
  - デプロイメントターゲットは `.macOS(.v26)` でビルドが通った
  - Mac を再起動したあとの Metal ツールチェーンのマウント先の問題は、今回は起きなかった
- 仕様への反映: SPEC 3.2 の構成のまま、シェーダーは各パッケージに `.process` で置ける。ビルドは `swift build` でよく、`xcodebuild` も使える。`nagi-render` は `swift build` で作れる。アプリの .app は、HanaLima と同じく `swift build` の成果物をスクリプトで組み立てる形を第一案にする。リソースのバンドルを `Contents/Resources` に置いて読めるかは S1 で確かめる
- M1 への持ち込み: シェーダーをリソースとして置くパッケージの書き方

### S3 無入力の時間と電源アサーション

- 判定: 一部。Claude が 1 人で確かめられる範囲だけ。入力の種類ごとの確認、動画と Zoom、ロックなどの通知は立ち会い A・B で行う
- 手順: `Spikes/IdleProbe/main.swift`(`swiftc` でビルド)。0.5 秒ごとに `CGEventSource.secondsSinceLastEventType` を `.hidSystemState` と `.combinedSessionState` で、`IOPMCopyAssertionsStatus` と `IOPMCopyAssertionsByProcess` を読む。画面の状態の通知も待ち受ける。権限は何も求めていない
- 結果:
  - 無入力の秒数は、権限なしの CLI で両方の状態 ID から取れた。2 つの値は同じだった
  - `caffeinate -d` を実行している間、そのプロセスの `PreventUserIdleDisplaySleep` が取れた。終了すると消えた
  - `caffeinate -i` は `PreventUserIdleSystemSleep` だけで、画面のスリープ防止としては拾われなかった
  - 注意: 利用者が操作したあと、powerd(システムのプロセス)が `InternalPreventDisplaySleep`(名前は `delayDisplayOff`)を持つ。ほかにも WindowServer がトラックパッドに触れるたびに `UserIsActive` を、Electron 製のアプリが `NoIdleSleepAssertion`(システムのスリープの防止)を持っていた。動画の検出では、他プロセスの `PreventUserIdleDisplaySleep` だけを数え、`Internal…` で始まる種類とシステムのスリープの防止は数えないことにする
- 仕様への反映(立ち会いのあとで確定): SPEC 3.8 の検出の条件を「他プロセスの `PreventUserIdleDisplaySleep`」と書く
- M1 への持ち込み: アサーションの種類の絞り込み
