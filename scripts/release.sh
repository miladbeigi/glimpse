#!/bin/bash
# Cuts a release: writes VERSION, commits, tags v<version> and pushes. The Release workflow then tests,
# builds and publishes Glimpse-<version>.zip + .sha256, which install.sh and the in-app updater pick up.
#
#   scripts/release.sh 1.1.0
#   scripts/release.sh patch|minor|major   bump the current VERSION
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "Error: $*" >&2; exit 1; }

current="$(cat VERSION)"
IFS=. read -r major minor patch <<<"$current"
case "${1:-}" in
  patch) version="$major.$minor.$((patch + 1))" ;;
  minor) version="$major.$((minor + 1)).0" ;;
  major) version="$((major + 1)).0.0" ;;
  "") fail "usage: scripts/release.sh <version>|patch|minor|major (current: $current)" ;;
  *) version="${1#v}" ;;
esac
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must look like 1.2.3, got '$version'."

branch="$(git rev-parse --abbrev-ref HEAD)"
[[ "$branch" == master ]] || fail "release from master (on '$branch')."
[[ -z "$(git status --porcelain)" ]] || fail "working tree has uncommitted changes."
git fetch -q origin master --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/master)" ]] || fail "master isn't in sync with origin/master."
git rev-parse -q --verify "refs/tags/v$version" >/dev/null && fail "tag v$version already exists."

echo "$version" > VERSION
git diff --quiet VERSION || git commit -qm "Release $version" VERSION
git tag "v$version"
git push -q origin master "v$version"

repo="$(git remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
echo "Pushed v$version. The Release workflow is building it: https://github.com/$repo/actions"
echo "Watch it with: gh run watch \$(gh run list --workflow Release --limit 1 --json databaseId -q '.[0].databaseId')"
