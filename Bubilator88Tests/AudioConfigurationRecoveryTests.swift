import AVFoundation
import Testing
@testable import Bubilator88

@MainActor
struct AudioConfigurationRecoveryTests {
  @Test func restartsOnlyObservedOutput() async throws {
    let recovery = AudioConfigurationRecovery()
    let output = NSObject()
    var starts = 0
    recovery.observe(output) { starts += 1 }
    NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: NSObject())
    try await Task.sleep(for: .milliseconds(50))
    #expect(starts == 0)
    NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: output)
    try await Task.sleep(for: .milliseconds(50))
    #expect(starts == 1)
    recovery.stop()
  }

  @Test func stopDiscardsQueuedNotification() async throws {
    let recovery = AudioConfigurationRecovery()
    let output = NSObject()
    var starts = 0
    recovery.observe(output) { starts += 1 }
    NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: output)
    recovery.stop()
    try await Task.sleep(for: .milliseconds(50))
    #expect(starts == 0)
  }

  @Test func retriesTransientFailure() async throws {
    struct Unavailable: Error {}
    let recovery = AudioConfigurationRecovery()
    let output = NSObject()
    var attempts = 0
    recovery.observe(output) {
      attempts += 1
      if attempts == 1 { throw Unavailable() }
    }
    NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: output)
    try await Task.sleep(for: .milliseconds(500))
    #expect(attempts == 2)
    recovery.stop()
  }
}
