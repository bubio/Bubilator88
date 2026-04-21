import Testing
import Foundation
import Compression
@testable import Bubilator88

struct ArchiveExtractorTests {

    // MARK: - detectType

    @Test("detects ZIP from PK magic bytes")
    func detectTypeZIP() {
        let data = Data([0x50, 0x4B, 0x03, 0x04, 0, 0, 0, 0])
        #expect(ArchiveExtractor.detectType(data) == .zip)
    }

    @Test("detects CAB from MSCF magic bytes")
    func detectTypeCAB() {
        let data = Data([0x4D, 0x53, 0x43, 0x46, 0, 0, 0, 0])
        #expect(ArchiveExtractor.detectType(data) == .cab)
    }

    @Test("detects RAR from Rar! magic bytes")
    func detectTypeRAR() {
        let data = Data([0x52, 0x61, 0x72, 0x21, 0, 0, 0, 0])
        #expect(ArchiveExtractor.detectType(data) == .rar)
    }

    @Test("detects LZH from -lh5- pattern")
    func detectTypeLZH() {
        // LZH header: bytes[2]='-', bytes[3]='l', bytes[4]='h', bytes[5]=method, bytes[6]='-'
        let data = Data([0x00, 0x00, 0x2D, 0x6C, 0x68, 0x35, 0x2D, 0x00])
        #expect(ArchiveExtractor.detectType(data) == .lzh)
    }

    @Test("detects LZH from -lz- variant")
    func detectTypeLZ() {
        let data = Data([0x00, 0x00, 0x2D, 0x6C, 0x7A, 0x35, 0x2D, 0x00])
        #expect(ArchiveExtractor.detectType(data) == .lzh)
    }

    @Test("returns .none for data shorter than 8 bytes")
    func detectTypeNoneShortData() {
        #expect(ArchiveExtractor.detectType(Data([0x50])) == .none)
        #expect(ArchiveExtractor.detectType(Data([0x50, 0x4B, 0x03])) == .none)
    }

    @Test("returns .none for empty data")
    func detectTypeNoneEmpty() {
        #expect(ArchiveExtractor.detectType(Data()) == .none)
    }

    @Test("returns .none for unknown magic bytes")
    func detectTypeNoneUnknown() {
        let data = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        #expect(ArchiveExtractor.detectType(data) == .none)
    }

    // MARK: - extractDiskImages

    @Test("returns nil for non-archive data")
    func extractDiskImagesReturnsNilForNonArchive() {
        let data = Data(repeating: 0x42, count: 100)
        #expect(ArchiveExtractor.extractDiskImages(data) == nil)
    }

    // MARK: - extractZIP

    @Test("extracts stored ZIP entry")
    func extractZIPStoredEntry() {
        let payload: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let zip = buildZIP(entries: [("test.d88", payload, 0)])
        let results = ArchiveExtractor.extractZIP(zip)

        #expect(results.count == 1)
        #expect(results[0].filename == "test.d88")
        #expect(Array(results[0].data) == payload)
    }

    @Test("extracts DEFLATE compressed ZIP entry")
    func extractZIPDeflateEntry() {
        // Create compressible data (repeating pattern)
        let original = [UInt8](repeating: 0x41, count: 256)
        guard let compressed = deflateCompress(original) else {
            Issue.record("Failed to compress test data")
            return
        }
        let zip = buildZIP(entries: [("game.d88", original, 8, compressed)])
        let results = ArchiveExtractor.extractZIP(zip)

        #expect(results.count == 1)
        #expect(results[0].filename == "game.d88")
        #expect(Array(results[0].data) == original)
    }

    @Test("extracts multiple ZIP entries")
    func extractZIPMultipleEntries() {
        let a: [UInt8] = [1, 2, 3]
        let b: [UInt8] = [4, 5, 6]
        let zip = buildZIP(entries: [("disk1.d88", a, 0), ("disk2.d88", b, 0)])
        let results = ArchiveExtractor.extractZIP(zip)

        #expect(results.count == 2)
        #expect(results[0].filename == "disk1.d88")
        #expect(results[1].filename == "disk2.d88")
    }

    @Test("skips directory entries in ZIP")
    func extractZIPSkipsDirectoryEntries() {
        let zip = buildZIP(entries: [("subdir/", [], 0), ("file.d88", [0xFF], 0)])
        let results = ArchiveExtractor.extractZIP(zip)

        #expect(results.count == 1)
        #expect(results[0].filename == "file.d88")
    }

    @Test("strips path from ZIP filenames")
    func extractZIPBasenameStripsPath() {
        let zip = buildZIP(entries: [("path/to/game.d88", [0x42], 0)])
        let results = ArchiveExtractor.extractZIP(zip)

        #expect(results.count == 1)
        #expect(results[0].filename == "game.d88")
    }

    @Test("decodes UTF-8 ZIP filename")
    func extractZIPUTF8Filename() {
        let zip = buildZIP(entries: [("hello.d88", [0x01], 0)])
        let results = ArchiveExtractor.extractZIP(zip)

        #expect(results.count == 1)
        #expect(results[0].filename == "hello.d88")
    }

    @Test("decodes Shift-JIS ZIP filename")
    func extractZIPShiftJISFilename() {
        // "テスト.d88" in Shift-JIS
        let nameBytes: [UInt8] = [0x83, 0x65, 0x83, 0x58, 0x83, 0x67, 0x2E, 0x64, 0x38, 0x38]
        let zip = buildZIPRaw(nameBytes: nameBytes, payload: [0x01], method: 0)
        let results = ArchiveExtractor.extractZIP(zip)

        #expect(results.count == 1)
        #expect(results[0].filename.hasSuffix(".d88"))
    }

    @Test("returns empty array for empty data")
    func extractZIPEmptyData() {
        #expect(ArchiveExtractor.extractZIP(Data()).isEmpty)
    }

    @Test("returns empty array for truncated header")
    func extractZIPTruncatedHeader() {
        // PK signature but less than 30 bytes total
        let data = Data([0x50, 0x4B, 0x03, 0x04] + Array(repeating: UInt8(0), count: 10))
        #expect(ArchiveExtractor.extractZIP(data).isEmpty)
    }

    @Test("skips entries with unsupported compression method")
    func extractZIPUnsupportedMethod() {
        let zip = buildZIP(entries: [("test.d88", [0x01, 0x02], 99)])
        let results = ArchiveExtractor.extractZIP(zip)

        #expect(results.isEmpty)
    }

    // MARK: - extractDiskImages with ZIP

    @Test("extractDiskImages returns empty for ZIP with no disk images")
    func extractDiskImagesEmptyForNonDiskZIP() {
        let zip = buildZIP(entries: [("readme.txt", [0x48, 0x69], 0)])
        let results = ArchiveExtractor.extractDiskImages(zip)

        #expect(results != nil)
        #expect(results!.isEmpty)
    }

    @Test("extractDiskImages filters disk extensions from ZIP")
    func extractDiskImagesFiltersDiskExtensions() {
        let zip = buildZIP(entries: [
            ("game.d88", [0x01], 0),
            ("readme.txt", [0x02], 0),
            ("other.d77", [0x03], 0),
        ])
        let results = ArchiveExtractor.extractDiskImages(zip)

        #expect(results != nil)
        #expect(results!.count == 2)
        let names = results!.map(\.filename)
        #expect(names.contains("game.d88"))
        #expect(names.contains("other.d77"))
    }

    // MARK: - ZIP Builder Helpers

    /// Build a ZIP file from multiple entries.
    /// For method=0 (stored), compressed data = payload.
    /// For method=8 (deflate), pass pre-compressed data via the 4th tuple element.
    private func buildZIP(entries: [(String, [UInt8], UInt16, [UInt8]?)]) -> Data {
        var data = Data()
        for (name, payload, method, compressed) in entries {
            let nameBytes = Array(name.utf8)
            let compressedData = compressed ?? payload
            data.append(contentsOf: buildLocalFileHeader(
                nameBytes: nameBytes,
                payload: compressedData,
                uncompressedSize: payload.count,
                method: method
            ))
        }
        return data
    }

    /// Convenience overload without pre-compressed data.
    private func buildZIP(entries: [(String, [UInt8], UInt16)]) -> Data {
        buildZIP(entries: entries.map { ($0.0, $0.1, $0.2, nil) })
    }

    /// Build a single-entry ZIP with raw name bytes (for encoding tests).
    private func buildZIPRaw(nameBytes: [UInt8], payload: [UInt8], method: UInt16) -> Data {
        Data(buildLocalFileHeader(
            nameBytes: nameBytes,
            payload: payload,
            uncompressedSize: payload.count,
            method: method
        ))
    }

    /// Construct a ZIP local file header + data.
    private func buildLocalFileHeader(
        nameBytes: [UInt8],
        payload: [UInt8],
        uncompressedSize: Int,
        method: UInt16
    ) -> [UInt8] {
        var header = [UInt8]()
        // Signature: PK\x03\x04
        header += [0x50, 0x4B, 0x03, 0x04]
        // Version needed (2 bytes)
        header += [0x14, 0x00]
        // General purpose bit flag (2 bytes)
        header += [0x00, 0x00]
        // Compression method (2 bytes)
        header += [UInt8(method & 0xFF), UInt8(method >> 8)]
        // Last mod time (2 bytes) + date (2 bytes)
        header += [0x00, 0x00, 0x00, 0x00]
        // CRC-32 (4 bytes) - not validated by our extractor
        header += [0x00, 0x00, 0x00, 0x00]
        // Compressed size (4 bytes LE)
        header += uint32LE(UInt32(payload.count))
        // Uncompressed size (4 bytes LE)
        header += uint32LE(UInt32(uncompressedSize))
        // Filename length (2 bytes LE)
        header += [UInt8(nameBytes.count & 0xFF), UInt8(nameBytes.count >> 8)]
        // Extra field length (2 bytes)
        header += [0x00, 0x00]
        // Filename
        header += nameBytes
        // File data
        header += payload
        return header
    }

    private func uint32LE(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
         UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    /// Compress data using raw DEFLATE (COMPRESSION_ZLIB).
    private func deflateCompress(_ input: [UInt8]) -> [UInt8]? {
        let bufferSize = input.count + 256
        var destination = [UInt8](repeating: 0, count: bufferSize)
        let compressedSize = input.withUnsafeBufferPointer { src in
            destination.withUnsafeMutableBufferPointer { dst in
                compression_encode_buffer(
                    dst.baseAddress!, bufferSize,
                    src.baseAddress!, input.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard compressedSize > 0 else { return nil }
        return Array(destination.prefix(compressedSize))
    }
}
