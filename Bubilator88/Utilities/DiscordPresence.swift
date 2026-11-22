import Darwin
import Foundation
import Logging

/// Shows the game on screen as the user's Discord activity ("Playing
/// Bubilator88 — <game>").
///
/// Talks to the running Discord client over its local IPC socket, the same
/// channel Discord's own SDKs use for Rich Presence without sign-in, so the
/// app needs no SDK, no network access and no OAuth. Discord not running is
/// the normal case: every call that cannot connect gives up quietly, and the
/// next ``update(gameName:)`` tries again.
nonisolated final class DiscordPresence: @unchecked Sendable {
  /// The "Bubilator88" application in the Discord Developer Portal. Its name
  /// is what Discord shows after "Playing", and its Rich Presence art assets
  /// hold `icon`. Empty turns the whole feature off.
  static let applicationID = "1574065632851271782"

  private static let logger = Logger(label: "App.DiscordPresence")

  /// Every member below is touched only on this queue.
  private let queue = DispatchQueue(label: "com.bubio.Bubilator88.DiscordPresence")
  private var fd: Int32 = -1

  /// Shows "Playing Bubilator88" with `details` under it (none when nil),
  /// counting elapsed time from `since`, or clears the activity when
  /// `activity` is nil.
  func update(activity: (details: String?, since: Date)?) {
    guard !Self.applicationID.isEmpty else { return }
    queue.async { [self] in
      let payload = Self.setActivityPayload(activity: activity, pid: getpid(), nonce: UUID().uuidString)
      if fd < 0 {
        // Nothing to clear on a connection that does not exist yet.
        guard activity != nil, connect() else { return }
      }
      if !send(opcode: .frame, payload) {
        // A stale connection from a Discord that has since restarted:
        // reconnect once and retry.
        close()
        guard activity != nil, connect(), send(opcode: .frame, payload) else {
          close()
          return
        }
      }
      drainReplies()
    }
  }

  /// Clears the activity and disconnects.
  func stop() {
    queue.async { [self] in
      guard fd >= 0 else { return }
      _ = send(opcode: .frame, Self.setActivityPayload(activity: nil, pid: getpid(), nonce: UUID().uuidString))
      close()
    }
  }

  /// ``stop()`` that waits until it is done, for app termination.
  func stopAndWait() {
    stop()
    queue.sync {}
  }

  // MARK: - Wire format

  enum Opcode: UInt32 {
    case handshake = 0
    case frame = 1
    case close = 2
  }

  /// One IPC message: opcode and payload length as little-endian `UInt32`,
  /// then the JSON payload.
  static func frame(opcode: Opcode, _ payload: [String: Any]) -> Data {
    let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
    var data = Data(capacity: 8 + json.count)
    withUnsafeBytes(of: opcode.rawValue.littleEndian) { data.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt32(json.count).littleEndian) { data.append(contentsOf: $0) }
    data.append(json)
    return data
  }

  static func handshakePayload() -> [String: Any] {
    ["v": 1, "client_id": applicationID]
  }

  /// `SET_ACTIVITY`; without an activity the `activity` key is left out,
  /// which tells Discord to clear it.
  static func setActivityPayload(activity: (details: String?, since: Date)?, pid: Int32, nonce: String) -> [String: Any] {
    var args: [String: Any] = ["pid": Int(pid)]
    if let activity {
      var body: [String: Any] = [
        "timestamps": ["start": Int(activity.since.timeIntervalSince1970)],
        "assets": ["large_image": "icon", "large_text": "Bubilator88"],
      ]
      if let details = activity.details { body["details"] = details }
      args["activity"] = body
    }
    return ["cmd": "SET_ACTIVITY", "args": args, "nonce": nonce]
  }

  // MARK: - Socket

  /// Discord listens on `discord-ipc-0` … `discord-ipc-9` in the user's
  /// temporary directory, the first free index winning.
  private static func socketPaths() -> [String] {
    var dirs: [String] = []
    if let tmp = ProcessInfo.processInfo.environment["TMPDIR"], !tmp.isEmpty { dirs.append(tmp) }
    dirs.append(NSTemporaryDirectory())
    dirs.append("/tmp/")
    var seen = Set<String>()
    let unique = dirs.map { $0.hasSuffix("/") ? $0 : $0 + "/" }.filter { seen.insert($0).inserted }
    return unique.flatMap { dir in (0..<10).map { "\(dir)discord-ipc-\($0)" } }
  }

  private func connect() -> Bool {
    for path in Self.socketPaths() where FileManager.default.fileExists(atPath: path) {
      let sock = socket(AF_UNIX, SOCK_STREAM, 0)
      guard sock >= 0 else { continue }
      var on: Int32 = 1
      setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
      var tv = timeval(tv_sec: 2, tv_usec: 0)
      setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
      setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

      var addr = sockaddr_un()
      addr.sun_family = sa_family_t(AF_UNIX)
      let capacity = MemoryLayout.size(ofValue: addr.sun_path)
      guard path.utf8.count < capacity else {
        Darwin.close(sock)
        continue
      }
      withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
        buffer.copyBytes(from: path.utf8)
        buffer[path.utf8.count] = 0
      }
      let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      guard connected == 0 else {
        Darwin.close(sock)
        continue
      }
      fd = sock
      // Discord answers the handshake with READY, or closes the socket on a
      // bad application ID.
      if send(opcode: .handshake, Self.handshakePayload()), let reply = readFrame(), reply.opcode == Opcode.frame.rawValue {
        Self.logger.debug("Connected to \(path)")
        return true
      }
      Self.logger.debug("Handshake failed on \(path)")
      close()
    }
    return false
  }

  private func send(opcode: Opcode, _ payload: [String: Any]) -> Bool {
    guard fd >= 0 else { return false }
    let data = Self.frame(opcode: opcode, payload)
    return data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
        if n <= 0 {
          if n < 0, errno == EINTR { continue }
          return false
        }
        offset += n
      }
      return true
    }
  }

  /// Reads one reply. Nil on timeout, a closed socket or a malformed header.
  private func readFrame() -> (opcode: UInt32, payload: Data)? {
    guard let header = readExactly(8) else { return nil }
    let opcode = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self)) }
    let length = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) }
    guard length <= 1 << 20, let payload = readExactly(Int(length)) else { return nil }
    return (opcode, payload)
  }

  private func readExactly(_ count: Int) -> Data? {
    var data = Data(count: count)
    var offset = 0
    let ok = data.withUnsafeMutableBytes { buffer -> Bool in
      while offset < count {
        let n = Darwin.read(fd, buffer.baseAddress! + offset, count - offset)
        if n <= 0 {
          if n < 0, errno == EINTR { continue }
          return false
        }
        offset += n
      }
      return true
    }
    return ok ? data : nil
  }

  /// Reads the reply to a command so the socket's buffer never fills. An
  /// error reply is only logged: the activity is a courtesy, not a feature
  /// worth interrupting play for.
  private func drainReplies() {
    guard let reply = readFrame() else {
      close()
      return
    }
    if reply.opcode == Opcode.close.rawValue {
      Self.logger.debug("Discord closed the connection: \(String(bytes: reply.payload, encoding: .utf8) ?? "")")
      close()
    } else if let json = try? JSONSerialization.jsonObject(with: reply.payload) as? [String: Any],
              json["evt"] as? String == "ERROR" {
      Self.logger.debug("SET_ACTIVITY failed: \(String(bytes: reply.payload, encoding: .utf8) ?? "")")
    }
  }

  private func close() {
    guard fd >= 0 else { return }
    Darwin.close(fd)
    fd = -1
  }
}
