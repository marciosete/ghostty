import Foundation

/// Lays a Messages API request out as a folder of numbered Markdown files, in the order the
/// model reads them: system blocks, one file per tool, then the messages, with the context
/// Claude Code adds split into a file per part. A port of `explode-request.mjs`.
///
/// It returns the files rather than writing them, so a folder can be brought up to date by
/// writing only the files that changed.
enum RequestExploder {
    typealias JSON = [String: Any]

    /// The files for `request`, by path relative to the folder. `name` heads the README.
    static func files(of request: JSON, name: String, rawSize: Int) -> [String: Data] {
        var out = Output()
        let system = blocks(of: request["system"])
        let tools = request["tools"] as? [JSON] ?? []
        let messages = request["messages"] as? [JSON] ?? []

        // 01-system
        let systemNames = ["billing-header", "identity", "base-prompt"]
        var systemIndex: [(file: String, what: String, size: Int)] = []
        for (i, block) in system.enumerated() {
            let name = i < systemNames.count ? systemNames[i] : "block-\(i + 1)"
            let text = block["text"] as? String ?? ""
            let file = out.write(
                "01-system/\(pad(i + 1))-\(name).md",
                "# System block \(i + 1) — \(name)\n\n\(chars(text)) chars · \(tokensApprox(chars(text)))\n\(cacheNote(block))\n---\n\n\(text)")
            systemIndex.append((file, "system block \(i + 1): \(name)", chars(text)))
        }

        // 02-tools
        var toolRows: [(i: Int, name: String, file: String, one: String, size: Int)] = []
        var counters: [String: Int] = [:]
        for (i, tool) in tools.enumerated() {
            let name = tool["name"] as? String ?? tool["type"] as? String ?? "tool"
            let description = tool["description"] as? String ?? ""
            let group = toolGroup(name)
            counters[group, default: 0] += 1
            let schema = tool["input_schema"] as? JSON ?? [:]
            let properties = schema["properties"] as? JSON ?? [:]
            let required = Set(schema["required"] as? [String] ?? [])
            let rows = properties.keys.sorted().map { key -> String in
                let property = properties[key] as? JSON ?? [:]
                return "| `\(key)` | \(cell(typeOf(property))) | \(required.contains(key) ? "yes" : "") | \(cell(property["description"])) |"
            }
            let schemaJSON = prettyJSON(schema)
            let body = [
                "# \(name)",
                "",
                "Position \(i + 1) of \(tools.count) in `tools` · description \(chars(description)) chars · schema \(chars(schemaJSON)) chars",
                cacheNote(tool),
                "## Description",
                "",
                description.isEmpty ? "_(empty)_" : description,
                "",
                "## Parameters",
                "",
                rows.isEmpty ? "_(none)_" : "| Param | Type | Required | Description |\n|---|---|---|---|\n" + rows.joined(separator: "\n"),
                "",
                "<details><summary>Raw input_schema</summary>",
                "",
                fence(schemaJSON, "json"),
                "",
                "</details>",
            ].joined(separator: "\n")
            let file = out.write("02-tools/\(group)/\(pad(counters[group]!))-\(shortToolName(name)).md", body)
            toolRows.append((i + 1, name, file, firstSentence(description), chars(description) + chars(schemaJSON)))
        }
        let toolTotal = toolRows.reduce(0) { $0 + $1.size }
        out.write("02-tools/00-index.md", ([
            "# Tools (\(toolRows.count))",
            "",
            "Total \(kb(toolTotal)) chars (description + schema). Sorted by position in the request.",
            "",
            "| # | Tool | Size | One-liner |",
            "|---|---|---|---|",
        ] + toolRows.map { row in
            "| \(row.i) | [\(row.name)](\(row.file.dropFirst("02-tools/".count))) | \(kb(row.size)) | \(cell(row.one)) |"
        } + [
            "",
            "## Largest",
            "",
        ] + toolRows.sorted { $0.size > $1.size }.prefix(10).map { "- \($0.name) — \(kb($0.size))" })
            .joined(separator: "\n"))

        // 03-messages
        var messageRows: [(n: String, role: String, file: String, what: String, size: Int)] = []
        for (i, message) in messages.enumerated() {
            let n = pad(i + 1)
            let role = message["role"] as? String ?? "unknown"
            let blocks = self.blocks(of: message["content"])
            let total = blocks.reduce(0) { $0 + blockLength($1) }
            let isReminder = { (block: JSON) -> Bool in
                block["type"] as? String == "text" && (block["text"] as? String ?? "").hasPrefix("<system-reminder>")
            }
            let first = blocks.first { $0["type"] as? String == "text" && !isReminder($0) }?["text"] as? String
                ?? blocks.first { $0["type"] as? String == "tool_use" }?["name"] as? String
                ?? blocks.first?["text"] as? String
                ?? blocks.first?["type"] as? String
                ?? ""
            let firstLine = first.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let label = "\(role)-\(shortTitle(firstLine))"

            // Big context-bearing messages become folders of parts.
            if role == "user" && blocks.contains(where: isReminder) {
                let dir = "03-messages/\(n)-\(role)-context"
                var k = 0
                for block in blocks {
                    let text = block["text"] as? String ?? ""
                    if isReminder(block) && text.firstMatch(of: contentsOfLine) != nil {
                        for part in split(text, at: contentsOfTitle) {
                            k += 1
                            if part.title == "preamble" && chars(part.text) < 400 {
                                out.write("\(dir)/\(pad(k))-reminder-preamble.md", part.text)
                                continue
                            }
                            let title = part.title == "preamble" ? "preamble" : reminderTitle(part.text)
                            out.write(
                                "\(dir)/\(pad(k))-\(title).md",
                                "<!-- \(chars(part.text)) chars · \(tokensApprox(chars(part.text))) -->\n\n\(part.text)")
                        }
                    } else if isReminder(block) {
                        k += 1
                        out.write("\(dir)/\(pad(k))-\(reminderTitle(text)).md", text)
                    } else {
                        k += 1
                        let type = block["type"] as? String ?? "block"
                        out.write("\(dir)/\(pad(k))-\(type == "text" ? "user-prompt" : type).md", blockText(block) + cacheNote(block))
                    }
                }
                messageRows.append((n, role, dir + "/", "context reminders + prompt: “\(first.prefix(80))”", total))
                continue
            }

            if role == "system" && total > 3000 {
                let dir = "03-messages/\(n)-system-environment"
                let text = blocks.map { $0["text"] as? String ?? "" }.joined(separator: "\n")
                for (k, part) in split(text, at: systemSection).enumerated() {
                    out.write("\(dir)/\(pad(k + 1))-\(shortTitle(part.title)).md", part.text)
                }
                messageRows.append((n, role, dir + "/", "mid-conversation system: environment, agents, MCP, skills, mode", total))
                continue
            }

            let body = ([
                "# Message \(i + 1) — \(role)",
                "",
                "\(blocks.count) block(s) · \(total) chars",
                "",
            ] + blocks.enumerated().map { j, block in
                "## Block \(j + 1): \(block["type"] as? String ?? "block")\n\(cacheNote(block))\n\(blockText(block))\n"
            }).joined(separator: "\n")
            let file = out.write("03-messages/\(n)-\(label).md", body)
            let what = blocks.map { block -> String in
                switch block["type"] as? String {
                case "tool_use": return "tool_use \(block["name"] as? String ?? "")"
                case "text":
                    let text = (block["text"] as? String ?? "").prefix(60).replacingOccurrences(of: "\n", with: " ")
                    return "text “\(text)”"
                case let type: return type ?? "block"
                }
            }.joined(separator: " + ")
            messageRows.append((n, role, file, what, total))
        }

        // 04-settings
        let settings = request.filter { !["system", "tools", "messages"].contains($0.key) }
        out.write("04-settings.json", prettyJSON(settings))

        // 00-README
        let systemTotal = system.reduce(0) { $0 + chars($1["text"] as? String ?? "") }
        let messageTotal = messageRows.reduce(0) { $0 + $1.size }
        let all = systemTotal + toolTotal + messageTotal
        func show(_ value: Any?) -> String {
            guard let value else { return "— (not in capture)" }
            return "`\(value as? String ?? compactJSON(value))`"
        }
        func share(_ n: Int) -> String {
            all == 0 ? "0.0%" : String(format: "%.1f%%", 100 * Double(n) / Double(all))
        }
        var breakpoints: [String] = []
        for (i, block) in system.enumerated() where block["cache_control"] != nil {
            breakpoints.append("system[\(i)]")
        }
        for tool in tools where tool["cache_control"] != nil {
            breakpoints.append("tool \(tool["name"] as? String ?? "")")
        }
        for (i, message) in messages.enumerated() {
            guard let content = message["content"] as? [JSON] else { continue }
            for (j, block) in content.enumerated() where block["cache_control"] != nil {
                breakpoints.append("messages[\(i)].content[\(j)]")
            }
        }
        let safeguards = (request["safeguards"] as? [JSON] ?? []).compactMap { $0["type"] as? String }
        out.write("00-README.md", ([
            "# Request \(name)",
            "",
            "Source: `request.json` (\(kb(rawSize)) bytes)",
            "",
            "Files are numbered in the order the model reads them: system → tools → messages.",
            "",
            "## Settings",
            "",
            "- **model:** \(show(request["model"])) · **max_tokens:** \(show(request["max_tokens"])) · **stream:** \(show(request["stream"]))",
            "- **thinking:** \(show(request["thinking"])) · **output_config:** \(show(request["output_config"]))",
            "- **context_management:** \(show(request["context_management"]))",
            "- **safeguards:** \(safeguards.isEmpty ? "none" : safeguards.map { "`\($0)`" }.joined(separator: ", ")) (full detail in [04-settings.json](04-settings.json))",
            "- **cache breakpoints (\(breakpoints.count)):** \(breakpoints.isEmpty ? "none" : breakpoints.joined(separator: ", "))",
            "",
            "## Where the characters go",
            "",
            "| Part | Chars | ≈ Tokens | Share |",
            "|---|---|---|---|",
            "| [01-system/](01-system/) | \(kb(systemTotal)) | \(tokensApprox(systemTotal)) | \(share(systemTotal)) |",
            "| [02-tools/](02-tools/00-index.md) (\(toolRows.count)) | \(kb(toolTotal)) | \(tokensApprox(toolTotal)) | \(share(toolTotal)) |",
            "| [03-messages/](03-messages/) (\(messageRows.count)) | \(kb(messageTotal)) | \(tokensApprox(messageTotal)) | \(share(messageTotal)) |",
            "| **Total** | **\(kb(all))** | **\(tokensApprox(all))** | |",
            "",
            "_Token counts are chars ÷ 4, a rough estimate._",
            "",
            "## System",
            "",
        ] + systemIndex.map { "- [\($0.file)](\($0.file)) — \($0.what) (\(kb($0.size)))" } + [
            "",
            "## Messages",
            "",
            "| # | Role | Size | What |",
            "|---|---|---|---|",
        ] + messageRows.map { "| [\($0.n)](\($0.file)) | \($0.role) | \(kb($0.size)) | \(cell($0.what)) |" })
            .joined(separator: "\n"))

        return out.files
    }

    // MARK: Output

    private struct Output {
        var files: [String: Data] = [:]

        @discardableResult
        mutating func write(_ path: String, _ body: String) -> String {
            files[path] = Data((body.hasSuffix("\n") ? body : body + "\n").utf8)
            return path
        }
    }

    // MARK: Formatting

    private static func pad(_ n: Int) -> String {
        n < 10 ? "0\(n)" : String(n)
    }

    /// Lengths count UTF-16 units, as the script's did.
    private static func chars(_ text: String) -> Int {
        text.utf16.count
    }

    private static func kb(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : String(n)
    }

    private static func tokensApprox(_ n: Int) -> String {
        "~\(kb(Int((Double(n) / 4).rounded()))) tok"
    }

    private static func slug(_ text: String) -> String {
        let words = text.lowercased()
            .split { !(("a"..."z").contains($0) || ("0"..."9").contains($0)) }
            .joined(separator: "-")
        let capped = String(words.prefix(50))
        let trimmed = capped.hasSuffix("-") ? String(capped.dropLast()) : capped
        return trimmed.isEmpty ? "part" : trimmed
    }

    private static func fence(_ text: String, _ language: String = "") -> String {
        let ticks = text.contains("```") ? "````" : "```"
        return "\(ticks)\(language)\n\(text)\n\(ticks)"
    }

    private static func cacheNote(_ block: JSON) -> String {
        guard let control = block["cache_control"] else { return "" }
        return "\n> **cache_control:** `\(compactJSON(control))` (cache breakpoint ends here)\n"
    }

    private static func cell(_ value: Any?) -> String {
        let text: String
        switch value {
        case nil, is NSNull: text = ""
        case let string as String: text = string
        case let other?: text = compactJSON(other)
        }
        return text.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n+", with: "<br>", options: .regularExpression)
    }

    private static func prettyJSON(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func compactJSON(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
        else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Blocks

    /// A content value as blocks: a string is one text block.
    private static func blocks(of content: Any?) -> [JSON] {
        if let text = content as? String { return [["type": "text", "text": text]] }
        return content as? [JSON] ?? []
    }

    private static func blockText(_ block: JSON) -> String {
        switch block["type"] as? String {
        case "text":
            return block["text"] as? String ?? ""
        case "thinking":
            let thinking = block["thinking"] as? String ?? ""
            return "_(thinking block — \(thinking.isEmpty ? "redacted; signature only" : "\(chars(thinking)) chars"))_"
                + (thinking.isEmpty ? "" : "\n\n" + thinking)
        case "redacted_thinking":
            return "_(redacted thinking)_"
        case "tool_use":
            return "**tool_use** `\(block["name"] as? String ?? "")` (id `\(block["id"] as? String ?? "")`)\n\n"
                + fence(prettyJSON(block["input"] ?? [String: Any]()), "json")
        case "tool_result":
            let content: String
            if let text = block["content"] as? String {
                content = text
            } else {
                content = (block["content"] as? [JSON] ?? []).map { part in
                    part["type"] as? String == "text" ? part["text"] as? String ?? "" : "[\(part["type"] as? String ?? "block")]"
                }.joined(separator: "\n")
            }
            let error = block["is_error"] as? Bool == true ? " — ERROR" : ""
            return "**tool_result** for `\(block["tool_use_id"] as? String ?? "")`\(error)\n\n\(fence(content))"
        default:
            return fence(prettyJSON(block), "json")
        }
    }

    private static func blockLength(_ block: JSON) -> Int {
        if let text = block["text"] as? String { return chars(text) }
        if let thinking = block["thinking"] as? String { return chars(thinking) }
        if let content = block["content"] as? String { return chars(content) }
        return chars(compactJSON(block["content"] ?? block["input"] ?? ""))
    }

    // MARK: Tools

    private static func toolGroup(_ name: String) -> String {
        if name.hasPrefix("mcp__claude-in-chrome__") { return "mcp-chrome" }
        if name.hasPrefix("mcp__claude_ai_Claude_Docs__") { return "mcp-claude-docs" }
        if name.hasPrefix("mcp__") { return "mcp-other" }
        return "core"
    }

    /// An MCP tool's name without its `mcp__<server>__` prefix.
    private static func shortToolName(_ name: String) -> String {
        guard name.hasPrefix("mcp__"),
              let separator = name.range(of: "__", range: name.index(name.startIndex, offsetBy: 5)..<name.endIndex)
        else { return name }
        return String(name[separator.upperBound...])
    }

    private static func typeOf(_ schema: JSON?) -> String {
        guard let schema, !schema.isEmpty else { return "" }
        if let values = schema["enum"] as? [Any] {
            return values.map { "`\($0 as? String ?? compactJSON($0))`" }.joined(separator: " \\| ")
        }
        if let options = schema["anyOf"] as? [JSON] {
            return options.map { typeOf($0) }.joined(separator: " \\| ")
        }
        if schema["type"] as? String == "array" {
            let items = typeOf(schema["items"] as? JSON)
            return "\(items.isEmpty ? "any" : items)[]"
        }
        if let constant = schema["const"] {
            return "`\(constant as? String ?? compactJSON(constant))`"
        }
        return schema["type"] as? String ?? "any"
    }

    private static func firstSentence(_ description: String) -> String {
        let line = description.split(separator: "\n", omittingEmptySubsequences: false)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
            .map(String.init) ?? ""
        let sentence = line.firstMatch(of: sentenceEnd).map { String($0.output[1].substring ?? "") } ?? line
        return String(sentence.prefix(200))
    }

    // MARK: Messages

    private static let sentenceEnd = try! Regex(#"^(.+?[.!?])(\s|$)"#)
    private static let contentsOfLine = try! Regex(#"(?m)^Contents of "#)
    private static let contentsOfTitle = try! Regex(#"^Contents of (.+?) \("#)
    private static let systemSection = try! Regex(
        #"^(# .+|You are powered by.*|Available agent types.*|The following skills.*|The following deferred tools.*|The following tools just became.*|While auto mode.*)$"#)

    /// Known lead-in lines, and the short file names they get.
    private static let known: [(prefix: String, name: String)] = [
        ("As you answer the user's questions", "user-email-and-git-status"),
        ("Attribution for git commits", "commit-attribution"),
        ("You are powered by", "model-identity"),
        ("Available agent types", "agent-types"),
        ("The following skills", "skills-list"),
        ("The following deferred tools", "deferred-tools"),
        ("The following tools just became", "newly-loaded-tools"),
        ("While auto mode", "auto-mode"),
        ("The user hasn't heard from you", "progress-nudge"),
        ("[SUGGESTION MODE", "suggestion-mode"),
    ]

    /// A short file name for a section that starts with `line`.
    static func shortTitle(_ line: String) -> String {
        let bare = line.hasPrefix("#") ? String(line.drop { $0 == "#" }.drop { $0.isWhitespace }) : line
        if let hit = known.first(where: { bare.hasPrefix($0.prefix) }) { return hit.name }
        return slug(line).split(separator: "-").prefix(4).joined(separator: "-")
    }

    private static func reminderTitle(_ text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let match = line.firstMatch(of: contentsOfTitle), let path = match.output[1].substring else { continue }
            let base = (String(path) as NSString).lastPathComponent
            return base == "CLAUDE.md" ? "claude-md" : slug(base.hasSuffix(".md") ? String(base.dropLast(3)) : base)
        }
        let heading = text.replacingOccurrences(of: "<system-reminder>", with: "")
            .replacingOccurrences(of: "</system-reminder>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return shortTitle(heading)
    }

    /// Splits `text` into sections at lines matching `pattern`. The first section keeps
    /// whatever comes before the first match, and sections with nothing but blank lines are
    /// dropped.
    private static func split(_ text: String, at pattern: Regex<AnyRegexOutput>) -> [(title: String, text: String)] {
        var parts: [(title: String, lines: [String])] = []
        var current: (title: String, lines: [String]) = ("preamble", [])
        for line in text.components(separatedBy: "\n") {
            if let match = line.firstMatch(of: pattern) {
                if !current.lines.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parts.append(current)
                }
                let title = match.output.count > 1 ? match.output[1].substring.map(String.init) ?? line : line
                current = (title, [line])
            } else {
                current.lines.append(line)
            }
        }
        if !current.lines.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(current)
        }
        return parts.map { ($0.title, $0.lines.joined(separator: "\n")) }
    }
}
