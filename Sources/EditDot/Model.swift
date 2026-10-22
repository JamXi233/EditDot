// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import AppKit
import CoreFoundation

enum TextEncoding: String, Codable, CaseIterable {
    case utf8, utf8BOM, utf16LE, utf16BE, gb18030, big5, shiftJIS, windows1252, latin1
    var title: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8BOM: return "UTF-8 BOM"
        case .utf16LE: return "UTF-16 LE"
        case .utf16BE: return "UTF-16 BE"
        case .gb18030: return "GB18030"
        case .big5: return "Big5"
        case .shiftJIS: return "Shift JIS"
        case .windows1252: return "Windows-1252"
        case .latin1: return "ISO-8859-1"
        }
    }
    var foundation: String.Encoding {
        switch self {
        case .utf8, .utf8BOM: return .utf8
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        case .gb18030: return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case .big5: return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        case .shiftJIS: return .shiftJIS
        case .windows1252: return .windowsCP1252
        case .latin1: return .isoLatin1
        }
    }
    var xmlCharset: String {
        switch self {
        case .utf8, .utf8BOM: return "UTF-8"
        case .utf16LE, .utf16BE: return "UTF-16"
        case .gb18030: return "GB18030"
        case .big5: return "Big5"
        case .shiftJIS: return "Shift_JIS"
        case .windows1252: return "windows-1252"
        case .latin1: return "ISO-8859-1"
        }
    }
    func encode(_ text: String) throws -> Data {
        guard var data = text.data(using: foundation, allowLossyConversion: false) else { throw FileError.unrepresentable }
        switch self {
        case .utf8BOM: data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0)
        case .utf16LE: data.insert(contentsOf: [0xFF, 0xFE], at: 0)
        case .utf16BE: data.insert(contentsOf: [0xFE, 0xFF], at: 0)
        default: break
        }
        return data
    }
    static func decode(_ data: Data, as forced: TextEncoding? = nil) throws -> (String, TextEncoding) {
        if let forced = forced {
            var bytes = data
            if (forced == .utf8 || forced == .utf8BOM), bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
            if forced == .utf16LE, bytes.starts(with: [0xFF, 0xFE]) { bytes = bytes.dropFirst(2) }
            if forced == .utf16BE, bytes.starts(with: [0xFE, 0xFF]) { bytes = bytes.dropFirst(2) }
            guard let text = String(data: bytes, encoding: forced.foundation) else { throw FileError.unsupported }
            return (text, forced)
        }
        for (signature, encoding) in [([UInt8](arrayLiteral: 0xEF, 0xBB, 0xBF), TextEncoding.utf8BOM), ([0xFF, 0xFE], .utf16LE), ([0xFE, 0xFF], .utf16BE)] {
            if data.starts(with: signature) {
                guard let text = String(data: data.dropFirst(signature.count), encoding: encoding.foundation) else { throw FileError.unsupported }
                return (text, encoding)
            }
        }
        if data.prefix(8192).contains(where: { $0 < 8 || ($0 > 13 && $0 < 27) }) { throw FileError.binary }
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8) }
        if let text = String(data: data, encoding: TextEncoding.gb18030.foundation) { return (text, .gb18030) }
        throw FileError.unsupported
    }
}

enum FileError: LocalizedError {
    case binary, unsupported, tooLarge, unrepresentable, changedOnDisk, invalidPlist
    var errorDescription: String? {
        switch self {
        case .binary: return tr("document.this_file_contains_binary_data_and_cannot_be_opened_as_text")
        case .unsupported: return tr("document.the_encoding_could_not_be_identified_utf_8_utf_16_and")
        case .tooLarge: return tr("document.text_files_up_to_32_mb_are_supported")
        case .unrepresentable: return tr("document.some_characters_cannot_be_saved_in_this_encoding_switch_to_utf")
        case .changedOnDisk: return tr("document.the_file_has_been_changed_by_another_application")
        case .invalidPlist: return tr("document.invalid_plist_content_check_the_xml_structure_and_value_types_the")
        }
    }
}

enum LineEnding: String, Codable, CaseIterable {
    case lf = "LF", crlf = "CRLF", cr = "CR", mixed = "Mixed"
    var sequence: String { self == .crlf ? "\r\n" : self == .cr ? "\r" : "\n" }
    var title: String { self == .mixed ? tr("document.mixed") : rawValue }
    static func detect(_ text: String) -> LineEnding {
        var lf = false, cr = false, crlf = false
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            if units[i] == 13 {
                if i + 1 < units.count && units[i + 1] == 10 { crlf = true; i += 1 } else { cr = true }
            } else if units[i] == 10 { lf = true }
            if (lf && cr) || (lf && crlf) || (cr && crlf) { return .mixed }
            i += 1
        }
        return crlf ? .crlf : cr ? .cr : .lf
    }
    func convert(_ text: String) -> String {
        guard self != .mixed else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: sequence)
    }
}

enum Syntax: String, Codable, CaseIterable {
    case plain, javascript, typescript, json, python, swift, html, css, markdown, shell, c
    case java, csharp, go, rust, php, ruby, lua, sql, yaml, toml, ini, dockerfile, makefile
    case xml, plist, kotlin, dart, perl, r, powershell, diff, graphql
    var title: String {
        switch self {
        case .plain: return tr("document.plain_text")
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .json: return "JSON"
        case .python: return "Python"
        case .swift: return "Swift"
        case .html: return "HTML"
        case .css: return "CSS"
        case .markdown: return "Markdown"
        case .shell: return "Shell"
        case .c: return "C / C++"
        case .java: return "Java"
        case .csharp: return "C#"
        case .go: return "Go"
        case .rust: return "Rust"
        case .php: return "PHP"
        case .ruby: return "Ruby"
        case .lua: return "Lua"
        case .sql: return "SQL"
        case .yaml: return "YAML"
        case .toml: return "TOML"
        case .ini: return "INI"
        case .dockerfile: return "Dockerfile"
        case .makefile: return "Makefile"
        case .xml: return "XML"
        case .plist: return "plist"
        case .kotlin: return "Kotlin"
        case .dart: return "Dart"
        case .perl: return "Perl"
        case .r: return "R"
        case .powershell: return "PowerShell"
        case .diff: return "Diff"
        case .graphql: return "GraphQL"
        }
    }
    static func detect(filename: String) -> Syntax {
        if filename.lowercased().hasPrefix("dockerfile") { return .dockerfile }
        if ["makefile", "gnumakefile"].contains(filename.lowercased()) { return .makefile }
        if [".gitignore", ".gitattributes", ".editorconfig", ".env"].contains(filename.lowercased()) || filename.lowercased().hasPrefix(".env.") { return .ini }
        switch (filename as NSString).pathExtension.lowercased() {
        case "js", "mjs", "cjs", "jsx": return .javascript
        case "ts", "tsx": return .typescript
        case "json", "jsonc": return .json
        case "py", "pyw": return .python
        case "swift": return .swift
        case "html", "htm", "xhtml", "vue", "svelte": return .html
        case "xml", "svg", "xsd", "xsl", "xslt", "rss", "atom", "xaml", "storyboard", "xib": return .xml
        case "plist", "stringsdict", "entitlements", "mobileconfig", "xcprivacy": return .plist
        case "css", "scss", "sass", "less": return .css
        case "md", "markdown", "mdown", "mkd": return .markdown
        case "sh", "zsh", "bash", "fish", "command": return .shell
        case "c", "h", "cpp", "cc", "hpp", "hxx", "cxx", "m", "mm": return .c
        case "java": return .java
        case "kt", "kts": return .kotlin
        case "dart": return .dart
        case "pl", "pm": return .perl
        case "r", "rscript": return .r
        case "ps1", "psm1", "psd1": return .powershell
        case "diff", "patch": return .diff
        case "graphql", "gql": return .graphql
        case "cs": return .csharp
        case "go": return .go
        case "rs": return .rust
        case "php": return .php
        case "rb": return .ruby
        case "lua": return .lua
        case "sql": return .sql
        case "yaml", "yml": return .yaml
        case "toml": return .toml
        case "ini", "conf", "cfg", "properties", "env", "editorconfig", "strings": return .ini
        default: return .plain
        }
    }
}

struct EditorDocument: Codable, Identifiable {
    var id = UUID()
    var url: URL?
    var content = ""
    var savedContent = ""
    var encoding: TextEncoding = .utf8
    var savedEncoding: TextEncoding = .utf8
    var syntax: Syntax = .plain
    var selectionLocation = 0
    var selectionLength = 0
    var scrollY: Double = 0
    var diskData: Data?
    var requiresSave = false
    var bookmarks: [Int]?
    var locked: Bool?
    var pinned: Bool?
    var preferredEnding: LineEnding?
    var plistFormat: PlistFormat?
    var savedPlistFormat: PlistFormat?
    var markdownView: MarkdownViewMode?
    var isDirty: Bool { requiresSave || content != savedContent || encoding != savedEncoding || plistFormat != savedPlistFormat }
    var title: String { url?.lastPathComponent ?? tr("document.untitled") }
    mutating func normalizeBookmarks() {
        guard let anchors = bookmarks else { return }
        let length = (content as NSString).length
        let valid = anchors.filter { $0 >= 0 && $0 <= length }
        if url == nil && content.isEmpty && valid.count != anchors.count {
            bookmarks = []
            return
        }
        let index = TextIndex(linesIn: content)
        bookmarks = Array(Set(valid.map { index.starts[index.line(at: $0)] })).sorted()
    }
    mutating func discardChanges() {
        if content != savedContent {
            bookmarks = url == nil && savedContent.isEmpty ? [] : TextTools.shiftedBookmarks(bookmarks ?? [], old: content, new: savedContent)
        }
        content = savedContent
        encoding = savedEncoding
        plistFormat = savedPlistFormat
        requiresSave = false
        normalizeBookmarks()
    }
    static func open(_ url: URL, encoding forced: TextEncoding? = nil) throws -> EditorDocument {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if (attributes[.size] as? NSNumber)?.intValue ?? 0 > 32 * 1024 * 1024 { throw FileError.tooLarge }
        let data = try Data(contentsOf: url)
        if data.starts(with: Data("bplist00".utf8)) {
            let text = try DocumentFormats.plistXML(from: data)
            guard text.utf8.count <= 32 * 1024 * 1024 else { throw FileError.tooLarge }
            return EditorDocument(url: url.standardizedFileURL, content: text, savedContent: text, syntax: .plist, diskData: data, plistFormat: .binary, savedPlistFormat: .binary)
        }
        let (text, encoding) = try TextEncoding.decode(data, as: forced)
        let syntax = Syntax.detect(filename: url.lastPathComponent)
        return EditorDocument(url: url.standardizedFileURL, content: text, savedContent: text, encoding: encoding, savedEncoding: encoding, syntax: syntax, diskData: data, plistFormat: syntax == .plist ? .xml : nil, savedPlistFormat: syntax == .plist ? .xml : nil)
    }
    func encodedContent() throws -> Data {
        if plistFormat == .binary {
            if savedPlistFormat == .binary, content == savedContent, let diskData = diskData { return diskData }
            return try DocumentFormats.plistData(from: content, format: .binary, original: savedPlistFormat == .binary ? diskData : nil, originalText: savedContent)
        }
        return try encoding.encode(content)
    }
    mutating func save(to destination: URL, overwrite: Bool = false) throws {
        if !overwrite, destination.standardizedFileURL == url?.standardizedFileURL, let previous = diskData,
           FileManager.default.fileExists(atPath: destination.path), try Data(contentsOf: destination) != previous { throw FileError.changedOnDisk }
        let data = try encodedContent()
        try data.write(to: destination, options: .atomic)
        let wasUntitled = url == nil
        url = destination.standardizedFileURL
        savedContent = content
        savedEncoding = encoding
        savedPlistFormat = plistFormat
        diskData = data
        requiresSave = false
        if wasUntitled { syntax = Syntax.detect(filename: destination.lastPathComponent) }
    }
}

struct EditorSession: Codable {
    var documents: [EditorDocument]
    var activeID: UUID?
    var folderURL: URL?
}

final class SessionStore {
    let url: URL
    let queue = DispatchQueue(label: "com.jamxi.editdot.recovery", qos: .utility)
    init(directory: URL? = nil) {
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("EditDot", isDirectory: true)
        url = directory.appendingPathComponent("session.json")
    }
    func load() -> EditorSession? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(EditorSession.self, from: data)
    }
    func save(_ session: EditorSession, completion: ((Error?) -> Void)? = nil) {
        queue.async {
            do {
                try FileManager.default.createDirectory(at: self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(session).write(to: self.url, options: .atomic)
                if let completion = completion { DispatchQueue.main.async { completion(nil) } }
            } catch {
                if let completion = completion { DispatchQueue.main.async { completion(error) } }
            }
        }
    }
    func flush() { queue.sync {} }
}

struct TextIndex {
    var starts: [Int] = [0]
    var characters = 0
    var ending: LineEnding = .lf
    init(_ text: String) {
        characters = text.count
        ending = LineEnding.detect(text)
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            if units[i] == 13 {
                if i + 1 < units.count && units[i + 1] == 10 { i += 1 }
                starts.append(i + 1)
            } else if [10, 0x85, 0x2028, 0x2029].contains(units[i]) { starts.append(i + 1) }
            i += 1
        }
    }
    init(linesIn text: String) {
        let source = text as NSString
        var location = 0
        var foundEnding = false
        while location < source.length {
            let range = source.lineRange(for: NSRange(location: location, length: 0))
            let end = NSMaxRange(range)
            if end > 0, [10, 13, 0x85, 0x2028, 0x2029].contains(source.character(at: end - 1)) {
                if !foundEnding, [10, 13].contains(source.character(at: end - 1)) { ending = source.character(at: end - 1) == 13 ? .cr : end > 1 && source.character(at: end - 2) == 13 ? .crlf : .lf; foundEnding = true }
                starts.append(end)
            }
            location = end
        }
    }
    func replacing(in old: String, with new: String, range: NSRange, replacement: String) -> TextIndex {
        let before = old as NSString, after = new as NSString
        let delta = (replacement as NSString).length - range.length
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= before.length,
              before.length + delta == after.length else { return TextIndex(linesIn: new) }
        let first = max(0, line(at: range.location) - 1)
        let last = min(starts.count - 1, line(at: NSMaxRange(range)) + 1)
        let start = starts[first], oldEnd = last + 1 < starts.count ? starts[last + 1] : before.length
        let end = oldEnd + delta
        guard start <= end, end <= after.length else { return TextIndex(linesIn: new) }
        let fragment = after.substring(with: NSRange(location: start, length: end - start))
        let local = TextIndex(linesIn: fragment)
        var result = self
        result.starts = Array(starts.prefix(first)) + local.starts.map { $0 + start } + starts.filter { $0 > oldEnd }.map { $0 + delta }
        return result
    }
    func line(at position: Int) -> Int {
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= position { low = middle + 1 } else { high = middle }
        }
        return max(0, low - 1)
    }
}

struct SearchResult {
    var matches: [NSTextCheckingResult] = []
    var expression: NSRegularExpression?
    var invalid = false
    var limited = false
    var timedOut = false
    static func find(_ query: String, in text: String, matchCase: Bool, regex: Bool, wholeWord: Bool = false, range: NSRange? = nil, timeout: Double = 0.25, cancelled: (() -> Bool)? = nil) -> SearchResult {
        guard !query.isEmpty else { return SearchResult() }
        let source = regex ? query : NSRegularExpression.escapedPattern(for: query)
        let pattern = wholeWord ? #"(?<![\p{L}\p{N}_])(?:"# + source + #")(?![\p{L}\p{N}_])"# : source
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if !matchCase { options.insert(.caseInsensitive) }
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return SearchResult(invalid: true) }
        var result = SearchResult(expression: expression)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        expression.enumerateMatches(in: text, options: [.reportProgress], range: range ?? NSRange(location: 0, length: (text as NSString).length)) { match, _, stop in
            if cancelled?() == true || ProcessInfo.processInfo.systemUptime > deadline { result.timedOut = true; result.limited = true; stop.pointee = true; return }
            if let match = match {
                if result.matches.count >= 10000 { result.limited = true; stop.pointee = true }
                else { result.matches.append(match) }
            }
        }
        return result
    }
}
