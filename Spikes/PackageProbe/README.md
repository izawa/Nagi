# S9 Swift パッケージ内の Metal シェーダー

- リポジトリのルートから `cd Spikes/PackageProbe` で移動する。
- (a) SwiftPM でビルドして実行する。 `swift build && .build/debug/probe`
- (b) Xcode で Release ビルドする。 `xcodebuild -scheme probe -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath build/dd build`
- (b) Release の実行ファイルを起動する。 `./build/dd/Build/Products/Release/probe`
- (c) macOS アプリに `ProbeShaders` をリンクし、エントリーポイントを `Sources/probe/main.swift` に差し替えてアーカイブ・書き出しする。
- (c) 書き出した `.app` の `Contents/MacOS/` にある実行ファイルをターミナルで起動し、`PASS` と `.app` 内の `default.metallib` のパスを確認する。
- `metal` が見つからない場合は `swift package clean` の後に (a) を再試行する。
