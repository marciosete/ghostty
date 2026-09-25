import Foundation

/// Speech from ElevenLabs text to speech, used to read Claude Code responses aloud.
///
/// The API key is kept in `~/.config/ghostty/elevenlabs-api-key`, readable only by its
/// owner. The keychain isn't used: every build of the app is signed differently, and each
/// one would ask for the password again, however often access is allowed.
///
/// The voice, model and speed can be changed with `defaults write` on the keys below.
enum ElevenLabs {
    static var apiKeyFile: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/ghostty/elevenlabs-api-key")
    }

    static let voiceIDKey = "ElevenLabsVoiceID"
    static let modelIDKey = "ElevenLabsModelID"
    static let speedKey = "ElevenLabsSpeed"

    /// Charlie: casual and upbeat, with an Australian accent.
    static let defaultVoiceID = "IKne3meq5aSn9XLyUdCD"

    /// The voices a session's tab offers.
    static let voices: [(name: String, id: String)] = [
        ("Charlie", "IKne3meq5aSn9XLyUdCD"),
        ("Laura", "FGY2WhTYpPnrIDTdsKH5"),
        ("Jessica", "cgSgspJ2msm6clMCkdW9"),
        ("Will", "bIHbv24MWmeRgasZH58o"),
        ("Liam", "TX3LPaxmHKxFdv7VOQHJ"),
        ("Chris", "iP95p4xoKVk53GoZ742B"),
        ("EUDA", "u8ADrbquiJqufR9XMtb8"),
    ]

    /// Flash starts speaking in under a second. eleven_v3 is more expressive, but takes
    /// several seconds to start.
    private static let defaultModelID = "eleven_flash_v2_5"
    private static let defaultSpeed = 1.2

    /// The audio is 16-bit mono PCM at this rate, so it can be played as it arrives.
    static let sampleRate = 24_000

    struct Voice: Equatable {
        let id: String
        let model: String
        let speed: Double

        /// The voice picked for a session, or the one set for every session.
        static func configured(id picked: String? = nil) -> Voice {
            let defaults = UserDefaults.ghostty
            let speed = defaults.double(forKey: speedKey)
            return Voice(
                id: picked ?? defaults.string(forKey: voiceIDKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultVoiceID,
                model: defaults.string(forKey: modelIDKey).flatMap { $0.isEmpty ? nil : $0 } ?? defaultModelID,
                speed: (0.7...1.2).contains(speed) ? speed : defaultSpeed)
        }

        /// eleven_v3 takes only 0, 0.5 or 1; lower is livelier on every model.
        var stability: Double { model == "eleven_v3" ? 0 : 0.35 }
    }

    enum Failure: Error {
        case http(status: Int, body: String)

        /// Too many requests at once, or too many lately: worth trying again shortly.
        var isRateLimit: Bool {
            if case .http(429, _) = self { return true }
            return false
        }
    }

    /// The API key, from its file, or from `ELEVENLABS_API_KEY` for an app started from a
    /// shell.
    static func apiKey() -> String? {
        let fromFile = (try? String(contentsOf: apiKeyFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let fromFile, !fromFile.isEmpty { return fromFile }
        let variable = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return variable?.isEmpty == false ? variable : nil
    }

    /// Speech of `text` in `voice`, as 16-bit little-endian mono PCM at `sampleRate`,
    /// streamed while it is generated.
    static func stream(of text: String, voice: Voice, apiKey: String) async throws -> URLSession.AsyncBytes {
        var components = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/")!
        components.path += "\(voice.id)/stream"
        components.queryItems = [URLQueryItem(name: "output_format", value: "pcm_\(sampleRate)")]

        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": voice.model,
            "voice_settings": [
                "stability": voice.stability,
                "similarity_boost": 0.75,
                "speed": voice.speed,
            ],
        ])

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 500 { break }
            }
            throw Failure.http(status: status, body: String(decoding: body, as: UTF8.self))
        }
        return bytes
    }
}
