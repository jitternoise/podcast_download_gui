import Foundation

/// Identifies audio/video container formats from their first bytes, so a
/// file is stored under the extension that matches what's actually in it —
/// not what the URL or the feed claimed.
enum MediaSniffer {
    /// The file extension the data's real format calls for, or nil if it
    /// isn't a recognised media format.
    static func fileExtension(for head: Data) -> String? {
        guard head.count >= 12 else { return nil }
        let b = [UInt8](head.prefix(64))

        // ID3v2 tag → MP3 (the tag precedes the first MPEG frame).
        if b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 { return "mp3" }
        // ISO base media (MP4 family): "ftyp" at offset 4; the brand says which.
        if b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {
            let brand = String(decoding: b[8..<12], as: UTF8.self)
            switch brand {
            case "M4B ": return "m4b"
            case "M4A ": return "m4a"
            case "M4V ", "mp71", "avc1": return "mp4"
            default: return "m4a"      // isom/mp42/… are used for audio-only files far more often in podcasting
            }
        }
        // Ogg container: Opus if the first page carries an OpusHead.
        if b[0] == 0x4F, b[1] == 0x67, b[2] == 0x67, b[3] == 0x53 {
            if head.count >= 36, String(decoding: b[28..<36], as: UTF8.self) == "OpusHead" { return "opus" }
            return "ogg"
        }
        if b[0] == 0x66, b[1] == 0x4C, b[2] == 0x61, b[3] == 0x43 { return "flac" }                    // fLaC
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,                                    // RIFF….WAVE
           b[8] == 0x57, b[9] == 0x41, b[10] == 0x56, b[11] == 0x45 { return "wav" }
        // AAC in ADTS framing: 12 sync bits, layer bits 00 (which MPEG audio reserves).
        if b[0] == 0xFF, b[1] & 0xF6 == 0xF0 { return "aac" }
        // Raw MPEG audio frame sync: 11 set bits, then version/layer bits that aren't "reserved".
        if b[0] == 0xFF, b[1] & 0xE0 == 0xE0 {
            let version = (b[1] >> 3) & 0x03, layer = (b[1] >> 1) & 0x03
            guard version != 1, layer != 0 else { return nil }
            if layer == 1 { return "mp3" }           // Layer III
            if layer == 3 { return "mp1" }           // Layer I (rare)
            return "mp2"                             // Layer II (rare)
        }
        return nil
    }

    /// Reads just enough of a file to identify it.
    static func fileExtension(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return fileExtension(for: (try? handle.read(upToCount: 64)) ?? Data())
    }
}
