#!/bin/bash
# Package a compiled CoreML model for on-demand download.
#
# Models too large to ship in the app bundle (see models/PROVENANCE.md) live in
# models/coreml/ and are published as zip assets on a `models-v*` GitHub
# Release. The app downloads one the first time its filter is selected and
# refuses it unless the SHA-256 and size match the manifest in
# Bubilator88/Rendering/AIModelStore.swift — so after publishing a new zip,
# paste the values this script prints into that manifest.
#
# Usage: scripts/package_ai_model.sh <ModelName> [outdir]
#   e.g. scripts/package_ai_model.sh RealESRGAN_x2
#
# The zip holds `<ModelName>.mlmodelc/` at its root. Resource forks, extended
# attributes and ACLs are left out so the archive carries only the model.
set -euo pipefail

NAME="${1:?usage: $0 <ModelName> [outdir]}"
OUTDIR="${2:-build/models}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/models/coreml/$NAME.mlmodelc"

test -d "$SRC" || { echo "not found: $SRC" >&2; exit 1; }
mkdir -p "$OUTDIR"
ZIP="$OUTDIR/$NAME.mlmodelc.zip"
rm -f "$ZIP"

ditto -c -k --keepParent --norsrc --noextattr --noacl "$SRC" "$ZIP"

SHA256=$(shasum -a 256 "$ZIP" | awk '{print $1}')
SIZE=$(stat -f %z "$ZIP")

echo "file:   $ZIP"
echo "sha256: $SHA256"
echo "bytes:  $SIZE"
