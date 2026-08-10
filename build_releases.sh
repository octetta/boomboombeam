#!/bin/bash
set -e

echo "========================================"
echo " Building Zig Engine for cross-platform"
echo "========================================"
cd native/skred_port

# Ensure priv directories exist
mkdir -p ../../priv/bin/linux
mkdir -p ../../priv/bin/windows
mkdir -p ../../priv/bin/macos

echo "--> Building for Linux (x86_64)..."
mise exec -- zig build-exe main.zig -I ../../clib/pulp/include ../../clib/pulp/lib64/libapi.a -lasound -lm -lc -O ReleaseFast --name skred_port
cp skred_port ../../priv/bin/linux/

echo "--> Note: Skipping Windows and macOS port builds for now."
echo "    (Cross-compiling the native port requires downloading the Windows and macOS releases of 'libapi.a' from the skred repo first)."

cd ../..

echo "========================================"
echo " Fetching Mix Dependencies"
echo "========================================"
MIX_ENV=prod mise exec -- mix deps.get

echo "========================================"
echo " Building Phoenix Assets"
echo "========================================"
MIX_ENV=prod mise exec -- mix compile
MIX_ENV=prod mise exec -- mix assets.deploy

echo "========================================"
echo " Packaging Desktop App with Burrito"
echo "========================================"
MIX_ENV=prod mise exec -- mix release --overwrite

echo "Done! Check burrito_out/ for your standalone executables."
