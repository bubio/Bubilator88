#!/bin/bash
# Install a release DMG on a fresh macOS VM (Tart) and check what a first-time
# user gets: the app's signature and extensions, the .d88 handler, and the
# Quick Look thumbnails Finder would draw for the given files.
#
# Usage: scripts/vm_release_check.sh [--image IMAGE] [--bios DIR] [--keep]
#                                    <path/to.dmg | vX.Y.Z> [file.b88s|file.d88 ...]
#
#   --image  Tart image to clone (default: macos-tahoe-vanilla:26.6.2)
#   --bios   Directory whose *.ROM files are copied into the VM, so .d88
#            thumbnails can boot. The VM is local and deleted afterwards.
#   --keep   Leave the VM running instead of deleting it (prints its name)
#
# A tag is downloaded from the GitHub release. The DMG is installed the way the
# README tells users to: copied from the DMG with a download quarantine, then
# cleared with `xattr -cr`, then launched once. Cirrus Labs images ship with
# Gatekeeper disabled, which that route does not depend on anyway. Vanilla
# images log in as admin/admin with SSH enabled.
#
# Needs swiftc and Tart on the host: `brew install openai/tools/tart` (the old
# cirruslabs/cli tap stopped at 2.32.1 and fails on current Homebrew). The
# first run pulls the image, about 24 GB.
set -euo pipefail

IMAGE="ghcr.io/cirruslabs/macos-tahoe-vanilla:26.6.2"
BIOS=""
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --image) IMAGE="$2"; shift 2 ;;
    --bios) BIOS="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) break ;;
  esac
done
[ $# -ge 1 ] || { sed -n '2,22p' "$0"; exit 2; }
SOURCE="$1"; shift

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/b88-vmcheck.XXXXXX")"
mkdir -p "$WORK/files" "$WORK/bios"

# The DMG: a local file, or a release tag to download.
if [ -f "$SOURCE" ]; then
  cp "$SOURCE" "$WORK/app.dmg"
else
  gh release download "$SOURCE" -R bubio/Bubilator88 -p "*.dmg" -O "$WORK/app.dmg"
fi
for f in "$@"; do cp "$f" "$WORK/files/"; done
[ -z "$BIOS" ] || cp "$BIOS"/*.ROM "$WORK/bios/" 2>/dev/null || true

# Vanilla images have no Swift toolchain, so the guest-side helpers are built here.
swiftc -O -target arm64-apple-macos26.0 "$REPO/scripts/ql_thumbnail_check.swift" \
  -o "$WORK/ql_thumbnail_check"
cat > "$WORK/d88_handler.swift" <<'EOF'
import AppKit
import UniformTypeIdentifiers
let type = UTType(filenameExtension: "d88")!
print(type.identifier, "->", NSWorkspace.shared.urlForApplication(toOpen: type)?.path ?? "none")
EOF
swiftc -O -target arm64-apple-macos26.0 "$WORK/d88_handler.swift" -o "$WORK/d88_handler"

# Hand the vanilla image's password to ssh without sshpass.
printf '#!/bin/sh\necho admin\n' > "$WORK/askpass.sh"
chmod +x "$WORK/askpass.sh"

VM="b88check-$(date +%s)"
cleanup() {
  if [ "$KEEP" = 1 ]; then
    echo "VM kept running: $VM (ip $(tart ip "$VM" 2>/dev/null || echo ?))"
  else
    tart stop "$VM" >/dev/null 2>&1 || true
    tart delete "$VM" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "== cloning $IMAGE as $VM"
tart clone "$IMAGE" "$VM"
tart run "$VM" --no-graphics --dir="share:$WORK:ro" >"$WORK/run.log" 2>&1 &
IP="$(tart ip "$VM" --wait 180)"

guest() {
  SSH_ASKPASS="$WORK/askpass.sh" SSH_ASKPASS_REQUIRE=force \
    ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o PubkeyAuthentication=no -o ConnectTimeout=5 "admin@$IP" "$@"
}
for _ in $(seq 1 60); do guest true </dev/null 2>/dev/null && break; sleep 3; done

echo "== running checks in the guest ($IP)"
guest 'bash -s' <<'GUEST' || true
set -u
S="/Volumes/My Shared Files/share"
for _ in $(seq 1 30); do [ -f "$S/app.dmg" ] && break; sleep 2; done
sw_vers -productVersion

# Install as a downloaded DMG would be, then follow the README.
cp "$S/app.dmg" ~/Downloads/app.dmg
xattr -w com.apple.quarantine "0083;$(printf %x "$(date +%s)");Safari;" ~/Downloads/app.dmg
MNT="$(hdiutil attach -nobrowse -readonly ~/Downloads/app.dmg | awk -F'\t' '/\/Volumes\//{print $NF}')"
ditto "$MNT/Bubilator88.app" /Applications/Bubilator88.app
hdiutil detach "$MNT" >/dev/null
xattr -cr /Applications/Bubilator88.app

if ls "$S/bios/"*.ROM >/dev/null 2>&1; then
  mkdir -p ~/Library/Application\ Support/Bubilator88
  cp "$S/bios/"*.ROM ~/Library/Application\ Support/Bubilator88/
fi

echo "-- extension entitlements"
codesign -d --entitlements - \
  /Applications/Bubilator88.app/Contents/PlugIns/Bubilator88QuickLook.appex 2>&1 \
  | grep -o 'com.apple.security[a-z.-]*' | sort -u

echo "-- first launch"
open -a /Applications/Bubilator88.app
sleep 15
osascript -e 'tell application "Bubilator88" to quit' >/dev/null 2>&1 || killall Bubilator88 2>/dev/null
sleep 3

echo "-- registered extensions"
pluginkit -m -v -i com.bubio.Bubilator88.QuickLook
pluginkit -m -v -i com.bubio.Bubilator88.QuickLookPreview

echo "-- .d88 handler"
"$S/d88_handler"

if ls "$S/files/"* >/dev/null 2>&1; then
  echo "-- Quick Look thumbnails"
  mkdir -p ~/Desktop/qlcheck
  cp "$S/files/"* ~/Desktop/qlcheck/
  "$S/ql_thumbnail_check" ~/Desktop/qlcheck/*
fi
GUEST
