#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
# The project lives on Google Drive, which re-adds extended attributes the
# moment they are cleared. codesign rejects those, so stage the bundle on a
# local disk and sign it there.
stage_dir="/tmp/napeprofix-stage"
app_dir="$stage_dir/NapeProFix.app"
contents_dir="$app_dir/Contents"

export CLANG_MODULE_CACHE_PATH="/tmp/napeprofix-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="/tmp/napeprofix-swift-cache"

cd "$project_dir"
swift build -c release

rm -rf "$app_dir"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$project_dir/.build/release/NapeProFix" "$contents_dir/MacOS/NapeProFix"
cp "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"
cp "$project_dir/Resources/AppIcon.icns" "$contents_dir/Resources/AppIcon.icns"
# SwiftPM keeps target resources in their own bundle; Bundle.module looks for
# it next to the executable's resources.
cp -R "$project_dir/.build/release/NapeProFix_NapeProFix.bundle" "$contents_dir/Resources/"

# A stable signing identity keeps the app's designated requirement unchanged
# across rebuilds, so the accessibility approval survives an update. Ad-hoc
# signatures are cdhash-based and lose it every time.
if [[ -n "${NAPEPROFIX_SIGN_IDENTITY:-}" ]]; then
  identity="$NAPEPROFIX_SIGN_IDENTITY"
else
  identity=$(security find-identity -v -p codesigning \
    | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')
fi
if [[ -z "$identity" ]]; then
  identity="-"
  echo "警告: 署名IDが見つかりません。アドホック署名のため更新のたびに権限の再登録が必要です。" >&2
fi
echo "署名ID: $identity" >&2

xattr -cr "$app_dir"
codesign --force --deep --sign "$identity" "$app_dir"
codesign --verify --strict "$app_dir"

echo "$app_dir"
