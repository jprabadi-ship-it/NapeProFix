#!/bin/zsh
set -euo pipefail

# Pushes the release branch and, when the app carries a version that has no
# GitHub release yet, builds the distributable and publishes the release.
# Use it instead of a plain `git push`: a push without a version bump just
# pushes.
#
# Release notes come from release-notes/<version>.md when that file exists,
# otherwise from the version's section of CHANGELOG.md
# (see release-notes.py next to this script).
#
#   publish.sh            push, then release if the version is new
#   publish.sh --dry-run  print what would happen and the notes; no push,
#                         no build, no release

project_dir="${0:A:h:h}"
repo="jprabadi-ship-it/NapeProFix"
branch="master"
title_format="%s"
footer="公証済み（Developer ID）。どの Mac でもダブルクリックで開けます。"

read_version() {
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist
}

# Prints the files to attach, one per line; build output goes to stderr.
build_assets() {
  scripts/release.sh | tail -n 1
}

# ---- Everything below is the same in every repository. ----

dry_run=false
[[ "${1:-}" == "--dry-run" ]] && dry_run=true

cd "$project_dir"
version=$(read_version)
tag="v$version"
notes_script="${0:A:h}/release-notes.py"

current_branch=$(git rev-parse --abbrev-ref HEAD)
if [[ "$current_branch" != "$branch" ]]; then
  echo "エラー: $branch ブランチで実行してください（いまは $current_branch）。" >&2
  exit 1
fi
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "エラー: コミットしていない変更があります。リリースする内容をコミットしてから実行してください。" >&2
  exit 1
fi

# A name that never appears in the published history must not arrive with a
# push: it is how a real name once came back after being scrubbed from it.
git fetch -q origin "$branch"
published_authors=$(git log --format='%an%n%cn' "origin/$branch" | sort -u)
new_authors=$(git log --format='%an%n%cn' "origin/$branch..HEAD" | sort -u)
unknown=$(comm -13 <(print -r -- "$published_authors") <(print -r -- "$new_authors"))
if [[ -n "$unknown" ]]; then
  echo "エラー: まだ push していないコミットに、公開済みの履歴にない作者名があります。" >&2
  print -r -- "$unknown" | sed 's/^/  /' >&2
  echo "作者名を直してから実行してください（git rebase --exec 'git commit --amend --no-edit --reset-author' など）。" >&2
  exit 1
fi

already_released=false
gh release view "$tag" --repo "$repo" >/dev/null 2>&1 && already_released=true

if [[ "$dry_run" == true ]]; then
  echo "バージョン: $version（タグ $tag）"
  if [[ "$already_released" == true ]]; then
    echo "→ 公開済みのため、push だけ行います。"
  else
    echo "→ push のあと、ビルドして Release を公開します。ノートは次のとおりです。"
    echo "-----"
    python3 -I "$notes_script" "$project_dir" "$version" "$footer"
    echo "-----"
  fi
  exit 0
fi

git push origin "$branch"

if [[ "$already_released" == true ]]; then
  echo "$tag は公開済みなので、リリースはしません（push のみ）。"
  exit 0
fi

# Check the notes before the build: notarization takes minutes, and a missing
# entry should not be discovered after it.
notes_file=$(mktemp -t release-notes)
trap 'rm -f "$notes_file"' EXIT
python3 -I "$notes_script" "$project_dir" "$version" "$footer" > "$notes_file"

assets=("${(@f)$(build_assets)}")
for asset in "${assets[@]}"; do
  if [[ ! -f "$asset" ]]; then
    echo "エラー: 配布ファイルができていません（$asset）。" >&2
    exit 1
  fi
done

gh release create "$tag" "${assets[@]}" \
  --repo "$repo" \
  --target "$(git rev-parse HEAD)" \
  --title "$(printf "$title_format" "$version")" \
  --notes-file "$notes_file"

gh release view "$tag" --repo "$repo" --json url,assets \
  --jq '"公開しました: \(.url)", (.assets[] | "  \(.name)  \(.size) bytes")'
