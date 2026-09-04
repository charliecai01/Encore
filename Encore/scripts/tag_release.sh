#!/bin/bash
# Bumps Encore's version (Encore/VERSION, the macOS Info.plist embedded in
# build_app.sh, and the iOS project.yml), commits the bump, and creates+pushes
# an annotated git tag vX.Y.Z to origin.
#
# Usage: scripts/tag_release.sh [major|minor|patch]   (default: patch)
set -euo pipefail
cd "$(dirname "$0")/.."

BUMP="${1:-patch}"
case "$BUMP" in
    major|minor|patch) ;;
    *) echo "Usage: $0 [major|minor|patch]" >&2; exit 1 ;;
esac

if [ -n "$(git status --porcelain)" ]; then
    echo "Working tree not clean — commit or stash pending changes first." >&2
    exit 1
fi

VERSION_FILE="VERSION"
CURRENT=$(cat "$VERSION_FILE")
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"

case "$BUMP" in
    major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
    minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
    patch) PATCH=$((PATCH + 1)) ;;
esac

NEW="$MAJOR.$MINOR.$PATCH"
TAG="v$NEW"

if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "Tag $TAG already exists." >&2
    exit 1
fi

echo "$NEW" > "$VERSION_FILE"

# macOS: the two Info.plist version strings embedded in build_app.sh. BSD
# sed (macOS default) has no GNU `0,/regex/` first-match address, so match
# each value by the <key> line immediately above it instead.
sed -i '' -E \
    "/<key>CFBundleShortVersionString<\/key>/{n;s/<string>$CURRENT<\/string>/<string>$NEW<\/string>/;}" \
    scripts/build_app.sh
sed -i '' -E \
    "/<key>CFBundleVersion<\/key>/{n;s/<string>$CURRENT<\/string>/<string>$NEW<\/string>/;}" \
    scripts/build_app.sh

# iOS: CFBundleShortVersionString / CFBundleVersion in project.yml.
sed -i '' \
    -e "s/CFBundleShortVersionString: \"$CURRENT\"/CFBundleShortVersionString: \"$NEW\"/" \
    -e "s/CFBundleVersion: \"$CURRENT\"/CFBundleVersion: \"$NEW\"/" \
    iOS/project.yml

git add "$VERSION_FILE" scripts/build_app.sh iOS/project.yml
git commit -m "Bump version to $TAG"
git tag -a "$TAG" -m "$TAG"
git push origin main
git push origin "$TAG"

echo "Tagged and pushed $TAG"
