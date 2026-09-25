import AppKit
import AVFoundation
import Foundation
import OSLog

/// The last response of a Claude Code session, read from its transcript.
enum ClaudeCodeResponse {
    /// How much of the end of a transcript is read. The last response is near the end, and a
    /// transcript can be many megabytes.
    private static let tailSize: UInt64 = 4 << 20

    /// The text of the last response in the transcript at `url`.
    static func last(inTranscript url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > tailSize ? end - tailSize : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return nil }

        var lines = data.split(separator: UInt8(ascii: "\n")).map { Data($0) }
        // Reading from the middle of the file starts partway through a line.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return last(inLines: lines)
    }

    /// The text of the last response in transcript lines. Claude Code writes each block of
    /// a message on its own line, so the response is the text blocks of the last message
    /// that has any. Text between tool calls is in earlier messages, and isn't included.
    static func last(inLines lines: [Data]) -> String? {
        var messageID: String?
        var texts: [String] = []

        for line in lines.reversed() {
            guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  entry["type"] as? String == "assistant",
                  entry["isSidechain"] as? Bool != true,
                  let message = entry["message"] as? [String: Any],
                  // Claude Code writes messages of its own, such as "No response requested."
                  message["model"] as? String != "<synthetic>",
                  let content = message["content"] as? [[String: Any]] else { continue }

            let id = message["id"] as? String
            if messageID != nil, id != messageID { break }

            let blockTexts = content.compactMap { block -> String? in
                guard block["type"] as? String == "text",
                      let text = block["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return text
            }
            guard !blockTexts.isEmpty else { continue }

            // A message without an id can't be told apart from the next, so it stands alone.
            guard let id else { return blockTexts.joined(separator: "\n\n") }
            messageID = id
            texts.insert(contentsOf: blockTexts, at: 0)
        }

        return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
    }

    /// Markdown as it should be read aloud: without code blocks, table rules, link targets
    /// or the characters that mark formatting.
    static func spoken(fromMarkdown markdown: String) -> String {
        var lines: [String] = []
        var fence: String?

        for rawLine in markdown.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                continue
            }

            var line = trimmed
            if line.hasPrefix("|") {
                // A table's rule under its header says nothing.
                if line.allSatisfy({ "|-: ".contains($0) }) { continue }
                line = line
                    .split(separator: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: ", ")
            }

            line = line
                // [text](target) reads as its text, and a bare address as "link".
                .replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"https?://\S+"#, with: "link", options: .regularExpression)
                // Headings, quotes and bullets.
                .replacingOccurrences(of: #"^(#{1,6}|>|[-*+])\s+"#, with: "", options: .regularExpression)
                // Emphasis and inline code. A lone underscore is often part of a name.
                .replacingOccurrences(of: #"\*+|__|`"#, with: "", options: .regularExpression)

            lines.append(line)
        }

        return lines
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Reads the last response of a tab's Claude Code session aloud, when asked. One tab speaks
/// at a time: asking another stops the first, and asking the one speaking stops it.
///
/// The response is spoken by ElevenLabs when an API key is set up (see `ElevenLabs`),
/// played as it streams in, and by the system voice otherwise, or if ElevenLabs fails
/// before saying anything.
@MainActor
final class ClaudeCodeSpeaker: NSObject {
    static let shared = ClaudeCodeSpeaker()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: ClaudeCodeSpeaker.self)
    )

    /// Audio is kept for this many responses, so reading one again starts at once.
    private static let audioCacheLimit = 8

    private let synthesizer = AVSpeechSynthesizer()
    private let player = PCMPlayer(sampleRate: ElevenLabs.sampleRate)

    /// The tab being read, and the reading of it.
    private weak var speakingWindow: TerminalWindow?
    private var reading: Task<Void, Never>?

    /// The ElevenLabs stream being played, so stopping cancels it.
    private var streaming: Task<PCMPlayer.Streamed, Error>?
    private var audioCache: [String: Data] = [:]

    /// What is playing now, and the reading waiting for it to end. A stopped utterance or
    /// buffer can report its end late, so only the current one's end counts.
    private var utterance: AVSpeechUtterance?
    private var playing: CheckedContinuation<Void, Never>?
    private var playID = 0

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Reads the last response of `window`'s session, or stops if it is being read.
    func toggle(_ window: TerminalWindow) {
        if speakingWindow === window {
            stop()
            return
        }
        stop()

        // The focused split's session first, then any other in the tab.
        let controller = window.terminalController
        let leaves = controller?.surfaceTree.root?.leaves() ?? []
        let focused = controller?.focusedSurface
        let pids = (leaves.filter { $0 === focused } + leaves.filter { $0 !== focused })
            .compactMap { $0.surfaceModel?.foregroundPID }

        // The tab shows it is speaking from the click, since the audio takes a moment.
        speakingWindow = window
        window.isSpeakingClaudeCodeResponse = true
        let voice = window.speechVoiceID
        reading = Task {
            await read(pids: pids, voice: voice)
            guard !Task.isCancelled else { return }
            reading = nil
            player.stop()
            speakingWindow?.isSpeakingClaudeCodeResponse = false
            speakingWindow = nil
        }
    }

    func stop() {
        reading?.cancel()
        reading = nil
        streaming?.cancel()
        streaming = nil

        playID += 1
        player.stop()
        utterance = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        finishPlaying()

        speakingWindow?.isSpeakingClaudeCodeResponse = false
        speakingWindow = nil
    }

    private func read(pids: [Int], voice: String?) async {
        let found = await Task.detached(priority: .userInitiated) { () -> (text: String, apiKey: String?)? in
            let text = pids.lazy
                .compactMap { ClaudeCodeSession.running(pid: $0)?.transcript }
                .compactMap { ClaudeCodeResponse.last(inTranscript: $0) }
                .map { ClaudeCodeResponse.spoken(fromMarkdown: $0) }
                .first { !$0.isEmpty }
            return text.map { ($0, ElevenLabs.apiKey()) }
        }.value
        guard !Task.isCancelled else { return }

        guard let found else {
            NSSound.beep()
            return
        }
        if let apiKey = found.apiKey {
            await readWithElevenLabs(found.text, voice: .configured(id: voice), apiKey: apiKey)
        } else {
            await speakWithSystemVoice(found.text)
        }
    }

    // MARK: ElevenLabs

    private func readWithElevenLabs(_ text: String, voice: ElevenLabs.Voice, apiKey: String) async {
        let key = "\(voice.id)|\(voice.model)|\(voice.speed)|\(text)"
        if let cached = audioCache[key] {
            await playToEnd(cached)
            return
        }

        let player = player
        let stream = Task.detached(priority: .userInitiated) {
            try await player.play(Self.speechStream(of: text, voice: voice, apiKey: apiKey))
        }
        streaming = stream

        do {
            let streamed = try await stream.value
            guard !Task.isCancelled else { return }
            streaming = nil
            if audioCache.count >= Self.audioCacheLimit { audioCache.removeAll() }
            audioCache[key] = streamed.all
            await playToEnd(streamed.rest)
        } catch {
            guard !Task.isCancelled else { return }
            streaming = nil
            Self.logger.warning("ElevenLabs speech failed: \(String(describing: error), privacy: .public)")
            if case PCMPlayer.Failure.failedAfterStarting = error { return }
            await speakWithSystemVoice(text)
        }
    }

    /// The speech stream, asked for again a few times while ElevenLabs is rate limited.
    /// A stream that was just stopped can still count against the limit for a moment.
    private nonisolated static func speechStream(
        of text: String, voice: ElevenLabs.Voice, apiKey: String
    ) async throws -> URLSession.AsyncBytes {
        var retries = 0
        while true {
            do {
                return try await ElevenLabs.stream(of: text, voice: voice, apiKey: apiKey)
            } catch let failure as ElevenLabs.Failure where failure.isRateLimit && retries < 3 {
                retries += 1
                try await Task.sleep(nanoseconds: UInt64(retries) * 500_000_000)
            }
        }
    }

    /// Plays `pcm` after what is already playing, and returns when all of it has played.
    private func playToEnd(_ pcm: Data) async {
        let id = playID
        await withCheckedContinuation { continuation in
            playing = continuation
            do {
                try player.start()
            } catch {
                Self.logger.warning("Audio couldn't start: \(String(describing: error), privacy: .public)")
                finishPlaying()
                return
            }
            player.schedule(pcm) {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard id == self.playID else { return }
                        self.finishPlaying()
                    }
                }
            }
        }
    }

    // MARK: System voice

    private func speakWithSystemVoice(_ text: String) async {
        let utterance = AVSpeechUtterance(string: text)
        if #available(macOS 14.0, *) {
            // The voice and rate picked in System Settings > Accessibility > Spoken Content.
            utterance.prefersAssistiveTechnologySettings = true
        }
        self.utterance = utterance
        await withCheckedContinuation { continuation in
            playing = continuation
            synthesizer.speak(utterance)
        }
    }

    private func finishPlaying() {
        let continuation = playing
        playing = nil
        continuation?.resume()
    }
}

extension ClaudeCodeSpeaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        spoken(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        spoken(utterance)
    }

    private nonisolated func spoken(_ utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard utterance === self.utterance else { return }
                self.utterance = nil
                self.finishPlaying()
            }
        }
    }
}

/// Plays 16-bit little-endian mono PCM, starting as soon as the first of it arrives.
/// `AVAudioPlayerNode` takes buffers from any thread.
final class PCMPlayer: @unchecked Sendable {
    enum Failure: Error {
        /// The stream failed after some of it had played.
        case failedAfterStarting(Error)
    }

    /// What a stream played: all of it, and the end, which isn't scheduled yet so that its
    /// end can be waited on.
    struct Streamed: Sendable {
        let all: Data
        let rest: Data
    }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format: AVAudioFormat

    /// Audio is scheduled this many bytes at a time: a tenth of a second.
    private let bufferBytes: Int

    init(sampleRate: Int) {
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
        bufferBytes = sampleRate / 10 * 2
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    func start() throws {
        if !engine.isRunning { try engine.start() }
        if !node.isPlaying { node.play() }
    }

    /// Drops everything scheduled, and lets the audio device go.
    func stop() {
        node.stop()
        engine.pause()
    }

    /// Plays `bytes` as they arrive, but the last of them, which it returns with the rest.
    func play(_ bytes: URLSession.AsyncBytes) async throws -> Streamed {
        var all = Data()
        var pending = Data()
        pending.reserveCapacity(bufferBytes)
        do {
            for try await byte in bytes {
                pending.append(byte)
                guard pending.count >= bufferBytes else { continue }
                try Task.checkCancellation()
                if all.isEmpty { try start() }
                schedule(pending)
                all.append(pending)
                pending.removeAll(keepingCapacity: true)
            }
        } catch {
            if all.isEmpty || error is CancellationError { throw error }
            throw Failure.failedAfterStarting(error)
        }
        all.append(pending)
        return Streamed(all: all, rest: pending)
    }

    func schedule(_ pcm: Data, completion: (@Sendable () -> Void)? = nil) {
        // A sample is two bytes; an odd one left over is dropped. An empty buffer still
        // reports its end.
        let frames = max(pcm.count / 2, 1)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let samples = buffer.floatChannelData?[0] else {
            completion?()
            return
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        samples[0] = 0
        pcm.withUnsafeBytes { raw in
            for i in 0..<(pcm.count / 2) {
                samples[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768
            }
        }
        if let completion {
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in completion() }
        } else {
            node.scheduleBuffer(buffer)
        }
    }
}
