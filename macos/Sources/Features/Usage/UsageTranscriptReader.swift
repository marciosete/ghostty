import Foundation

/// A transcript file found by a directory walk.
struct UsageTranscriptFile: Equatable {
    let path: String
    let size: Int
    let mtimeNs: Int

    var mtimeMs: Int { mtimeNs / 1_000_000 }
}

/// Where a parse of a transcript stopped, with what's needed to continue from there.
///
/// The guard hash fingerprints the bytes just before `resumeOffset`. A parse only resumes
/// when they still match: transcripts are append-only, but a rotated or rewritten file
/// read from the middle would corrupt the totals, and those cases all disturb the file
/// at that offset.
struct UsageParsePosition: Equatable {
    /// The offset just past the last newline-terminated line that was read.
    var resumeOffset: Int
    var guardLength: Int
    var guardHash: UInt32
}

struct UsageParseResult {
    /// Records from newline-terminated lines.
    let records: [UsageRecord]

    /// Records from a last line the writer hasn't terminated yet. They are kept apart
    /// because `position` leaves that line out: the next parse reads it again once it's
    /// complete, and counting it twice would double count.
    let tailRecords: [UsageRecord]

    let position: UsageParsePosition

    /// Whether the parse continued from an earlier position rather than the start.
    let resumed: Bool
}

/// Reads transcripts from disk. A cold 30 day scan can cover more than a gigabyte of
/// JSONL, so files are streamed in chunks, and only lines that can carry usage (found by
/// a byte search) are decoded as JSON.
enum UsageTranscriptReader {
    /// 64 bytes of JSONL are plenty to tell a replaced file apart.
    static let guardLength = 64

    private static let chunkSize = 1 << 20

    /// Lists the `.jsonl` files under `root` modified at or after `sinceMs`, or only the
    /// files named `fileName`. Grok's session folders also hold large logs that never
    /// carry usage, which the name filter skips.
    static func listFiles(in root: String, modifiedSinceMs sinceMs: Int, fileName: String? = nil) -> [UsageTranscriptFile] {
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return [] }

        var files: [UsageTranscriptFile] = []
        for case let relativePath as String in enumerator {
            let name = (relativePath as NSString).lastPathComponent
            if let fileName {
                guard name == fileName else { continue }
            } else {
                guard name.hasSuffix(".jsonl") else { continue }
            }

            // Files come and go while the walk runs; a vanished one is skipped.
            let path = (root as NSString).appendingPathComponent(relativePath)
            var info = stat()
            guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }

            let mtimeNs = Int(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int(info.st_mtimespec.tv_nsec)
            let file = UsageTranscriptFile(path: path, size: Int(info.st_size), mtimeNs: mtimeNs)
            if file.mtimeMs >= sinceMs {
                files.append(file)
            }
        }
        return files
    }

    /// Streams one transcript and returns its usage records, or nil when it couldn't be
    /// read. A failed read isn't an empty transcript, and callers must not cache it as one.
    ///
    /// With `resume`, parsing continues from that position when its guard bytes still
    /// match, so only appended lines are read. Otherwise the whole file is parsed.
    static func read(path: String, provider: UsageProvider, resumingFrom resume: UsageParsePosition? = nil) -> UsageParseResult? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let parser = LineParser(provider: provider)
        var start = 0
        var resumed = false
        if let resume, resume.resumeOffset > 0,
           guardHash(fd: fd, end: resume.resumeOffset, length: resume.guardLength) == resume.guardHash {
            start = resume.resumeOffset
            resumed = true
        }

        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkSize, alignment: 1)
        defer { buffer.deallocate() }

        var records: [UsageRecord] = []
        var pending: [UInt8] = []
        var offset = start
        var resumeOffset = start
        while true {
            let count = pread(fd, buffer.baseAddress, chunkSize, off_t(offset))
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { break }

            let chunk = UnsafeRawBufferPointer(rebasing: buffer[0..<count])
            let chunkOffset = offset
            offset += count

            var lineStart = 0
            while lineStart < count,
                  let newlinePointer = memchr(chunk.baseAddress! + lineStart, 0x0A, count - lineStart) {
                let newline = chunk.baseAddress!.distance(to: UnsafeRawPointer(newlinePointer))
                let line = UnsafeRawBufferPointer(rebasing: chunk[lineStart..<newline])
                if pending.isEmpty {
                    parser.parse(line, into: &records)
                } else {
                    pending.append(contentsOf: line)
                    pending.withUnsafeBytes { parser.parse($0, into: &records) }
                    pending.removeAll(keepingCapacity: true)
                }
                lineStart = newline + 1
                resumeOffset = chunkOffset + lineStart
            }

            if lineStart < count {
                pending.append(contentsOf: UnsafeRawBufferPointer(rebasing: chunk[lineStart..<count]))
            }
        }

        // A last line without its newline is parsed for this result but not consumed: its
        // writer may still be appending to it.
        var tailRecords: [UsageRecord] = []
        if !pending.isEmpty {
            pending.withUnsafeBytes { parser.parse($0, into: &tailRecords) }
        }

        let guardLength = min(Self.guardLength, resumeOffset)
        var hash: UInt32 = 0
        if guardLength > 0 {
            guard let windowHash = guardHash(fd: fd, end: resumeOffset, length: guardLength) else { return nil }
            hash = windowHash
        }

        return UsageParseResult(
            records: records,
            tailRecords: tailRecords,
            position: UsageParsePosition(
                resumeOffset: resumeOffset,
                guardLength: guardLength,
                guardHash: hash),
            resumed: resumed)
    }

    /// The FNV-1a hash of the `length` bytes before `end`, or nil when they can't be read.
    private static func guardHash(fd: Int32, end: Int, length: Int) -> UInt32? {
        guard length > 0, length <= Self.guardLength, end >= length else { return nil }
        var window = [UInt8](repeating: 0, count: length)
        let count = window.withUnsafeMutableBytes { pread(fd, $0.baseAddress, length, off_t(end - length)) }
        guard count == length else { return nil }
        return window.withUnsafeBytes(fnv1a)
    }

    static func fnv1a(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var hash: UInt32 = 0x811C_9DC5
        for byte in bytes {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hash
    }
}

/// Parses the lines of one transcript, skipping lines that can't carry usage before
/// decoding any JSON. Transcripts are mostly tool output, so this skips most of them.
private struct LineParser {
    let provider: UsageProvider

    func parse(_ line: UnsafeRawBufferPointer, into records: inout [UsageRecord]) {
        var line = line
        if line.last == 0x0D {
            line = UnsafeRawBufferPointer(rebasing: line.dropLast())
        }
        guard !line.isEmpty else { return }

        switch provider {
        case .claude:
            guard Self.contains(line, "\"usage\"") else { return }
            if let record = UsageTranscripts.parseClaudeLine(Self.data(line)) {
                records.append(record)
            }

        case .grok:
            guard Self.contains(line, "\"turn_completed\"") else { return }
            records.append(contentsOf: UsageTranscripts.parseGrokLine(Self.data(line)))
        }
    }

    private static func contains(_ line: UnsafeRawBufferPointer, _ needle: StaticString) -> Bool {
        needle.withUTF8Buffer { needle in
            memmem(line.baseAddress, line.count, needle.baseAddress, needle.count) != nil
        }
    }

    /// The line without a copy. The data is only used while the line's bytes are alive.
    private static func data(_ line: UnsafeRawBufferPointer) -> Data {
        Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: line.baseAddress!), count: line.count, deallocator: .none)
    }
}
