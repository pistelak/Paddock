#!/bin/sh
# Prints the next release version, derived from the last reachable v* tag.
#
#   $ scripts/next-version.sh [patch|minor|major]
#   last=v0.1.0
#   version=0.2.0
#
# `last` is empty when no release tag is reachable; the version then counts
# from 0.0.0. Tags are the only place a version lives: project.yml keeps a
# 0.0.0 placeholder and scripts/build-release.sh passes this value to
# xcodebuild. Tags that are not exactly vN.N.N are refused rather than guessed
# at, and tags without the v prefix are never considered.
set -eu

bump="${1:-patch}"
case "$bump" in
    patch | minor | major) ;;
    *)
        echo "usage: $0 [patch|minor|major]" >&2
        exit 2
        ;;
esac

last="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
if [ -n "$last" ]; then
    base="${last#v}"
else
    base="0.0.0"
fi

major="${base%%.*}"
rest="${base#*.}"
minor="${rest%%.*}"
patch="${rest#*.}"
for part in "$major" "$minor" "$patch"; do
    case "$part" in
        '' | *[!0-9]*)
            echo "last tag '$last' is not of the form vN.N.N" >&2
            exit 1
            ;;
    esac
done
case "$base" in
    "$major.$minor.$patch") ;;
    *)
        echo "last tag '$last' is not of the form vN.N.N" >&2
        exit 1
        ;;
esac

case "$bump" in
    major)
        major=$((major + 1))
        minor=0
        patch=0
        ;;
    minor)
        minor=$((minor + 1))
        patch=0
        ;;
    patch) patch=$((patch + 1)) ;;
esac

echo "last=$last"
echo "version=$major.$minor.$patch"
