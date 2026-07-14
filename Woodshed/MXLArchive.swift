//
//  MXLArchive.swift
//  Woodshed
//
//  Minimal, dependency-free reader for `.mxl` (compressed MusicXML) files.
//
//  An .mxl is a ZIP archive: META-INF/container.xml names the root score file,
//  which is deflate- or store-compressed. Foundation has no public unzip API, so
//  this parses just enough of the ZIP format (End-of-Central-Directory → central
//  directory entries → local headers) and inflates entries with the Compression
//  framework (COMPRESSION_ZLIB == raw DEFLATE, which is what ZIP uses). Bounds-
//  checked throughout — a corrupt archive throws, never crashes (same rule as
//  MIDIParser). Unit-tested against a hand-built archive in WoodshedTests.
//

import Foundation
import Compression

enum MXLError: Error, CustomStringConvertible {
    case notAZip, malformed, unsupportedCompression, noScoreFile, tooLarge
    var description: String {
        switch self {
        case .notAZip: return "Not a valid .mxl archive."
        case .malformed: return "The .mxl archive is damaged."
        case .unsupportedCompression: return "The .mxl uses an unsupported compression method."
        case .noScoreFile: return "No MusicXML score found inside the .mxl."
        case .tooLarge: return "The .mxl declares an implausibly large score (possible corrupt or malicious archive)."
        }
    }
}

enum MXLArchive {
    /// Cap on a single entry's declared uncompressed size. A ZIP's header can claim up
    /// to ~4 GB while its compressed payload is a few bytes (a "zip bomb"); without a
    /// cap that number drives an allocation that can OOM-kill the app. A real MusicXML
    /// score is well under this.
    static let maxUncompressedSize = 64 * 1024 * 1024   // 64 MB

    /// Extract the MusicXML score from `.mxl` data: honours META-INF/container.xml's
    /// rootfile when present, else falls back to the first top-level .xml/.musicxml.
    static func extractScore(from data: Data) throws -> Data {
        let entries = try list(data)

        // Preferred: the path named by container.xml (<rootfile full-path="...">).
        if let container = entries.first(where: { $0.name == "META-INF/container.xml" }),
           let xml = String(data: try extract(container, from: data), encoding: .utf8),
           let path = rootfilePath(in: xml),
           let entry = entries.first(where: { $0.name == path }) {
            return try extract(entry, from: data)
        }
        // Fallback: first score-looking file outside META-INF.
        if let entry = entries.first(where: {
            !$0.name.hasPrefix("META-INF/") && !$0.name.hasSuffix("/")
                && ($0.name.lowercased().hasSuffix(".xml") || $0.name.lowercased().hasSuffix(".musicxml"))
        }) {
            return try extract(entry, from: data)
        }
        throw MXLError.noScoreFile
    }

    /// The `full-path` attribute of the first `<rootfile>` in container.xml.
    static func rootfilePath(in containerXML: String) -> String? {
        guard let range = containerXML.range(of: #"full-path="([^"]+)""#, options: .regularExpression)
        else { return nil }
        let match = containerXML[range]
        return match.dropFirst(#"full-path=""#.count).dropLast().isEmpty
            ? nil : String(match.dropFirst(#"full-path=""#.count).dropLast())
    }

    // MARK: - ZIP plumbing

    struct Entry {
        let name: String
        let method: UInt16            // 0 = stored, 8 = deflate
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    /// Parse the central directory. Throws on anything structurally off.
    static func list(_ data: Data) throws -> [Entry] {
        let bytes = [UInt8](data)
        // End of Central Directory record: signature 0x06054b50, ≥22 bytes, at the
        // very end (allow up to 64 KB of trailing comment per the spec).
        guard bytes.count >= 22 else { throw MXLError.notAZip }
        var eocd = -1
        let scanStart = max(0, bytes.count - 22 - 65_536)
        var i = bytes.count - 22
        while i >= scanStart {
            if bytes[i] == 0x50, bytes[i+1] == 0x4b, bytes[i+2] == 0x05, bytes[i+3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw MXLError.notAZip }

        func u16(_ o: Int) throws -> Int {
            guard o + 2 <= bytes.count else { throw MXLError.malformed }
            return Int(bytes[o]) | (Int(bytes[o+1]) << 8)
        }
        func u32(_ o: Int) throws -> Int {
            guard o + 4 <= bytes.count else { throw MXLError.malformed }
            return Int(bytes[o]) | (Int(bytes[o+1]) << 8) | (Int(bytes[o+2]) << 16) | (Int(bytes[o+3]) << 24)
        }

        let count = try u16(eocd + 10)
        var offset = try u32(eocd + 16)          // start of central directory
        var entries: [Entry] = []
        for _ in 0..<count {
            guard try u32(offset) == 0x02014b50 else { throw MXLError.malformed }
            let method = UInt16(try u16(offset + 10))
            let csize = try u32(offset + 20)
            let usize = try u32(offset + 24)
            let nameLen = try u16(offset + 28)
            let extraLen = try u16(offset + 30)
            let commentLen = try u16(offset + 32)
            let localOffset = try u32(offset + 42)
            guard offset + 46 + nameLen <= bytes.count else { throw MXLError.malformed }
            let name = String(bytes: bytes[(offset + 46)..<(offset + 46 + nameLen)], encoding: .utf8) ?? ""
            entries.append(Entry(name: name, method: method, compressedSize: csize,
                                 uncompressedSize: usize, localHeaderOffset: localOffset))
            offset += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }

    /// Extract one entry's bytes (stored or deflate).
    static func extract(_ entry: Entry, from data: Data) throws -> Data {
        let bytes = [UInt8](data)
        let o = entry.localHeaderOffset
        func u16(_ off: Int) throws -> Int {
            guard off + 2 <= bytes.count else { throw MXLError.malformed }
            return Int(bytes[off]) | (Int(bytes[off+1]) << 8)
        }
        guard o + 30 <= bytes.count,
              bytes[o] == 0x50, bytes[o+1] == 0x4b, bytes[o+2] == 0x03, bytes[o+3] == 0x04
        else { throw MXLError.malformed }
        // The local header's own name/extra lengths can differ from the central ones.
        let nameLen = try u16(o + 26)
        let extraLen = try u16(o + 28)
        let start = o + 30 + nameLen + extraLen
        guard start + entry.compressedSize <= bytes.count else { throw MXLError.malformed }
        // Reject an implausibly large declared size BEFORE allocating for it (zip bomb).
        guard entry.uncompressedSize <= maxUncompressedSize else { throw MXLError.tooLarge }
        let payload = Data(bytes[start..<(start + entry.compressedSize)])

        switch entry.method {
        case 0:   // stored
            return payload
        case 8:   // deflate (raw, per ZIP — Apple's COMPRESSION_ZLIB)
            guard entry.uncompressedSize > 0 else { return Data() }
            var dst = Data(count: entry.uncompressedSize)
            let written = dst.withUnsafeMutableBytes { dstPtr in
                payload.withUnsafeBytes { srcPtr in
                    compression_decode_buffer(
                        dstPtr.bindMemory(to: UInt8.self).baseAddress!, entry.uncompressedSize,
                        srcPtr.bindMemory(to: UInt8.self).baseAddress!, payload.count,
                        nil, COMPRESSION_ZLIB)
                }
            }
            guard written == entry.uncompressedSize else { throw MXLError.malformed }
            return dst
        default:
            throw MXLError.unsupportedCompression
        }
    }
}
