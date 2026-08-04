import Foundation
import QuickLookUI
import UniformTypeIdentifiers

/// Builds the spacebar preview for a `.b88s` save state: the screen the
/// emulator was showing, plus what the file says about itself.
///
/// Everything shown comes out of the file — `THMB` for the image, `AMTA` for
/// the app's metadata, `META` for the emulator's, and the header timestamp.
/// The extension is sandboxed and is handed one URL, so it cannot read the
/// `.meta.json` / `.thumb.png` sidecars next to a state saved by an older
/// build; those files preview with only what their header carries.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
  func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
    let url = request.fileURL
    let thumbnail = SaveStateFileAccess.readSection(SaveStateFileAccess.thumbnailTag, from: url)
    let appMeta = json(SaveStateFileAccess.readSection(SaveStateFileAccess.appMetaTag, from: url))
    let coreMeta = json(SaveStateFileAccess.readSection(SaveStateFileAccess.coreMetaTag, from: url))
    let timestamp = SaveStateFileAccess.readTimestamp(from: url)

    let rows = detailRows(appMeta: appMeta, coreMeta: coreMeta, timestamp: timestamp)
    let title = diskNames(appMeta: appMeta, coreMeta: coreMeta).first

    // 640×400 screen plus room for the detail rows underneath.
    let reply = QLPreviewReply(dataOfContentType: .html,
                               contentSize: CGSize(width: 660, height: 520)) { reply in
      reply.stringEncoding = .utf8
      if let thumbnail {
        reply.attachments["screen"] = QLPreviewReplyAttachment(data: thumbnail,
                                                               contentType: .png)
      }
      return Data(Self.html(hasScreen: thumbnail != nil, rows: rows).utf8)
    }
    if let title { reply.title = title }
    return reply
  }

  // MARK: - Content

  private func json(_ data: Data?) -> [String: Any] {
    guard let data,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return [:]
    }
    return object
  }

  /// Prefer the app's metadata (it keeps the file name the user picked) and
  /// fall back to the emulator's disk labels.
  private func diskNames(appMeta: [String: Any], coreMeta: [String: Any]) -> [String] {
    let candidates: [(String, String)] = [("drive0FileName", "disk0"), ("drive1FileName", "disk1")]
    var names: [String] = []
    for (appKey, coreKey) in candidates {
      let appName = appMeta[appKey] as? String
        ?? appMeta[appKey.replacingOccurrences(of: "FileName", with: "Name")] as? String
      let name = appName ?? appMeta[coreKey] as? String ?? coreMeta[coreKey] as? String
      if let name, !name.isEmpty, !names.contains(name) { names.append(name) }
    }
    return names
  }

  private func detailRows(appMeta: [String: Any],
                          coreMeta: [String: Any],
                          timestamp: Date?) -> [(String, String)] {
    var rows: [(String, String)] = []

    let disks = diskNames(appMeta: appMeta, coreMeta: coreMeta)
    if !disks.isEmpty {
      rows.append((String(localized: "Disks", comment: "Quick Look preview: disk names row"),
                   disks.joined(separator: ", ")))
    }
    if let mode = appMeta["bootMode"] as? String, !mode.isEmpty {
      rows.append((String(localized: "Boot Mode", comment: "Quick Look preview: boot mode row"),
                   mode))
    }
    if let clock8MHz = (appMeta["clock8MHz"] ?? coreMeta["clock8MHz"]) as? Bool {
      rows.append((String(localized: "CPU Clock", comment: "Quick Look preview: CPU clock row"),
                   clock8MHz ? "8 MHz" : "4 MHz"))
    }
    if let timestamp {
      rows.append((String(localized: "Saved", comment: "Quick Look preview: save date row"),
                   DateFormatter.localizedString(from: timestamp,
                                                 dateStyle: .medium, timeStyle: .short)))
    }
    return rows
  }

  // MARK: - Markup

  /// Colours follow the system appearance so the panel matches Quick Look's
  /// own chrome in both light and dark mode.
  private static func html(hasScreen: Bool, rows: [(String, String)]) -> String {
    let screen = hasScreen
      ? "<img class=\"screen\" src=\"cid:screen\" alt=\"\">"
      : "<div class=\"screen missing\">\(escape(String(localized: "No screenshot in this save state", comment: "Quick Look preview: shown for states written before thumbnails were stored inside the file")))</div>"

    let details = rows.map { label, value in
      "<div class=\"label\">\(escape(label))</div><div class=\"value\">\(escape(value))</div>"
    }.joined()

    return """
    <!DOCTYPE html>
    <html>
    <head><meta charset="utf-8">
    <style>
      :root { color-scheme: light dark; }
      body {
        margin: 0; padding: 16px;
        font: 13px -apple-system, system-ui, sans-serif;
        background: Canvas; color: CanvasText;
      }
      .screen {
        display: block; width: 640px; height: 400px; margin: 0 auto;
        image-rendering: pixelated; border-radius: 4px;
        background: #000;
      }
      /* Overrides .screen's black fill: placeholder text has to stay legible,
         and an empty black rectangle reads as a broken image. */
      .missing {
        display: flex; align-items: center; justify-content: center;
        background: color-mix(in srgb, CanvasText 10%, transparent);
        color: color-mix(in srgb, CanvasText 60%, transparent);
      }
      .details {
        display: grid; grid-template-columns: max-content 1fr;
        gap: 4px 12px; width: 640px; margin: 14px auto 0;
      }
      .label { color: color-mix(in srgb, CanvasText 55%, transparent); text-align: right; }
      .value { overflow-wrap: anywhere; }
    </style>
    </head>
    <body>
      \(screen)
      <div class="details">\(details)</div>
    </body>
    </html>
    """
  }

  private static func escape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }
}
