# Release exclusivity policy

Swift's dynamic exclusivity checks remain enabled in normal development builds.
The macOS distribution workflow, Windows core builds, and explicitly selected
local performance builds request `unchecked`. Static exclusivity
diagnostics remain enabled; neither `-enforce-exclusivity=none` nor `-Ounchecked`
is used. No package manifest or persistent Xcode setting disables checks.

## Validation and distribution

- Core PR/main CI runs Debug and Release tests with explicit `checked`.
- App PR/main CI tests the exact core revision in the app's `Package.resolved`,
  in both Debug and Release with explicit `checked`.
- Core Release Tag tests its base commit in checked Debug, checked Release and
  unchecked Release before the existing tag script runs.
- App release CI independently tests its exact pinned core in checked and
  unchecked Release with the same selected Xcode toolchain used for the app.
  Each test variant uses a fresh SwiftPM scratch directory.
- The distribution build passes `SWIFT_ENFORCE_EXCLUSIVE_ACCESS=unchecked` to
  `xcodebuild`. It builds the bare project with locked package resolution.
- Before packaging, CI verifies actual compiler arguments for the app, every
  core module and Logging, and checks dependency checkout SHAs against the app
  lockfile. Missing commands, conflicting flags, wrong revisions or failed tests
  stop DMG creation. Logs and test summaries are retained as Actions artifacts.

A successful build with no warnings is insufficient: dynamic exclusivity
violations are runtime failures. Tests must execute with checks enabled.
Passing tests covers exercised paths, not every possible runtime interaction.
The automated gate currently tests the core; manual app testing and the existing
game regression suite still matter. Windows builds the stable core directly with
explicit `unchecked` and does not rely on the toolchain default.

## Local verification

For everyday development and local performance builds, see
[Local macOS builds](LOCAL_BUILD.md). Those builds accept the working copy of
the sibling core; the release-validation helper below requires a clean pinned
checkout instead.

Use a clean, separate core checkout at the revision in the app lockfile. Do not
reset a development checkout that contains work. The output directory must not
already exist:

```sh
python3 -m unittest discover -s scripts/tests -v
python3 scripts/test_pinned_core.py --core /path/to/clean/Bubilator88Core \
  --configuration debug release --mode checked unchecked \
  --output /tmp/b88-exclusivity-tests-new
```

For an unchecked app build, use the command in `.github/workflows/release.yml`
with a fresh DerivedData directory, then verify both evidence sources:

```sh
python3 scripts/check_exclusivity.py --mode unchecked --xcode-log release-build.log
python3 scripts/test_pinned_core.py --xcode-checkouts build/SourcePackages/checkouts
```

The helper deliberately rejects a dirty or differently pinned core checkout.
It also rejects transitive dependency revisions that differ from the app's lock.
When updating dependencies, align the core lock and app lock before releasing.
When adding a Swift module, update `CORE_MODULES` in `scripts/check_exclusivity.py`
so its compiler settings are verified too.

To restore checked distribution builds, change the release build setting and
the following compiler verification's `--mode` to `checked` together.
Keep the checked test gate in place.

## Local verification on 2026-09-14

The app-pinned core `521df6608d77e868ba759660adf47c15cedb0ee0` passed 875 tests
in each of Debug checked, Debug unchecked, Release checked and Release unchecked
with Swift 6.3.3 on arm64 macOS. All six core/dependency modules' SwiftPM compiler
arguments and dependency revisions passed verification. A fresh Release app
build succeeded; all seven required modules explicitly used `unchecked`, and
Xcode dependency checkout revisions matched the app lockfile.

Both Release variants passed all 17 game regression scenarios (20 screenshots,
using the existing Wizardry masks). YS (8 MHz, 500 frames, turbo 8) and SB2 Music
Disk v4 (4 MHz, 1800 frames, turbo 1), with virtual RTC enabled, produced
byte-identical WAV and final PPM files across checked and unchecked builds.
The four validation-helper tests and workflow syntax validation also passed.
The app build emitted only App Intents metadata-extraction warnings about the
absent AppIntents.framework dependency; this is not a warning-free build claim.

These results validate the currently pinned release, which does not yet contain
the separate pending hot-path optimizations. GitHub-hosted execution must still
be confirmed after these workflow changes are pushed.
