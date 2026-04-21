import Foundation
import Compression

// MARK: - Archive Types

enum ArchiveType {
    case zip
    case lzh
    case cab
    case rar
    case none
}

struct ArchiveEntry {
    let filename: String
    let data: Data
}

// MARK: - ArchiveExtractor

enum ArchiveExtractor {

    /// Disk image extensions to extract from archives.
    private static let diskExtensions: Set<String> = ["d88", "d77", "2d", "2hd"]
    private static let tapeExtensions: Set<String> = ["cmt", "t88"]

    /// Detect archive type from magic bytes.
    static func detectType(_ data: Data) -> ArchiveType {
        guard data.count >= 8 else { return .none }
        // ZIP: PK\x03\x04
        if data[0] == 0x50, data[1] == 0x4B, data[2] == 0x03, data[3] == 0x04 {
            return .zip
        }
        // CAB: MSCF
        if data[0] == 0x4D, data[1] == 0x53, data[2] == 0x43, data[3] == 0x46 {
            return .cab
        }
        // RAR: "Rar!" signature
        if data[0] == 0x52, data[1] == 0x61, data[2] == 0x72, data[3] == 0x21 {
            return .rar
        }
        // LZH: check for -lh?- or -lz?- signature pattern
        if data.count >= 7, data[2] == 0x2D,
           (data[3] == 0x6C && data[4] == 0x68) || (data[3] == 0x6C && data[4] == 0x7A),
           data[6] == 0x2D {
            return .lzh
        }
        return .none
    }

    /// Archive extensions for nested archive detection.
    private static let archiveExtensions: Set<String> = ["zip", "lzh", "cab", "rar"]

    /// Extract disk image files from a supported archive.
    /// Returns nil if the data is not a recognized archive format.
    /// Handles nested archives (e.g. RAR containing CAB containing D88).
    static func extractDiskImages(_ data: Data) -> [ArchiveEntry]? {
        return extractMatchingEntries(data, targetExtensions: diskExtensions, depth: 0)
    }

    /// Extract cassette-tape image files (`.cmt` / `.t88`) from a supported
    /// archive. Same nesting rules as `extractDiskImages`.
    static func extractTapeImages(_ data: Data) -> [ArchiveEntry]? {
        return extractMatchingEntries(data, targetExtensions: tapeExtensions, depth: 0)
    }

    private static func extractMatchingEntries(_ data: Data,
                                               targetExtensions: Set<String>,
                                               depth: Int) -> [ArchiveEntry]? {
        guard depth < 3 else { return nil }  // Prevent infinite recursion
        let type = detectType(data)
        var entries: [ArchiveEntry]
        switch type {
        case .zip:
            entries = extractZIP(data)
            if entries.isEmpty {
                // Fallback to bsdtar for ZIPs with data descriptors or unsupported methods
                entries = extractWithBsdtar(data)
            }
        case .rar: entries = extractRAR(data)
        case .lzh, .cab: entries = extractWithBsdtar(data)
        case .none: return nil
        }

        var matches: [ArchiveEntry] = []
        for entry in entries {
            let ext = (entry.filename as NSString).pathExtension.lowercased()
            if targetExtensions.contains(ext) {
                matches.append(entry)
            } else if archiveExtensions.contains(ext) {
                // Nested archive — recurse
                if let nested = extractMatchingEntries(entry.data,
                                                       targetExtensions: targetExtensions,
                                                       depth: depth + 1) {
                    matches.append(contentsOf: nested)
                }
            }
        }
        return matches
    }

    // MARK: - ZIP Extraction (native, using Compression framework)

    static func extractZIP(_ data: Data) -> [ArchiveEntry] {
        var results: [ArchiveEntry] = []
        let bytes = [UInt8](data)
        var offset = 0

        while offset + 30 <= bytes.count {
            // Local file header signature: PK\x03\x04
            guard bytes[offset] == 0x50, bytes[offset+1] == 0x4B,
                  bytes[offset+2] == 0x03, bytes[offset+3] == 0x04 else { break }

            let method = UInt16(bytes[offset+8]) | UInt16(bytes[offset+9]) << 8
            let compressedSize = Int(readU32(bytes, offset+18))
            let uncompressedSize = Int(readU32(bytes, offset+22))
            let nameLen = Int(UInt16(bytes[offset+26]) | UInt16(bytes[offset+27]) << 8)
            let extraLen = Int(UInt16(bytes[offset+28]) | UInt16(bytes[offset+29]) << 8)

            let nameStart = offset + 30
            guard nameStart + nameLen <= bytes.count else { break }
            let nameBytes = Array(bytes[nameStart..<nameStart+nameLen])
            let filename = decodeFilename(nameBytes)

            let dataStart = nameStart + nameLen + extraLen
            guard dataStart + compressedSize <= bytes.count else { break }

            if !filename.hasSuffix("/") {
                let compressedData = Array(bytes[dataStart..<dataStart+compressedSize])
                if let decompressed = decompressZIPEntry(compressedData, method: method,
                                                         uncompressedSize: uncompressedSize) {
                    results.append(ArchiveEntry(filename: basename(filename), data: Data(decompressed)))
                }
            }

            offset = dataStart + compressedSize
        }
        return results
    }

    private static func decompressZIPEntry(_ compressed: [UInt8], method: UInt16,
                                            uncompressedSize: Int) -> [UInt8]? {
        switch method {
        case 0: return compressed
        case 8: return inflateRaw(compressed, expectedSize: uncompressedSize)
        default: return nil
        }
    }

    /// Inflate raw DEFLATE data using Apple's Compression framework.
    private static func inflateRaw(_ compressed: [UInt8], expectedSize: Int) -> [UInt8]? {
        let bufferSize = max(expectedSize, compressed.count * 4)
        var destination = [UInt8](repeating: 0, count: bufferSize)
        let decodedSize = compressed.withUnsafeBufferPointer { src in
            destination.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(
                    dst.baseAddress!, bufferSize,
                    src.baseAddress!, compressed.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard decodedSize > 0 else { return nil }
        return Array(destination.prefix(decodedSize))
    }

    // MARK: - External Tool Extraction

    /// Extract files using macOS built-in bsdtar (libarchive).
    /// Supports LZH (all methods), CAB (MSZIP, LZX), RAR (stored only).
    private static func extractWithBsdtar(_ data: Data) -> [ArchiveEntry] {
        return extractToTempDir(data) { archivePath, extractDir in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
            process.arguments = ["xf", archivePath, "-C", extractDir,
                                "--options", "hdrcharset=CP932"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
        }
    }

    /// Extract RAR files using unar/unrar/7z (Homebrew), falling back to bsdtar.
    /// bsdtar/libarchive cannot decompress RAR4 methods 0x31-0x35.
    private static func extractRAR(_ data: Data) -> [ArchiveEntry] {
        // Try unar first (The Unarchiver CLI — handles all RAR versions reliably)
        if let unarPath = findExecutable("unar") {
            let results = extractToTempDir(data, createExtractDir: false) { archivePath, extractDir in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: unarPath)
                process.arguments = ["-no-directory", "-o", extractDir, archivePath]
                process.standardOutput = Pipe()
                process.standardError = Pipe()
                try process.run()
                process.waitUntilExit()
            }
            if !results.isEmpty { return results }
        }

        // Try unrar (WinRAR CLI)
        if let unrarPath = findExecutable("unrar") {
            let results = extractToTempDir(data, createExtractDir: false) { archivePath, extractDir in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: unrarPath)
                process.arguments = ["x", "-o+", "-y", archivePath, extractDir + "/"]
                process.standardOutput = Pipe()
                process.standardError = Pipe()
                try process.run()
                process.waitUntilExit()
            }
            if !results.isEmpty { return results }
        }

        // Try 7z (p7zip)
        if let sevenZPath = findExecutable("7zz") ?? findExecutable("7z") {
            let results = extractToTempDir(data) { archivePath, extractDir in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: sevenZPath)
                process.arguments = ["x", "-y", "-o" + extractDir, archivePath]
                process.standardOutput = Pipe()
                process.standardError = Pipe()
                try process.run()
                process.waitUntilExit()
            }
            if !results.isEmpty { return results }
        }

        // Fall back to bsdtar (works for stored RARs only)
        return extractWithBsdtar(data)
    }

    /// Common extraction logic: write archive to temp, run extractor, collect results.
    private static func extractToTempDir(_ data: Data,
                                          createExtractDir: Bool = true,
                                          extractor: (String, String) throws -> Void) -> [ArchiveEntry] {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bubilator88_\(UUID().uuidString)")
        let archivePath = tempDir.appendingPathComponent("archive").path
        let extractDir = tempDir.appendingPathComponent("out")

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            if createExtractDir {
                try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
            }
            try data.write(to: URL(fileURLWithPath: archivePath))
        } catch {
            return []
        }
        defer { try? FileManager.default.removeItem(at: tempDir) }

        do {
            try extractor(archivePath, extractDir.path)
        } catch {
            return []
        }

        // Scan extracted files, filtering out corrupt (all-zero) files
        let relevantExtensions = diskExtensions.union(tapeExtensions).union(archiveExtensions)
        var results: [ArchiveEntry] = []
        if let enumerator = FileManager.default.enumerator(at: extractDir,
                                                            includingPropertiesForKeys: [.isRegularFileKey],
                                                            options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                guard relevantExtensions.contains(ext) else { continue }
                guard let fileData = try? Data(contentsOf: fileURL),
                      !fileData.isEmpty,
                      fileData.contains(where: { $0 != 0 }) else { continue }
                results.append(ArchiveEntry(filename: fileURL.lastPathComponent, data: fileData))
            }
        }
        return results
    }

    /// Search for an executable in common paths.
    private static func findExecutable(_ name: String) -> String? {
        let searchPaths = [
            "/usr/local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        return searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Helpers

    private static func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset+1]) << 8 |
        UInt32(bytes[offset+2]) << 16 | UInt32(bytes[offset+3]) << 24
    }

    /// Decode a filename from bytes, trying UTF-8 first then Shift-JIS.
    private static func decodeFilename(_ bytes: [UInt8]) -> String {
        if let utf8 = String(bytes: bytes, encoding: .utf8),
           utf8.utf8.count == bytes.count {
            // Valid UTF-8 and no byte loss — use it
            return utf8
        }
        if let sjis = String(bytes: bytes, encoding: .shiftJIS), !sjis.isEmpty {
            return sjis
        }
        return String(bytes: bytes, encoding: .ascii) ?? "unknown"
    }

    /// Extract basename from a path (remove directory components).
    private static func basename(_ path: String) -> String {
        let components = path.split(omittingEmptySubsequences: true) { $0 == "/" || $0 == "\\" }
        return String(components.last ?? Substring(path))
    }
}
