import Foundation
import Testing
@testable import Bubilator88

struct DiscordPresenceTests {
  private func decode(_ frame: Data) -> (opcode: UInt32, length: UInt32, json: [String: Any]) {
    let opcode = frame.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self)) }
    let length = frame.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) }
    let json = (try? JSONSerialization.jsonObject(with: frame.dropFirst(8))) as? [String: Any] ?? [:]
    return (opcode, length, json)
  }

  @Test("frames carry a little-endian opcode and payload length")
  func frameHeader() {
    let frame = DiscordPresence.frame(opcode: .handshake, ["v": 1, "client_id": "123"])
    let (opcode, length, json) = decode(frame)
    #expect(Array(frame.prefix(4)) == [0, 0, 0, 0])
    #expect(opcode == 0)
    #expect(Int(length) == frame.count - 8)
    #expect(json["client_id"] as? String == "123")
    #expect(json["v"] as? Int == 1)
  }

  @Test("SET_ACTIVITY names the game and its start time")
  func setActivity() {
    let since = Date(timeIntervalSince1970: 1_700_000_000)
    let payload = DiscordPresence.setActivityPayload(activity: (details: "イース \"II\"", since: since), pid: 42, nonce: "n")
    let (opcode, _, json) = decode(DiscordPresence.frame(opcode: .frame, payload))
    #expect(opcode == 1)
    #expect(json["cmd"] as? String == "SET_ACTIVITY")
    #expect(json["nonce"] as? String == "n")
    let args = json["args"] as? [String: Any]
    #expect(args?["pid"] as? Int == 42)
    let activity = args?["activity"] as? [String: Any]
    #expect(activity?["details"] as? String == "イース \"II\"")
    #expect((activity?["timestamps"] as? [String: Any])?["start"] as? Int == 1_700_000_000)
    #expect((activity?["assets"] as? [String: Any])?["large_image"] as? String == "icon")
  }

  @Test("no game leaves the activity out, which clears it")
  func clearActivity() {
    let payload = DiscordPresence.setActivityPayload(activity: nil, pid: 42, nonce: "n")
    let args = payload["args"] as? [String: Any]
    #expect(args?["pid"] as? Int == 42)
    #expect(args?["activity"] == nil)
  }

  @Test("an activity without details still shows, with no details line")
  func activityWithoutDetails() {
    let payload = DiscordPresence.setActivityPayload(activity: (details: nil, since: Date()), pid: 42, nonce: "n")
    let activity = (payload["args"] as? [String: Any])?["activity"] as? [String: Any]
    #expect(activity != nil)
    #expect(activity?["details"] == nil)
  }
}
