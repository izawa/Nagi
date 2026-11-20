#!/bin/zsh
# Builds build/Nagi.app from `swift build` products (DECISIONS D12): the executable, the resource
# bundles and the icon in Contents/Resources, Info.plist, then signs inside out with Developer ID,
# Hardened Runtime and App Sandbox. The identity comes from $SIGN_IDENTITY or Config/Local.xcconfig.
# Release signing (with a secure timestamp) is scripts/release.sh's job; this build has none.
set -euo pipefail

root=${0:A:h:h}
app=$root/build/Nagi.app
identity=${SIGN_IDENTITY:-$(sed -nE 's/^SIGN_IDENTITY *= *(.+)$/\1/p' $root/Config/Local.xcconfig 2>/dev/null || true)}
[[ -n $identity ]] || { echo "SIGN_IDENTITY is not set (env or Config/Local.xcconfig)" >&2; exit 1; }
timestamp=${TIMESTAMP:---timestamp=none}

swift build -c release --package-path $root/App --product Nagi
products=$(swift build -c release --package-path $root/App --show-bin-path)

rm -rf $app
mkdir -p $app/Contents/MacOS $app/Contents/Resources
/bin/cp -f $products/Nagi $app/Contents/MacOS/Nagi
for bundle in $products/*.bundle(N); do /bin/cp -R $bundle $app/Contents/Resources/; done
/bin/cp -f $root/App/AppIcon/AppIcon.icns $app/Contents/Resources/  # drawn by scripts/make-icon.py
# Info.plist (version, icon, LSUIElement) is App/Info.plist; the build number is the commit count,
# so each build can be traced to its commit.
/bin/cp -f $root/App/Info.plist $app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git -C $root rev-list --count HEAD)" $app/Contents/Info.plist
printf "APPL????" > $app/Contents/PkgInfo
for bundle in $app/Contents/Resources/*.bundle(N); do
    codesign --force --sign $identity $timestamp $bundle
done
codesign --force --sign $identity $timestamp --options runtime --entitlements $root/App/Nagi.entitlements $app
codesign --verify --strict $app
echo "built $app"
