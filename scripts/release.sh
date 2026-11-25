#!/bin/zsh
# Builds the DMG for distribution (SPEC 6.2): timestamped Developer ID signatures, a signed DMG,
# notarization, stapling and checks. Publishing to GitHub Releases is left to a person (docs/RELEASE.md).
#   scripts/release.sh                → build/Nagi-<version>.dmg, notarized by Apple
#   scripts/release.sh --no-notarize  → stop after the signed DMG (nothing is sent to Apple)
#
# Needs, in the login keychain: the Developer ID Application certificate and its key, and notarytool
# credentials saved with `xcrun notarytool store-credentials` (profile developer-id-notary, or
# $NOTARY_PROFILE). The identity comes from $SIGN_IDENTITY or Config/Local.xcconfig (SPEC 6.3).
set -euo pipefail

notarize=true
case ${1:-} in
    "") ;;
    --no-notarize) notarize=false ;;
    *) echo "使い方: $0 [--no-notarize]" >&2; exit 2 ;;
esac

root=${0:A:h:h}
cd $root
export SIGN_IDENTITY=${SIGN_IDENTITY:-$(sed -nE 's/^SIGN_IDENTITY *= *(.+)$/\1/p' Config/Local.xcconfig 2>/dev/null || true)}
[[ -n $SIGN_IDENTITY ]] || { echo "✗ SIGN_IDENTITY がありません(環境変数か Config/Local.xcconfig)" >&2; exit 1; }
profile=${NOTARY_PROFILE:-developer-id-notary}

# The build number is the commit count: local changes would give a different DMG the same number,
# and a shallow clone would count wrong.
[[ $(git rev-parse --is-shallow-repository) == false ]] || { echo "✗ 浅いクローンでは作れません" >&2; exit 1; }
if [[ -n $(git status --porcelain) ]]; then
    echo "✗ コミットしていない変更があります。コミットしてから実行してください。" >&2
    exit 1
fi

TIMESTAMP=--timestamp scripts/build-app.sh
app=$root/build/Nagi.app
plist=$app/Contents/Info.plist
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $plist)

echo "▶ .app を確かめる"
for bundle in NagiApp_Nagi NagiCore_NagiCore KomorebiEffect_KomorebiEffect RainEffect_RainEffect CausticsEffect_CausticsEffect FirefliesEffect_FirefliesEffect GemsEffect_GemsEffect RipplesEffect_RipplesEffect; do
    [[ -d $app/Contents/Resources/$bundle.bundle ]] || { echo "✗ $bundle.bundle がありません" >&2; exit 1; }
done
# Moss stays out of the release (DECISIONS D41).
[[ ! -e $app/Contents/Resources/MossEffect_MossEffect.bundle ]] || { echo "✗ 苔が入っています" >&2; exit 1; }
[[ -f $app/Contents/Resources/AppIcon.icns ]] || { echo "✗ アイコンがありません" >&2; exit 1; }
[[ $(lipo -archs $app/Contents/MacOS/Nagi) == arm64 ]] || { echo "✗ arm64 だけになっていません" >&2; exit 1; }
[[ $(/usr/libexec/PlistBuddy -c "Print :LSUIElement" $plist) == true ]] || { echo "✗ LSUIElement が無い" >&2; exit 1; }
entitlements=$(codesign -d --entitlements - --xml $app 2>/dev/null | plutil -convert json -o - - 2>/dev/null)
[[ $entitlements == '{"com.apple.security.app-sandbox":true}' ]] \
    || { echo "✗ entitlement が App Sandbox だけになっていません: $entitlements" >&2; exit 1; }
for signed in $app $app/Contents/Resources/*.bundle; do
    info=$(codesign -dv --verbose=4 $signed 2>&1)
    [[ $info == *"Timestamp="* ]] || { echo "✗ タイムスタンプがありません: ${signed:t}" >&2; exit 1; }
done
[[ $(codesign -dv --verbose=4 $app 2>&1) == *"(runtime)"* ]] || { echo "✗ Hardened Runtime が無い" >&2; exit 1; }
codesign --verify --strict --deep --verbose=2 $app

dmg=$root/build/Nagi-$version.dmg
echo "▶ $dmg を作る"
rm -f $dmg.sha256  # a checksum from an earlier run would no longer match
scripts/make_dmg.sh $app $dmg "Nagi $version"
codesign --force --timestamp --sign $SIGN_IDENTITY $dmg
codesign --verify --verbose=2 $dmg

if ! $notarize; then
    echo "✓ 署名した DMG を作りました(公証はしていません): $dmg"
    exit 0
fi

echo "▶ 公証を申請(数分かかる)"
# Don't stop when notarytool fails, so that the log with the reason is still printed.
result=$(xcrun notarytool submit $dmg --keychain-profile $profile --wait 2>&1) || true
echo $result
if [[ $result != *"status: Accepted"* ]]; then
    id=$(awk '/^ *id:/ { print $2; exit }' <<<$result)
    echo "✗ 公証が通りませんでした。理由は次のログを見てください。" >&2
    [[ -n $id ]] && xcrun notarytool log $id --keychain-profile $profile >&2
    exit 1
fi

echo "▶ 公証の結果を DMG に付ける"
xcrun stapler staple $dmg

echo "▶ 確かめる"
xcrun stapler validate $dmg
spctl --assess --type open --context context:primary-signature --verbose=2 $dmg
(cd ${dmg:h} && shasum -a 256 ${dmg:t} | tee ${dmg:t}.sha256)  # the bare name, for shasum -c
echo "✓ 配布できる DMG ができました: $dmg"
