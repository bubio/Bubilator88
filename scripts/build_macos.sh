#!/bin/bash
# Build the macOS app locally with explicit Swift exclusivity settings.
set -euo pipefail

PROJECT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
configuration=Debug
exclusivity=checked
core=local
build_root="$PROJECT/build/macos"
dry_run=false

usage() {
  cat <<'EOF'
Usage: build_macos.sh [options]
  --configuration Debug|Release  Xcode configuration (default: Debug)
  --exclusivity checked|unchecked  Dynamic exclusivity (default: checked)
  --core local|pinned            Core source (default: local sibling clone)
  --build-root PATH              Output root (default: build/macos in the repo)
  --dry-run                      Print the command without building
  -h, --help                     Show this help
EOF
}

fail() { printf 'Error: %s\n' "$*" >&2; exit 2; }

while (($#)); do
  case "$1" in
    --configuration|--exclusivity|--core|--build-root)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || fail "Missing value for $1"
      case "$1" in
        --configuration) configuration=$2 ;;
        --exclusivity) exclusivity=$2 ;;
        --core) core=$2 ;;
        --build-root) build_root=$2 ;;
      esac
      shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

case "$configuration" in Debug) configuration_dir=debug ;; Release) configuration_dir=release ;; *) fail "Invalid configuration: $configuration" ;; esac
case "$exclusivity" in checked|unchecked) ;; *) fail "Invalid exclusivity: $exclusivity" ;; esac
case "$core" in local|pinned) ;; *) fail "Invalid core source: $core" ;; esac
[[ $(uname -s) == Darwin ]] || fail 'This entry point requires macOS and Xcode'
if [[ "$core" == local ]]; then
  [[ -f "$PROJECT/../Bubilator88Core/Package.swift" ]] || fail 'Clone ../Bubilator88Core or use --core pinned'
  source_args=(-workspace "$PROJECT/Bubilator88Dev.xcworkspace")
else
  source_args=(-project "$PROJECT/Bubilator88.xcodeproj" -onlyUsePackageVersionsFromResolvedFile)
fi
[[ "$build_root" == /* ]] || build_root="$PWD/$build_root"
output="$build_root/$core/$configuration_dir-$exclusivity"
derived="$output/DerivedData"
command=(xcodebuild "${source_args[@]}" -scheme Bubilator88
  -configuration "$configuration" -derivedDataPath "$derived"
  -destination 'generic/platform=macOS'
  "SWIFT_ENFORCE_EXCLUSIVE_ACCESS=$exclusivity" "ARCHS=$(uname -m)"
  ONLY_ACTIVE_ARCH=YES CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES build)

printf 'Core: %s; configuration: %s; exclusivity: %s\n' "$core" "$configuration" "$exclusivity"
printf '%q ' "${command[@]}"
printf '\n'
if "$dry_run"; then exit 0; fi

mkdir -p "$output"
printf 'Log: %s\n' "$output/build.log"
cd "$PROJECT"
"${command[@]}" 2>&1 | tee "$output/build.log"
app="$derived/Build/Products/$configuration/Bubilator88.app"
printf 'App: %s\nLaunch: open %q\n' "$app" "$app"
