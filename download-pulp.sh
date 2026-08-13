#!/bin/bash
set -e

VERSION="0.56.8"
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    if [ "$OS" = "darwin" ]; then
        ARCH="universal"
    else
        ARCH="aarch64"
    fi
fi

# Map Darwin to macOS
if [ "$OS" = "darwin" ]; then
    OS="macos"
fi

# Map Windows environments
if [[ "$OS" == mingw* ]] || [[ "$OS" == msys* ]] || [[ "$OS" == cygwin* ]]; then
    OS="windows"
fi

ASSET="skred-${VERSION}-maxed-${OS}-${ARCH}.tar.gz"
if [ "$OS" = "windows" ]; then
    ASSET="skred-${VERSION}-maxed-${OS}-${ARCH}.zip"
fi
URL="https://github.com/octetta/pulp/releases/download/v${VERSION}/${ASSET}"
EXTRACT_DIR="clib/pulp"

echo "Downloading Pulp ${VERSION} for ${OS}-${ARCH}..."

mkdir -p "$EXTRACT_DIR"
curl -fLO "$URL" || { echo "Failed to download $URL"; exit 1; }

echo "Extracting ${ASSET}..."
if [ "$OS" = "windows" ]; then
    unzip -q -o "$ASSET" -d "$EXTRACT_DIR"
    # Pulp's zip might have a differently named root folder. 
    # Just move whatever directory was extracted up one level.
    SUBDIR=$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)
    if [ -n "$SUBDIR" ]; then
        mv "$SUBDIR"/* "$EXTRACT_DIR/"
        rm -rf "$SUBDIR"
    fi
else
    tar -xzf "$ASSET" -C "$EXTRACT_DIR" --strip-components=1
fi
rm "$ASSET"

echo "Pulp native libraries downloaded and extracted to ${EXTRACT_DIR}!"

# Download WASM Build
WASM_ASSET="skred-${VERSION}-maxed-wasm.zip"
WASM_URL="https://github.com/octetta/pulp/releases/download/v${VERSION}/${WASM_ASSET}"
WASM_EXTRACT_DIR="priv/static/assets/skred"

echo "Downloading WASM build..."
mkdir -p "$WASM_EXTRACT_DIR"
curl -fLO "$WASM_URL" || { echo "Failed to download $WASM_URL"; exit 1; }

echo "Extracting ${WASM_ASSET}..."
unzip -q -o "$WASM_ASSET" -d "$WASM_EXTRACT_DIR"
SUBDIR=$(find "$WASM_EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)
if [ -n "$SUBDIR" ]; then
    mv "$SUBDIR"/* "$WASM_EXTRACT_DIR/"
    rm -rf "$SUBDIR"
fi
rm "$WASM_ASSET"

echo "WASM build extracted to ${WASM_EXTRACT_DIR}!"
