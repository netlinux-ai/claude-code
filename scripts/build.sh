#!/bin/bash
set -euo pipefail

# Build script for Claude Code .deb package
# Downloads the npm package, beautifies JS, builds ripgrep from source,
# and prepares the staging directory for checkinstall.

STAGING="staging"
RG_VERSION="14.1.1"

echo "==> Downloading @anthropic-ai/claude-code from npm"
npm pack @anthropic-ai/claude-code
TARBALL=$(ls anthropic-ai-claude-code-*.tgz)
VERSION=$(echo "$TARBALL" | sed 's/anthropic-ai-claude-code-\(.*\)\.tgz/\1/')
echo "==> Version: ${VERSION}"

echo "==> Extracting npm package"
mkdir -p "$STAGING"
tar xzf "$TARBALL" --strip-components=1 -C "$STAGING"

echo "==> Beautifying cli.js"
npx js-beautify@latest --type js -f "$STAGING/cli.js" -o "$STAGING/cli.js.pretty"
mv "$STAGING/cli.js.pretty" "$STAGING/cli.js"

echo "==> Building ripgrep ${RG_VERSION} from source"
git clone --depth 1 --branch "${RG_VERSION}" https://github.com/BurntSushi/ripgrep.git ripgrep-src
cd ripgrep-src
cargo build --release --features pcre2
cd ..

echo "==> Replacing bundled ripgrep binary with source build"
cp ripgrep-src/target/release/rg "$STAGING/vendor/ripgrep/x64-linux/rg"

echo "==> Removing non-Linux platform binaries"
for dir in "$STAGING"/vendor/ripgrep/*/; do
    dirname=$(basename "$dir")
    if [ "$dirname" != "x64-linux" ] && [ "$dirname" != "COPYING" ]; then
        echo "    Removing vendor/ripgrep/${dirname}/"
        rm -rf "$dir"
    fi
done

echo "==> Removing files not needed for Linux package"
rm -f "$STAGING/bun.lock"

echo "==> Staging directory ready"
ls -la "$STAGING/"
echo ""
echo "VERSION=${VERSION}"
