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
# Developer ID first: it is the only identity notarization accepts, and it is
# what lets the app open on a Mac other than this one. Apple Development is the
# fallback for a machine without one.
if [[ -n "${NAPEPROFIX_SIGN_IDENTITY:-}" ]]; then
  identity="$NAPEPROFIX_SIGN_IDENTITY"
else
  identities=$(security find-identity -v -p codesigning)
  identity=$(echo "$identities" | awk -F'"' '/Developer ID Application/ {print $2; exit}')
  if [[ -z "$identity" ]]; then
    identity=$(echo "$identities" | awk -F'"' '/Apple Development/ {print $2; exit}')
  fi
fi
if [[ -z "$identity" ]]; then
  identity="-"
  echo "警告: 署名IDが見つかりません。アドホック署名のため更新のたびに権限の再登録が必要です。" >&2
fi
echo "署名ID: $identity" >&2

# Hardened Runtime is required for notarization. No entitlements are needed:
# accessibility is granted through TCC, not through an entitlement.
sign_options=(--force --sign "$identity")
if [[ "$identity" == "Developer ID Application"* ]]; then
  sign_options+=(--options runtime --timestamp)
fi

xattr -cr "$app_dir"

# Sign the app bundle itself, without --deep. --deep does not reliably carry
# the options to nested code: notarization rejected a --deep bundle because the
# main executable had neither the hardened runtime nor a secure timestamp, even
# though the outer bundle did.
#
# The SwiftPM resource bundle alongside the executable is not signed separately
# — it holds no code, codesign rejects it as "bundle format unrecognized", and
# signing the app seals it as a resource anyway.
codesign "${sign_options[@]}" "$app_dir"
codesign --verify --strict --deep "$app_dir"

echo "$app_dir"
