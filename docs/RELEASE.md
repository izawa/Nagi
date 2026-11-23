# リリースの手順

公証済みの DMG を作り、GitHub Releases で配布する手順。管理者向け。仕組みは SPEC 6 のとおりで、HanaLima の手順と同じ形にしている。

## 前もって要るもの

どれもリリースを作る Mac のログインキーチェーンに置く。

| もの | 中身 | 確かめ方 |
|---|---|---|
| 署名の ID | Developer ID Application の証明書と秘密鍵。名前は `Config/Local.xcconfig` の `SIGN_IDENTITY` に書く(コミットしない。ひな形は `Local.xcconfig.example`) | `security find-identity -v -p codesigning` に出る |
| 公証の認証情報 | プロファイル名 `developer-id-notary`(HanaLima と同じもの) | `xcrun notarytool history --keychain-profile developer-id-notary` が終了コード 0 |

別の ID やプロファイルを使うときは、環境変数 `SIGN_IDENTITY`・`NOTARY_PROFILE` で `scripts/release.sh` に渡す。

## 手順

1. **版を上げる。** `App/Info.plist` の `CFBundleShortVersionString` を書き換えてコミットする。ビルド番号はコミット数で、`scripts/build-app.sh` が書き込む。
2. **テストを通す。**
   ```sh
   (cd App && swift test)
   (cd Packages/NagiKit && swift test)
   (cd Packages/NagiCore && swift test)
   (cd Packages/Effects/KomorebiEffect && swift test)
   ```
3. **DMG を作る。** 作業ツリーにコミットしていない変更があると止まる。
   ```sh
   scripts/release.sh
   ```
   ビルド、タイムスタンプ付きの署名、.app の確かめ、DMG の作成と署名、公証、ステープル、確かめを順に行う。.app の確かめでは、リソースのバンドルとアイコンがあること、苔のバンドルが無いこと(D41)、arm64 だけであること、`LSUIElement`、entitlement が App Sandbox だけであること、どの署名にもタイムスタンプがあること、Hardened Runtime を見る。
   DMG の見た目(開いたウインドウの背景と配置、マウントしたときのアイコン)は `scripts/make_dmg.sh` が Finder に設定させる。画面のある Mac で、同じ名前の DMG をマウントしていない状態で実行する。初回は「Finder を操作しようとしています」の許可が要る。
   背景とボリュームのアイコンの絵は `scripts/make_dmg_art.py`(Pillow と numpy)の先頭の `CONFIG` で決まる。アプリのアイコン(`scripts/make-icon.py --render`)か `CONFIG` を直したら、実行して `App/DMG` の画像を作り直し、コミットする。
   公証は数分かかる。終わると `build/Nagi-<版>.dmg` と、その SHA-256(`build/Nagi-<版>.dmg.sha256`)ができる。Apple に送らずに署名までを試すときは `--no-notarize` を付ける。
4. **ダウンロードした形で入れて確かめる。** 手元で作った DMG には隔離属性が付かないので、そのまま開いても Gatekeeper の確かめにならない。`build/` を手元の HTTP サーバーで出し、Safari か Chrome で落とす(curl では隔離属性が付かない)。
   ```sh
   (cd build && python3 -m http.server --bind 127.0.0.1 8000)   # ブラウザで http://127.0.0.1:8000/Nagi-<版>.dmg を開く
   xattr -p com.apple.quarantine ~/Downloads/Nagi-<版>.dmg   # 値が出ること
   ```
   開発中の `build/Nagi.app` は終了しておく。DMG を開いて Nagi を Applications へドラッグし、Finder から起動する。初回の確認のあと、警告なしに起動することを見る。入れた .app も確かめる。
   ```sh
   spctl -a -t exec -vv /Applications/Nagi.app        # source=Notarized Developer ID
   codesign --verify --strict --deep /Applications/Nagi.app
   ```
5. **タグを付けて push する。** タグは DMG を作ったコミットに付ける。
   ```sh
   git tag -a v<版> -m "Nagi <版>"
   git push origin main v<版>
   ```
6. **リリースを下書きで作り、見てから公開する。**
   ```sh
   gh release create v<版> build/Nagi-<版>.dmg build/Nagi-<版>.dmg.sha256 --draft --verify-tag --title "Nagi <版>" --notes-file <本文のファイル>
   gh release edit v<版> --draft=false --latest
   ```
7. **公開したものを確かめる。** ダウンロードし直して、次の 3 つを見る。
   ```sh
   shasum -a 256 Nagi-<版>.dmg               # 本文の値と同じ
   xcrun stapler validate Nagi-<版>.dmg      # The validate action worked!
   spctl -a -t open --context context:primary-signature -v Nagi-<版>.dmg   # source=Notarized Developer ID
   ```

## リリース本文のひな形

英語の本文のあとに、同じ内容の日本語の節を置く。

- 冒頭: この版で変わったこと
- Requirements / 動作環境: macOS 27 以降、Apple シリコンの Mac
- Install / インストール: DMG を開く → Nagi を Applications へドラッグ → 起動するとメニューバーに出る
- Verify the download / ダウンロードしたファイルの確認: 本文に載せた SHA-256 と、`shasum -a 256 ~/Downloads/Nagi-<版>.dmg`

## うまくいかないとき

- **公証が通らない。** `release.sh` が理由のログ(`notarytool log`)を出す。多いのは、署名に Hardened Runtime かタイムスタンプが無いこと、中のバンドルが署名されていないこと。`release.sh` は公証の前にこの 2 つを確かめている。
- **`--deep` で署名しない。** `build-app.sh` はリソースのバンドルを 1 つずつ署名してから、最後にアプリを署名する(DECISIONS D12)。`--deep` は確かめにだけ使う。
- **署名で「キーチェーンの鍵を使おうとしています」と聞かれる。** ログインパスワードを入れて「常に許可」を押す。
- **`hdiutil create` が非推奨だという警告が出る。** 2026-11 の時点では動くので、そのままにしている。

## 証明書の期限

HanaLima と同じ証明書を使っている。期限と作り直しの流れは HanaLima の `docs/13-release.md` の「証明書の期限」にまとめてある。署名にタイムスタンプを付けているので、配布済みの DMG とアプリは、証明書が切れても開ける。
