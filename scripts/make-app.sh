#!/bin/zsh
# Builds build/Nagi.app (scripts/build-app.sh) and optionally installs it into /Applications.
#   scripts/make-app.sh                    → build/Nagi.app
#   scripts/make-app.sh --install          → also copy it to /Applications
#   scripts/make-app.sh --install --open   → and launch the installed copy
set -euo pipefail

install=false open=false
for arg in "$@"; do
    case $arg in
        --install) install=true ;;
        --open) open=true ;;
        *) echo "使い方: $0 [--install [--open]]" >&2; exit 2 ;;
    esac
done
$open && ! $install && { echo "--open は --install と一緒に使います" >&2; exit 2; }

root=${0:A:h:h}
app=$root/build/Nagi.app
dest=/Applications/Nagi.app

$root/scripts/build-app.sh
plist=$app/Contents/Info.plist
echo "  Nagi $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $plist) ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' $plist))"
$install || exit 0

echo "▶ $dest にインストール"
# Nagi lives in the menu bar, so ask it to quit and wait for it.
if pgrep -xq Nagi; then
    osascript -e 'tell application id "org.izawa.Nagi" to quit' >/dev/null 2>&1 || true
    for _ in {1..50}; do pgrep -xq Nagi || break; sleep 0.1; done
    if pgrep -xq Nagi; then
        echo "✗ Nagi が終了しませんでした。メニューバーの葉から終了してから、もう一度実行してください。" >&2
        exit 1
    fi
fi
rm -rf $dest
ditto $app $dest
# Refresh Launch Services so Finder and Spotlight pick up the new icon and version.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f $dest || true
echo "✓ インストールしました: $dest"
$open && open $dest
exit 0
