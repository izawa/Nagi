# S9 Swift パッケージ内の Metal シェーダー

- リポジトリのルートから `cd Spikes/PackageProbe` で移動する。
- (a) SwiftPM でビルドして実行する。 `swift build && .build/debug/probe`
- (b) Xcode で Release ビルドする。 `xcodebuild -scheme probe -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath build/dd build`
- (b) Release の実行ファイルを起動する。 `./build/dd/Build/Products/Release/probe`
- `metal` が見つからない場合は `swift package clean` の後に (a) を再試行する。
- (c) .app の中で読めるかは Harness が確かめる(`Spikes/scripts/build-spikes.sh` で作り、`--run s9` で起動する)。
