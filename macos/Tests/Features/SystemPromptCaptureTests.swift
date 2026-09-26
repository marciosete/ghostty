import Foundation
import Testing
@testable import Ghostty

private func request(_ head: String, body: String = "") -> Data {
    Data((head.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n\r\n" + body).utf8)
}

struct ProxyRequestTests {
    @Test func readsARequestWithALength() throws {
        let parsed = try #require(try ProxyRequest.parse(request(
            "POST /v1/messages?beta=true HTTP/1.1\nHost: 127.0.0.1:1234\nContent-Length: 5",
            body: "hello")))

        #expect(parsed.method == "POST")
        #expect(parsed.target == "/v1/messages?beta=true")
        #expect(parsed.path == "/v1/messages")
        #expect(parsed.header("host") == "127.0.0.1:1234")
        #expect(parsed.body == Data("hello".utf8))
    }

    @Test func waitsForTheWholeBody() throws {
        #expect(try ProxyRequest.parse(request("POST / HTTP/1.1\nContent-Length: 10", body: "hello")) == nil)
        #expect(try ProxyRequest.parse(Data("POST / HTTP/1.1\r\nContent-".utf8)) == nil)
    }

    @Test func joinsAChunkedBody() throws {
        let head = "POST / HTTP/1.1\nTransfer-Encoding: chunked"
        #expect(try ProxyRequest.parse(request(head, body: "5\r\nhello\r\n")) == nil)

        let parsed = try #require(try ProxyRequest.parse(request(head, body: "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")))
        #expect(parsed.body == Data("hello world".utf8))
    }

    @Test func readsARequestWithoutABody() throws {
        let parsed = try #require(try ProxyRequest.parse(request("GET /v1/models HTTP/1.1\nHost: x")))
        #expect(parsed.body.isEmpty)
    }

    @Test func rejectsAMalformedRequest() {
        #expect(throws: ProxyRequest.ParseError.self) {
            try ProxyRequest.parse(request("nonsense"))
        }
    }
}

private typealias JSON = [String: Any]

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func text(_ text: String) -> JSON { ["type": "text", "text": text] }

private let mainSystem: [JSON] = [
    text("x-anthropic-billing-header: cc_version=1"), text("You are Claude Code."), text("Be helpful."),
]
private let bash: JSON = [
    "name": "Bash",
    "description": "Runs a command.",
    "input_schema": [
        "type": "object",
        "properties": ["command": ["type": "string", "description": "The command"]],
        "required": ["command"],
    ],
]
private let chrome: JSON = [
    "name": "mcp__claude-in-chrome__navigate",
    "description": "Goes to a URL.\nMore.",
    "input_schema": ["type": "object"],
]
private let opening: JSON = ["role": "user", "content": [
    text("<system-reminder>\nContents of /repo/CLAUDE.md (project instructions):\n\n# Rules\n</system-reminder>"),
    text("fix the bug"),
]]

private func conversation(_ messages: [JSON], system: Any = mainSystem, tools: [JSON] = [bash, chrome]) -> JSON {
    ["model": "claude-opus-5-5", "system": system, "tools": tools, "messages": messages, "max_tokens": 64000]
}

private let sessionHead = """
    POST /v1/messages?beta=true HTTP/1.1
    Authorization: Bearer sk-ant-oat-secret
    X-Claude-Code-Session-Id: 2A27681F-602C-4DA1-9535-53F171AC7B00
    """

private func proxyRequest(_ body: JSON, head: String = sessionHead) throws -> ProxyRequest {
    let json = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
    return try #require(try ProxyRequest.parse(request(head + "\nContent-Length: \(json.utf8.count)", body: json)))
}

private func files(in directory: URL) -> [String] {
    (FileManager.default.enumerator(atPath: directory.path)?.compactMap { $0 as? String } ?? []).sorted()
}

private func modified(_ url: URL) throws -> Date {
    try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
}

struct CaptureFolderTests {
    @Test func writesOnlyWhatChanged() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try CaptureFolder.sync(["a.md": Data("a".utf8), "sub/b.md": Data("b".utf8)], into: directory)
        let a = directory.appendingPathComponent("a.md")
        let old = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: a.path)

        try CaptureFolder.sync(["a.md": Data("a".utf8), "sub/b.md": Data("changed".utf8)], into: directory)
        #expect(try modified(a) == old)
        #expect(try Data(contentsOf: directory.appendingPathComponent("sub/b.md")) == Data("changed".utf8))
    }

    @Test func removesWhatIsGoneButKeepsWhatItIsTold() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try CaptureFolder.sync(["a.md": Data(), "old/b.md": Data(), "agents/x/c.md": Data()], into: directory)
        try Data().write(to: directory.appendingPathComponent(".DS_Store"))
        try CaptureFolder.sync(["a.md": Data()], into: directory, keeping: ["agents"])

        #expect(files(in: directory) == [".DS_Store", "a.md", "agents", "agents/x", "agents/x/c.md"])
    }
}

struct CaptureRouterTests {
    @Test func keepsTheMainConversationAtTheTop() {
        var router = CaptureRouter()
        #expect(router.folder(for: conversation([opening]), path: "/v1/messages") == "")
        let reply: JSON = ["role": "assistant", "content": [text("done")]]
        let later = conversation([opening, reply, ["role": "user", "content": "thanks"]])
        #expect(router.folder(for: later, path: "/v1/messages") == "")
    }

    @Test func givesEachSubagentAFolder() {
        var router = CaptureRouter()
        _ = router.folder(for: conversation([opening]), path: "/v1/messages")

        let agentSystem = [text("x-anthropic-billing-header: cc_version=1"), text("You are a file search specialist.")]
        let agentOpening: JSON = ["role": "user", "content": [
            text("<system-reminder>context</system-reminder>"), text("Find the parser, then stop."),
        ]]
        let agent = conversation([agentOpening], system: agentSystem, tools: [bash])
        #expect(router.folder(for: agent, path: "/v1/messages") == "agents/01-find-the-parser-then-stop")

        let later = conversation([agentOpening, ["role": "assistant", "content": "found it"]], system: agentSystem, tools: [bash])
        #expect(router.folder(for: later, path: "/v1/messages") == "agents/01-find-the-parser-then-stop")
        #expect(router.folder(for: conversation([opening]), path: "/v1/messages") == "")
    }

    @Test func followsTheMainConversationThroughACompaction() {
        var router = CaptureRouter()
        _ = router.folder(for: conversation([opening]), path: "/v1/messages")
        let compacted = conversation([
            ["role": "user", "content": "This session is being continued from a previous conversation."],
        ])
        #expect(router.folder(for: compacted, path: "/v1/messages") == "")
    }

    @Test func putsSideCallsApart() {
        var router = CaptureRouter()
        _ = router.folder(for: conversation([opening]), path: "/v1/messages")

        let quota: JSON = ["model": "m", "max_tokens": 1, "messages": [["role": "user", "content": "quota"]]]
        #expect(router.folder(for: quota, path: "/v1/messages") == "side-calls/quota")

        let title = conversation(
            [["role": "user", "content": "<session>fix the bug</session>"]],
            system: [
                text("x-anthropic-billing-header: cc_version=1"), text("You are Claude Code."),
                text("You are naming a coding session so the user can pick it."),
            ],
            tools: [])
        #expect(router.folder(for: title, path: "/v1/messages") == "side-calls/you-are-naming-a-coding-session")

        let suggestion = conversation([
            opening, ["role": "user", "content": [text("[SUGGESTION MODE: Suggest what the user might type.]")]],
        ])
        #expect(router.folder(for: suggestion, path: "/v1/messages") == "side-calls/suggestion-mode")

        #expect(router.folder(for: conversation([opening]), path: "/v1/messages/count_tokens")
            == "side-calls/v1-messages-count-tokens")
    }
}

struct RequestExploderTests {
    @Test func laysTheRequestOutLikeTheScript() throws {
        let toolUse: JSON = ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "ls"]]
        let files = RequestExploder.files(
            of: conversation([opening, ["role": "assistant", "content": [toolUse]]]),
            name: "Fix the bug (2a27681f)", rawSize: 1234)

        #expect(files.keys.sorted() == [
            "00-README.md",
            "01-system/01-billing-header.md",
            "01-system/02-identity.md",
            "01-system/03-base-prompt.md",
            "02-tools/00-index.md",
            "02-tools/core/01-Bash.md",
            "02-tools/mcp-chrome/01-navigate.md",
            "03-messages/01-user-context/01-reminder-preamble.md",
            "03-messages/01-user-context/02-claude-md.md",
            "03-messages/01-user-context/03-user-prompt.md",
            "03-messages/02-assistant-bash.md",
            "04-settings.json",
        ])

        func read(_ path: String) throws -> String { String(decoding: try #require(files[path]), as: UTF8.self) }
        #expect(try read("02-tools/core/01-Bash.md").contains("| `command` | string | yes | The command |"))
        #expect(try read("02-tools/00-index.md")
            .contains("| 2 | [mcp__claude-in-chrome__navigate](mcp-chrome/01-navigate.md) |"))
        #expect(try read("03-messages/01-user-context/02-claude-md.md").contains("# Rules"))
        #expect(try read("00-README.md").hasPrefix("# Request Fix the bug (2a27681f)\n"))
        #expect(try read("04-settings.json").contains("\"max_tokens\" : 64000"))
    }
}

struct SystemPromptCaptureTests {
    @Test func keepsTheLatestRequestOfEachThreadInTheSessionFolder() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = SystemPromptCapture(directory: directory)
        func save(_ body: JSON) throws {
            let request = try proxyRequest(body)
            let parsed = try JSONSerialization.jsonObject(with: request.body) as? JSON
            let id = SystemPromptCapture.sessionID(of: request, body: parsed)
            try capture.save(request, body: parsed, sessionID: id, sessionName: "Fix the bug")
        }

        try save(conversation([opening]))
        let reply: JSON = ["role": "assistant", "content": [text("done")]]
        let last = conversation([opening, reply, ["role": "user", "content": "thanks"]])
        try save(last)
        try save(["model": "m", "max_tokens": 1, "messages": [["role": "user", "content": "quota"]]])

        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["Fix the bug (2a27681f)"])
        let session = directory.appendingPathComponent("Fix the bug (2a27681f)")
        let saved = try Data(contentsOf: session.appendingPathComponent("request.json"))
        #expect(saved == (try proxyRequest(last)).body)
        #expect(files(in: session).contains("03-messages/03-user-thanks.md"))
        #expect(files(in: session).contains("side-calls/quota/request.json"))

        let head = try String(contentsOf: session.appendingPathComponent("request.http"), encoding: .utf8)
        #expect(head.contains("Authorization: [redacted]"))
        #expect(!head.contains("secret"))
    }

    @Test func followsTheTabWhenItIsRenamed() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = SystemPromptCapture(directory: directory)
        let request = try proxyRequest(conversation([opening]))
        let body = try JSONSerialization.jsonObject(with: request.body) as? JSON

        try capture.save(request, body: body, sessionID: "2a27681f-602c", sessionName: nil)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("2a27681f/request.json").path))

        try capture.save(request, body: body, sessionID: "2a27681f-602c", sessionName: "Fix: the/bug")
        try capture.save(request, body: body, sessionID: "2a27681f-602c", sessionName: nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["Fix- the-bug (2a27681f)"])
    }

    @Test func readsTheSessionFromTheMetadata() throws {
        let request = try proxyRequest(
            ["metadata": ["user_id": #"{"device_id":"d","session_id":"ABC"}"#]], head: "POST /v1/messages HTTP/1.1")
        let body = try JSONSerialization.jsonObject(with: request.body) as? JSON
        #expect(SystemPromptCapture.sessionID(of: request, body: body) == "abc")
    }
}
