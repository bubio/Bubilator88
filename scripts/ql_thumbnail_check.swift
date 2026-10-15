import AppKit
import QuickLookThumbnailing
// Usage: swift scripts/ql_thumbnail_check.swift <file>...
// Asks Quick Look the way Finder does (qlmanage -t hangs on app thumbnail
// extensions on macOS 27) and prints which representation Quick Look produced:
// "thumbnail" means a provider drew it, "icon" means Finder's generic icon.
let sem = DispatchSemaphore(value: 0)
for path in CommandLine.arguments.dropFirst() {
  let start = Date()
  let req = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path),
                                         size: CGSize(width: 256, height: 256), scale: 1,
                                         representationTypes: .all)
  QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, err in
    let kind: String
    switch rep?.type { case .thumbnail?: kind = "thumbnail"; case .lowQualityThumbnail?: kind = "lowQuality"; case .icon?: kind = "icon"; default: kind = "none" }
    print(path, "->", kind, String(format: "%.1fs", Date().timeIntervalSince(start)), err.map { "\($0)" } ?? "")
    sem.signal()
  }
  if sem.wait(timeout: .now() + 30) == .timedOut { print(path, "-> TIMEOUT") }
}
