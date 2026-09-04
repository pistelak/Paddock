#!/bin/sh
# Adds one release to the Sparkle appcast.
#
#   $ SPARKLE_PRIVATE_KEY=… scripts/appcast.sh 0.2.0 build/notes.html pages
#
# Expects build/Paddock-<version>.zip (from scripts/build-release.sh) and an
# HTML fragment of release notes. The appcast is read from and written back
# to <pages-dir>/appcast.xml: generate_appcast keeps every item already in
# that file, so only the newest zip needs to be present, and it creates the
# file on the first run. Enclosure URLs point at the GitHub Release assets.
#
# The private key comes from the environment (the SPARKLE_PRIVATE_KEY repo
# secret in CI; locally, `sparkle-tools/bin/generate_keys -x` exports it).
# Sparkle's tools are downloaded once and checked against a pinned hash.
set -eu

version="${1:?usage: $0 X.Y.Z notes.html pages-dir}"
notes="${2:?usage: $0 X.Y.Z notes.html pages-dir}"
pages="${3:?usage: $0 X.Y.Z notes.html pages-dir}"
: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY is not set}"

cd "$(dirname "$0")/.."

sparkle_version=2.9.6
sparkle_sha256=52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192
tools=sparkle-tools
if [ ! -x "$tools/bin/generate_appcast" ]; then
    archive="Sparkle-$sparkle_version.tar.xz"
    curl -sSL -o "$archive" \
        "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/$archive"
    echo "$sparkle_sha256  $archive" | shasum -a 256 -c - >/dev/null
    mkdir -p "$tools"
    tar -xJf "$archive" -C "$tools"
fi

zip="build/Paddock-$version.zip"
[ -f "$zip" ] || {
    echo "$zip does not exist; run scripts/build-release.sh first" >&2
    exit 1
}

updates=build/updates
rm -rf "$updates"
mkdir -p "$updates" "$pages"
cp "$zip" "$updates/"
cp "$notes" "$updates/Paddock-$version.html"

printf '%s' "$SPARKLE_PRIVATE_KEY" | "$tools/bin/generate_appcast" --ed-key-file - \
    --download-url-prefix "https://github.com/pistelak/Paddock/releases/download/v$version/" \
    --link "https://github.com/pistelak/Paddock" \
    --maximum-versions 0 \
    -o "$pages/appcast.xml" "$updates"

grep -q "Paddock-$version.zip" "$pages/appcast.xml" || {
    echo "appcast.xml has no item for $version" >&2
    exit 1
}
echo "$pages/appcast.xml"
