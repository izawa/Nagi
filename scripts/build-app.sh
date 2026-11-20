#!/bin/zsh
# Builds build/Nagi.app from `swift build` products (DECISIONS D12): the executable, the resource
# bundles in Contents/Resources, Info.plist, then signs inside out with Developer ID, Hardened
# Runtime and App Sandbox. The identity comes from $SIGN_IDENTITY or Config/Local.xcconfig.
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
cat > $app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>org.izawa.Nagi</string>
  <key>CFBundleExecutable</key><string>Nagi</string>
  <key>CFBundleName</key><string>Nagi</string>
  <key>CFBundleDisplayName</key><string>Nagi</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M%S)</string>
  <key>CFBundleDevelopmentRegion</key><string>ja</string>
  <key>CFBundleLocalizations</key><array><string>ja</string><string>en</string></array>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
for bundle in $app/Contents/Resources/*.bundle(N); do
    codesign --force --sign $identity $timestamp $bundle
done
codesign --force --sign $identity $timestamp --options runtime --entitlements $root/App/Nagi.entitlements $app
codesign --verify --strict $app
echo "built $app"
