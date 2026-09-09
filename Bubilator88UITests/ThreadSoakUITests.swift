import XCTest

/// Drives the host-side operations of the `RELEASE_1_5_0_PLAN.md` §3.4 soak
/// against a Thread Sanitizer build, so that the manual pass shrinks to the
/// parts a UI test genuinely cannot reach.
///
/// **This does not replace the manual soak.** It covers the menu-driven half
/// (§3.4 items 3-7, 10, 12, 14). Stepping the debugger, judging audio dropouts,
/// and playing an actual game to a specific state stay manual.
///
/// How the gate works — read this before trusting a green run:
///
/// 1. The app under test must be built with Thread Sanitizer. XCUITest does
///    *not* do that for you; run through `scripts/tsan_ui_soak.sh`, or pass
///    `-enableThreadSanitizer YES` to `xcodebuild test` yourself. Without it
///    these tests still pass and check nothing about thread safety.
/// 2. `TSAN_OPTIONS=halt_on_error=1` (set in `launchEnvironment`) turns a race
///    into an abort. TSan otherwise only writes a warning to the log, the app
///    keeps running, and the test goes green with a race sitting in it.
/// 3. `assertLive()` after every step is what actually notices the abort, and
///    the accessibility query inside it is what notices a deadlock — which TSan
///    is documented not to catch (`KNOWN_PITFALLS.md` §19).
final class ThreadSoakUITests: XCTestCase {

  /// Where the app under test looks for its ROMs (`EmulatorViewModel.loadROMs`).
  ///
  /// The XCUITest runner is a separate, *sandboxed* process, so every path API
  /// available here — `FileManager.urls(for: .applicationSupportDirectory …)`,
  /// `NSHomeDirectory()`, even `NSHomeDirectoryForUser(NSUserName())` — answers
  /// with the runner's own container
  /// (`~/Library/Containers/…Bubilator88UITests.xctrunner/Data/…`), which never
  /// holds the ROMs. Turning off `ENABLE_APP_SANDBOX` for the target does not
  /// change this; the generated `-Runner.app` stays sandboxed.
  ///
  /// So the real path is handed in from outside instead: `scripts/tsan_ui_soak.sh`
  /// exports `TEST_RUNNER_BUBILATOR_ROM_DIR`, and XCTest passes it to this
  /// process with the `TEST_RUNNER_` prefix stripped. Running the suite straight
  /// from Xcode without that variable skips rather than falsely passing.
  private static var romDirectory: URL? {
    guard let path = ProcessInfo.processInfo.environment["BUBILATOR_ROM_DIR"],
          !path.isEmpty else { return nil }
    return URL(fileURLWithPath: path)
  }

  /// N88.ROM is not in the repository, so this suite is a local tool. On a
  /// machine without ROMs the app puts up a modal alert at launch, which would
  /// fail every test here for the wrong reason.
  private static var romsInstalled: Bool {
    guard let dir = romDirectory else { return false }
    return FileManager.default.fileExists(atPath: dir.appending(component: "N88.ROM").path)
  }

  /// Quick Save writes to one fixed path — there is no scratch slot — so
  /// pressing ⌘S here **overwrites the quick save of whoever runs the suite**.
  ///
  /// Backing it up from inside this process does not work: the sandboxed runner
  /// may read that directory but silently fails to write to it, so a restore in
  /// `tearDown` looks like it succeeded and does not. `scripts/tsan_ui_soak.sh`
  /// therefore does the backup and restore itself, outside the sandbox.
  ///
  /// **Running this suite directly from Xcode destroys your quick save.** Go
  /// through the script.
  private static var quickSaveFiles: [URL] {
    guard let dir = romDirectory?.appending(component: "SaveStates") else { return [] }
    return ["quicksave.b88s", "quicksave.meta.json", "quicksave.thumb.png"]
      .map { dir.appending(component: $0) }
  }

  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
    try XCTSkipUnless(
      Self.romsInstalled,
      Self.romDirectory.map { "N88.ROM not found in \($0.path)." }
        ?? "BUBILATOR_ROM_DIR is unset — run this suite through scripts/tsan_ui_soak.sh.")

    app = XCUIApplication()
    // Boot to BASIC from ROM so the suite needs no disk fixture. `-XC…`
    // arguments XCUITest injects are dropped by `LaunchRequest
    // .stripSystemArguments`, so these reach the parser intact.
    app.launchArguments = ["-romboot", "-v2", "-4mhz"]
    // Make a detected race abort the process instead of only logging, and send
    // the report to a file: TSan writes to the app's stderr, which xcodebuild
    // does not capture, so without `log_path` a race leaves only an abort with
    // no explanation of what raced with what.
    var tsanOptions = "halt_on_error=1"
    if let logPrefix = ProcessInfo.processInfo.environment["BUBILATOR_TSAN_LOG"], !logPrefix.isEmpty {
      tsanOptions += ":log_path=\(logPrefix)"
    }
    app.launchEnvironment["TSAN_OPTIONS"] = tsanOptions
    app.launch()
    // TSan slows the app by 5-15x; the first frame takes a while to appear.
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60),
                  "app did not reach the foreground")
    soak(3)
  }

  override func tearDownWithError() throws {
    app?.terminate()
    app = nil
  }

  // MARK: - Helpers

  /// Lets the emulation thread run. Races show up in steady state, not only at
  /// the instant of the operation, so every step is followed by one of these.
  private func soak(_ seconds: TimeInterval) {
    Thread.sleep(forTimeInterval: seconds)
  }

  /// The actual assertion of this suite.
  ///
  /// - A TSan abort (`halt_on_error=1`) leaves the app not running.
  /// - A deadlock leaves it "running" but unable to answer accessibility
  ///   queries, so `waitForExistence` times out and fails here.
  private func assertLive(_ step: String, file: StaticString = #filePath, line: UInt = #line) {
    // The message deliberately avoids spelling out the sanitizer's own banner
    // text: tooling greps the logs for that string to decide whether a race was
    // reported, and an assertion message containing it reads as a false hit.
    XCTAssertEqual(app.state, .runningForeground,
                   "app died after \(step) — inspect the sanitizer report files",
                   file: file, line: line)
    XCTAssertTrue(app.menuBars.firstMatch.waitForExistence(timeout: 10),
                  "app stopped answering accessibility queries after \(step) — possible deadlock",
                  file: file, line: line)
  }

  private func press(_ key: String, _ modifiers: XCUIElement.KeyModifierFlags = .command) {
    app.typeKey(key, modifierFlags: modifiers)
  }

  // MARK: - §3.4 items

  /// Item 4/5: save and load cross the emulation thread via the stop/join
  /// handshake, and `captureThumbnail()` reads the pixel buffer while it does.
  ///
  /// This one also carries the suite's proof of life. Every other test asserts
  /// only that the app survived, which a keystroke landing nowhere would also
  /// satisfy — so here we check that ⌘S actually rewrote the quick save file.
  /// If this fails while the others pass, the shortcuts are not reaching the
  /// app and the whole suite is measuring nothing.
  func testQuickSaveLoadCycle() throws {
    let quickSave = try XCTUnwrap(Self.quickSaveFiles.first)
    let before = (try? quickSave.resourceValues(forKeys: [.contentModificationDateKey]))?
      .contentModificationDate

    for round in 1...3 {
      press("s")
      soak(2)
      assertLive("quick save (round \(round))")

      press("l")
      soak(2)
      assertLive("quick load (round \(round))")
    }

    let after = (try? quickSave.resourceValues(forKeys: [.contentModificationDateKey]))?
      .contentModificationDate
    XCTAssertNotNil(after, "⌘S never produced \(quickSave.lastPathComponent) — the shortcut is not reaching the app")
    if let before, let after {
      XCTAssertGreaterThan(after, before,
                           "⌘S did not rewrite the quick save — the shortcut is not reaching the app")
    }
  }

  /// Item 12 (reset half): reset tears down and restarts the loop.
  func testResetCycle() throws {
    for round in 1...3 {
      press("r")
      soak(3)
      assertLive("reset (round \(round))")
    }
  }

  /// Pause/resume flips `shouldRun` from the main thread while the emulation
  /// thread is inside a frame — the case `stopIsQuiescent()` pins in isolation,
  /// here against the real view model.
  func testPauseResumeCycle() throws {
    for round in 1...4 {
      press("p")
      soak(2)
      assertLive("pause toggle (round \(round))")
    }
  }

  /// Item 3: occlusion parks the loop (`visibilityGatesTheLoop()`), and
  /// `+Launch.swift:152-159` had a pitfall on the way back.
  func testOcclusionCycle() throws {
    let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
    for round in 1...3 {
      finder.activate()
      soak(2)
      app.activate()
      soak(2)
      assertLive("occlusion round \(round)")
    }
  }

  /// Item 8 (attach/detach only — stepping stays manual): the debugger takes
  /// `emuQueue` from the main thread while the emulation thread holds it every
  /// frame.
  func testDebuggerWindowCycle() throws {
    for round in 1...3 {
      press("d", [.command, .shift])
      soak(3)
      assertLive("debugger open (round \(round))")

      // Close the front window; the emulator window stays because the debugger
      // opened on top of it.
      press("w")
      soak(2)
      assertLive("debugger close (round \(round))")
    }
  }

  /// Item 10: rewind calls `machine.keyboard.releaseAll()` off the emulation
  /// thread (`+Rewind.swift:131,184`, no lock).
  ///
  /// ⌘Z is deliberately not bound as a menu shortcut — `AppDelegate`'s local
  /// `NSEvent` monitor owns it (see `ControlCommands.swift`). XCUITest
  /// synthesizes real HID events, so the monitor sees these.
  func testRewindCycle() throws {
    soak(5)  // build up snapshots to rewind through
    for round in 1...3 {
      press("z")
      soak(2)
      assertLive("rewind (round \(round))")
    }
  }

  /// Item 12: the settings window reads `Settings.shared` from the main thread
  /// while the emulation thread reads the same object every frame
  /// (`KNOWN_PITFALLS.md` §19).
  func testSettingsWindowCycle() throws {
    for round in 1...2 {
      press(",")
      soak(3)
      assertLive("settings open (round \(round))")

      press("w")
      soak(2)
      assertLive("settings close (round \(round))")
    }
  }

  /// Item 14: CPU speed is written from the main thread and read by the pacer.
  func testSpeedChangeCycle() throws {
    for round in 1...3 {
      press(.init(XCUIKeyboardKey.upArrow.rawValue))
      soak(2)
      assertLive("speed up (round \(round))")

      press(.init(XCUIKeyboardKey.downArrow.rawValue))
      soak(2)
      assertLive("speed down (round \(round))")
    }
  }

  /// The combination pass. Individual tests each get a fresh process, so none
  /// of them reaches a state built up by the others; races that need one
  /// operation to follow another only appear here.
  func testMixedSoak() throws {
    press("s"); soak(2); assertLive("mixed: save")
    press("p"); soak(2); assertLive("mixed: pause")
    press("p"); soak(2); assertLive("mixed: resume")
    press("d", [.command, .shift]); soak(3); assertLive("mixed: debugger")
    press("w"); soak(2); assertLive("mixed: debugger closed")
    press("l"); soak(2); assertLive("mixed: load")
    press("r"); soak(3); assertLive("mixed: reset")
    press("z"); soak(2); assertLive("mixed: rewind")
    press("s"); soak(2); assertLive("mixed: save again")
    soak(5)
    assertLive("mixed: settled")
  }
}
