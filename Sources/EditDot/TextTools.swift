// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import Foundation

struct TextChange {
    var range: NSRange
    var text: String
}

enum TextTool: Int, CaseIterable {
    case uppercase, lowercase, trimTrailing, removeEmpty, sortAscending, sortDescending, uniqueLines
    case indent, outdent, duplicate, deleteLine, moveUp, moveDown, comment, tabsToSpaces, spacesToTabs, formatJSON, compactJSON
    case joinLines, reverseLines, encodeBase64, decodeBase64, encodeURL, decodeURL, quoteJSON, unquoteJSON
    var title: String {
        switch self {
        case .uppercase: return tr("text.use_capital_letters")
        case .lowercase: return tr("text.use_small_letters")
        case .trimTrailing: return tr("text.clean_line_tails")
        case .removeEmpty: return tr("text.drop_blank_rows")
        case .sortAscending: return tr("text.natural_order")
        case .sortDescending: return tr("text.reverse_order")
        case .uniqueLines: return tr("text.keep_one_of_each_line")
        case .indent: return tr("text.indent")
        case .outdent: return tr("text.unindent")
        case .duplicate: return tr("text.copy_lines_below")
        case .deleteLine: return tr("text.remove_these_lines")
        case .moveUp: return tr("text.shift_one_line_up")
        case .moveDown: return tr("text.shift_one_line_down")
        case .comment: return tr("text.comment_or_restore_lines")
        case .tabsToSpaces: return tr("text.expand_tabs_into_spaces")
        case .spacesToTabs: return tr("text.pack_indentation_into_tabs")
        case .formatJSON: return tr("text.expand_json_layout")
        case .compactJSON: return tr("text.condense_json_layout")
        case .joinLines: return tr("text.join_rows_into_one")
        case .reverseLines: return tr("text.flip_row_order")
        case .encodeBase64: return tr("text.convert_to_base64")
        case .decodeBase64: return tr("text.restore_from_base64")
        case .encodeURL: return tr("text.encode_url_component")
        case .decodeURL: return tr("text.decode_url_component")
        case .quoteJSON: return tr("text.create_json_string")
        case .unquoteJSON: return tr("text.read_json_string")
        }
    }
    var operatesOnCurrentLine: Bool { [.indent, .outdent, .duplicate, .deleteLine, .moveUp, .moveDown, .comment].contains(self) }
}

enum TextTools {
    static func completionWords(in text: String) -> [String] {
        guard text.utf8.count <= 512 * 1024 else { return [] }
        var words = Set("class struct enum func function let var const import return if else for while switch case break continue try catch throw async await public private static final guard self true false null nil def in with lambda yield SELECT FROM WHERE JOIN INSERT UPDATE DELETE CREATE TABLE GROUP ORDER LIMIT".components(separatedBy: " "))
        let expression = try! NSRegularExpression(pattern: #"[\p{L}_][\p{L}\p{N}_]{2,}"#)
        let source = text as NSString
        expression.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, stop in
            if words.count >= 5000 { stop.pointee = true; return }
            if let range = match?.range { words.insert(source.substring(with: range)) }
        }
        return words.sorted()
    }
    struct Line { var body: String; var ending: String }
    static func lines(_ text: String) -> [Line] {
        let source = text as NSString
        if source.length == 0 { return [Line(body: "", ending: "")] }
        var result: [Line] = [], location = 0
        while location < source.length {
            var start = 0, end = 0, contentsEnd = 0
            source.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            result.append(Line(body: source.substring(with: NSRange(location: start, length: contentsEnd - start)), ending: source.substring(with: NSRange(location: contentsEnd, length: end - contentsEnd))))
            location = end
        }
        return result
    }
    static func lineRange(_ selection: NSRange, in source: NSString) -> NSRange {
        let start = source.lineRange(for: NSRange(location: min(selection.location, source.length), length: 0)).location
        let end = NSMaxRange(source.lineRange(for: NSRange(location: min(source.length, max(selection.location, NSMaxRange(selection) - 1)), length: 0)))
        return NSRange(location: start, length: end - start)
    }
    static func duplicateLines(in text: String, selection: NSRange, fallbackEnding: String? = nil) -> (change: TextChange, selection: NSRange) {
        let source = text as NSString, range = lineRange(selection, in: source)
        let input = source.substring(with: range)
        let rows = lines(input)
        let ending = rows.last?.ending ?? ""
        let separator: String
        if !ending.isEmpty { separator = "" }
        else {
            let preceding = source.substring(to: range.location)
            separator = lines(preceding).last(where: { !$0.ending.isEmpty })?.ending ?? fallbackEnding ?? LineEnding.detect(text).sequence
        }
        let location = NSMaxRange(range)
        let copiedStart = location + (separator as NSString).length
        return (TextChange(range: NSRange(location: location, length: 0), text: separator + input),
                NSRange(location: copiedStart + selection.location - range.location, length: selection.length))
    }
    static func change(_ tool: TextTool, text: String, selection: NSRange, syntax: Syntax, width: Int, tabs: Bool) throws -> TextChange {
        let source = text as NSString, newline = LineEnding.detect(text).sequence
        let lineTools: [TextTool] = [.trimTrailing, .removeEmpty, .sortAscending, .sortDescending, .uniqueLines, .spacesToTabs, .joinLines, .reverseLines]
        let full = NSRange(location: 0, length: source.length)
        let range = tool.operatesOnCurrentLine || (selection.length > 0 && lineTools.contains(tool)) ? lineRange(selection, in: source) : selection.length > 0 ? selection : full
        let input = source.substring(with: range)
        var rows = lines(input)
        let unit = tabs ? "\t" : String(repeating: " ", count: width)
        switch tool {
        case .encodeBase64, .decodeBase64, .encodeURL, .decodeURL, .quoteJSON, .unquoteJSON:
            return TextChange(range: range, text: try TextConversions.apply(tool, to: input))
        case .joinLines:
            let bodies = rows.enumerated().map { index, row in index == 0 ? row.body.replacingOccurrences(of: #"[\t ]+$"#, with: "", options: .regularExpression) : row.body.trimmingCharacters(in: .whitespaces) }
            return TextChange(range: range, text: bodies.joined(separator: " ") + (rows.last?.ending ?? ""))
        case .reverseLines:
            let bodies = rows.map(\.body).reversed()
            for (index, body) in zip(rows.indices, bodies) { rows[index].body = body }
        case .uppercase: return TextChange(range: range, text: input.uppercased())
        case .lowercase: return TextChange(range: range, text: input.lowercased())
        case .duplicate:
            return duplicateLines(in: text, selection: selection).change
        case .deleteLine: return TextChange(range: range, text: "")
        case .moveUp:
            guard range.location > 0 else { return TextChange(range: range, text: input) }
            let previous = source.lineRange(for: NSRange(location: range.location - 1, length: 0))
            let priorText = source.substring(with: previous)
            let separated = input.hasSuffix("\n") || input.hasSuffix("\r")
            return TextChange(range: NSRange(location: previous.location, length: previous.length + range.length), text: separated ? input + priorText : input + newline + String(priorText.dropLast()))
        case .moveDown:
            guard NSMaxRange(range) < source.length else { return TextChange(range: range, text: input) }
            let next = source.lineRange(for: NSRange(location: NSMaxRange(range), length: 0))
            let following = source.substring(with: next)
            let separated = following.hasSuffix("\n") || following.hasSuffix("\r")
            return TextChange(range: NSRange(location: range.location, length: range.length + next.length), text: separated ? following + input : following + newline + String(input.dropLast()))
        case .formatJSON, .compactJSON:
            let object = try JSONSerialization.jsonObject(with: Data(input.utf8), options: [.fragmentsAllowed])
            let options: JSONSerialization.WritingOptions = tool == .formatJSON ? [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes] : [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
            let data = try JSONSerialization.data(withJSONObject: object, options: options)
            let formatted = String(decoding: data, as: UTF8.self)
            return TextChange(range: range, text: LineEnding.detect(text).convert(formatted) + (input.hasSuffix("\n") || input.hasSuffix("\r") ? newline : ""))
        case .sortAscending, .sortDescending:
            let bodies = rows.map(\.body).sorted { tool == .sortAscending ? $0.localizedStandardCompare($1) == .orderedAscending : $0.localizedStandardCompare($1) == .orderedDescending }
            for index in rows.indices { rows[index].body = bodies[index] }
        case .uniqueLines, .removeEmpty:
            var seen = Set<String>()
            let trailing = rows.last?.ending ?? ""
            rows = rows.filter { tool == .removeEmpty ? !$0.body.trimmingCharacters(in: .whitespaces).isEmpty : seen.insert($0.body).inserted }
            if !rows.isEmpty { for index in rows.indices { rows[index].ending = index == rows.count - 1 ? trailing : (rows[index].ending.isEmpty ? newline : rows[index].ending) } }
        case .comment:
            let prefix: String
            switch syntax {
            case .python, .shell, .ruby, .yaml, .toml, .dockerfile, .makefile, .perl, .r, .powershell, .graphql: prefix = "#"
            case .sql, .lua: prefix = "--"
            case .ini: prefix = ";"
            case .html, .markdown, .xml, .plist:
                let finalEnding = rows.last?.ending ?? ""
                let block = finalEnding.isEmpty ? input : String(input.dropLast())
                let indent = String(block.prefix { $0 == " " || $0 == "\t" })
                let body = String(block.dropFirst(indent.count))
                if body.hasPrefix("<!--"), body.hasSuffix("-->") {
                    var rest = String(body.dropFirst(4).dropLast(3))
                    if rest.hasPrefix(" ") { rest.removeFirst() }
                    if rest.hasSuffix(" ") { rest.removeLast() }
                    return TextChange(range: range, text: indent + rest + finalEnding)
                }
                return TextChange(range: range, text: indent + "<!-- " + body + " -->" + finalEnding)
            default: prefix = "//"
            }
            let nonempty = rows.filter { !$0.body.trimmingCharacters(in: .whitespaces).isEmpty }
            let remove = !nonempty.isEmpty && nonempty.allSatisfy { $0.body.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) }
            for index in rows.indices {
                let indent = String(rows[index].body.prefix { $0 == " " || $0 == "\t" })
                let body = String(rows[index].body.dropFirst(indent.count))
                if body.isEmpty { continue }
                if remove { var rest = String(body.dropFirst(prefix.count)); if rest.hasPrefix(" ") { rest.removeFirst() }; rows[index].body = indent + rest }
                else { rows[index].body = indent + prefix + " " + body }
            }
        default:
            for index in rows.indices {
                switch tool {
                case .trimTrailing: rows[index].body = rows[index].body.replacingOccurrences(of: #"[\t ]+$"#, with: "", options: .regularExpression)
                case .indent: rows[index].body = unit + rows[index].body
                case .outdent:
                    if rows[index].body.hasPrefix("\t") { rows[index].body.removeFirst() }
                    else { rows[index].body.removeFirst(min(width, rows[index].body.prefix { $0 == " " }.count)) }
                case .tabsToSpaces:
                    var column = 0, body = ""
                    for character in rows[index].body {
                        if character == "\t" { let spaces = width - column % width; body += String(repeating: " ", count: spaces); column += spaces }
                        else { body.append(character); column += 1 }
                    }
                    rows[index].body = body
                case .spacesToTabs:
                    let spaces = rows[index].body.prefix { $0 == " " }.count
                    rows[index].body = String(repeating: "\t", count: spaces / width) + String(repeating: " ", count: spaces % width) + rows[index].body.dropFirst(spaces)
                default: break
                }
            }
        }
        return TextChange(range: range, text: rows.map { $0.body + $0.ending }.joined())
    }
    static func shiftedBookmarks(_ anchors: [Int], old: String, new: String, edit: TextChange? = nil) -> [Int] {
        let source = old as NSString, target = new as NSString
        let length = target.length
        var start: Int, end: Int
        if let edit = edit, edit.range.location >= 0, edit.range.length >= 0,
           edit.range.location <= source.length, edit.range.length <= source.length - edit.range.location,
           source.replacingCharacters(in: edit.range, with: edit.text) == new {
            start = edit.range.location; end = NSMaxRange(edit.range)
        } else {
            let before = Array(old.utf16), after = Array(new.utf16)
            var prefix = 0, suffix = 0
            while prefix < min(before.count, after.count) && before[prefix] == after[prefix] { prefix += 1 }
            while suffix < min(before.count, after.count) - prefix && before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
            start = prefix; end = before.count - suffix
        }
        let index = TextIndex(new), delta = length - source.length
        return Array(Set(anchors.map { anchor in
            // Appending to a marked empty row leaves the mark on that row.
            let staysOnEmptyTail = anchor == source.length && start == source.length && end == source.length
            let completesCRLF = staysOnEmptyTail && source.length > 0 && length > source.length && source.character(at: source.length - 1) == 13 && target.character(at: source.length) == 10
            let position = staysOnEmptyTail ? anchor + (completesCRLF ? 1 : 0) : anchor < start ? anchor : anchor >= end ? anchor + delta : start
            return index.starts[index.line(at: max(0, min(length, position)))]
        })).sorted()
    }
    static func expandEscapes(_ text: String) -> String {
        var output = "", escaping = false
        for character in text {
            if escaping { output += character == "n" ? "\n" : character == "r" ? "\r" : character == "t" ? "\t" : character == "\\" ? "\\" : "\\" + String(character); escaping = false }
            else if character == "\\" { escaping = true }
            else { output.append(character) }
        }
        if escaping { output += "\\" }
        return output
    }
    static func columnChange(text: String, selection: NSRange, column: Int, length: Int, value: String, firstNumber: Int? = nil) -> TextChange {
        let source = text as NSString, range = lineRange(selection, in: source)
        var rows = lines(source.substring(with: range))
        for index in rows.indices {
            var characters = Array(rows[index].body)
            if characters.count < column { characters += Array(repeating: " ", count: column - characters.count) }
            let end = min(characters.count, column + length)
            let insertion = firstNumber.map { value + String($0 + index) } ?? value
            characters.replaceSubrange(column..<end, with: Array(insertion))
            rows[index].body = String(characters)
        }
        return TextChange(range: range, text: rows.map { $0.body + $0.ending }.joined())
    }
    static func bracketPair(in text: String, at caret: Int) -> [NSRange] {
        guard text.utf8.count <= 1024 * 1024 else { return [] }
        let units = Array(text.utf16), pairs: [UInt16: UInt16] = [41: 40, 93: 91, 125: 123]
        var stack: [(UInt16, Int)] = [], quote: UInt16? = nil, escaped = false, comment = false
        var index = 0
        while index < units.count {
            let character = units[index]
            if comment { if character == 10 || character == 13 { comment = false }; index += 1; continue }
            if let current = quote {
                if escaped { escaped = false }
                else if character == 92 { escaped = true }
                else if character == current { quote = nil }
            } else if character == 34 || character == 39 || character == 96 { quote = character }
            else if character == 47, index + 1 < units.count, units[index + 1] == 47 { comment = true }
            else if [40, 91, 123].contains(character) { stack.append((character, index)) }
            else if let open = pairs[character], let top = stack.last {
                if top.0 == open {
                    stack.removeLast()
                    if [caret, caret - 1].contains(top.1) || [caret, caret - 1].contains(index) { return [NSRange(location: top.1, length: 1), NSRange(location: index, length: 1)] }
                } else { stack.removeAll() }
            }
            index += 1
        }
        return []
    }
}

struct MacroEdit: Codable {
    var offset: Int
    var length: Int
    var text: String
}
