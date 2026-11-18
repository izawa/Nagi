#!/bin/zsh
# Builds the M0 spike apps (docs/M0-PLAN.md section 2) into build/spikes/:
#   NagiSpike-granted.app   org.izawa.nagi.spike.granted
#   NagiSpike-plain.app     org.izawa.nagi.spike.plain
#   NagiSpike-*-sandboxed.app (with --sandboxed)  …granted.sandboxed / …plain.sandboxed
#   NagiFixture.app         org.izawa.nagi.spike.fixture
# All are signed with Developer ID and Hardened Runtime so that TCC keeps a stable
# identity across rebuilds. The identity comes from $SIGN_IDENTITY or Config/Local.xcconfig.
set -euo pipefail

root=${0:A:h:h:h}
out=$root/build/spikes
sandboxed=false
[[ ${1:-} == --sandboxed ]] && sandboxed=true

identity=${SIGN_IDENTITY:-$(sed -nE 's/^SIGN_IDENTITY *= *(.+)$/\1/p' $root/Config/Local.xcconfig 2>/dev/null || true)}
[[ -n $identity ]] || { echo "SIGN_IDENTITY is not set (env or Config/Local.xcconfig)" >&2; exit 1; }

swift build -c release --package-path $root/Spikes/Harness
products=$(swift build -c release --package-path $root/Spikes/Harness --show-bin-path)
build_number=$(date +%Y%m%d%H%M%S)

# make_app <name> <executable> <bundle id> <LSUIElement true|false> [entitlements]
make_app() {
    local app=$out/$1.app exe=$2 id=$3 agent=$4 entitlements=${5:-}
    rm -rf $app
    mkdir -p $app/Contents/MacOS $app/Contents/Resources
    /bin/cp -f $products/$exe $app/Contents/MacOS/$exe
    for bundle in $products/*.bundle(N); do
        /bin/cp -R $bundle $app/Contents/Resources/
    done
    cat > $app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$id</string>
  <key>CFBundleExecutable</key><string>$exe</string>
  <key>CFBundleName</key><string>$1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.0</string>
  <key>CFBundleVersion</key><string>$build_number</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><$agent/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
    # Inside out, without --deep: resource bundles first, then the app.
    for bundle in $app/Contents/Resources/*.bundle(N); do
        codesign --force --sign $identity --timestamp=none $bundle
    done
    local -a extra=()
    [[ -n $entitlements ]] && extra=(--entitlements $entitlements)
    codesign --force --sign $identity --timestamp=none --options runtime $extra $app
    codesign --verify --strict $app
    echo "built $app ($id)"
}

mkdir -p $out
sandbox_entitlements=$out/sandbox.entitlements
cat > $sandbox_entitlements <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><true/>
</dict></plist>
PLIST

for variant in granted plain; do
    make_app NagiSpike-$variant Harness org.izawa.nagi.spike.$variant true
    if $sandboxed; then
        make_app NagiSpike-$variant-sandboxed Harness org.izawa.nagi.spike.$variant.sandboxed true $sandbox_entitlements
    fi
done
make_app NagiFixture Fixture org.izawa.nagi.spike.fixture false
