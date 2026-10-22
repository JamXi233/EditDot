// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import Foundation
import CoreFoundation

enum PlistFormat: String, Codable, CaseIterable {
    case xml, binary
    var title: String { self == .xml ? "XML plist" : tr("format.binary_plist") }
}

enum MarkdownViewMode: Int, Codable, CaseIterable {
    case source, split, preview
    var title: String {
        switch self {
        case .source: return tr("format.source")
        case .split: return tr("format.split_preview")
        case .preview: return tr("format.preview")
        }
    }
}

enum DocumentFormats {
    private static let declaration = try! NSRegularExpression(pattern: #"(?i)^(\s*<\?xml\b[^?]*\bencoding\s*=\s*)(["'])([^"']*)\2"#)
    static func xmlEncoding(in text: String) -> String? {
        guard let range = xmlEncodingRange(in: text) else { return nil }
        return (text as NSString).substring(with: range)
    }
    static func xmlEncodingRange(in text: String) -> NSRange? { declaration.firstMatch(in: text, range: NSRange(location: 0, length: min(512, (text as NSString).length)))?.range(at: 3) }
    static func xmlDeclaration(_ text: String, encoding: String) -> String {
        guard let match = declaration.firstMatch(in: text, range: NSRange(location: 0, length: min(512, (text as NSString).length))) else { return text }
        let value = NSMutableString(string: text); value.replaceCharacters(in: match.range(at: 3), with: encoding); return value as String
    }
    private static func xmlInput(_ text: String) -> Data { Data(xmlDeclaration(text, encoding: "UTF-8").utf8) }
    static func plistXML(from data: Data) throws -> String {
        guard let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let xml = try? PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0),
              let text = String(data: xml, encoding: .utf8) else { throw FileError.invalidPlist }
        return text
    }
    static func plistData(from text: String, format: PlistFormat, original: Data? = nil, originalText: String? = nil) throws -> Data {
        guard var value = try? PropertyListSerialization.propertyList(from: xmlInput(text), options: [], format: nil) else { throw FileError.invalidPlist }
        if format == .binary, let original = original, let originalText = originalText,
           let stored = try? PropertyListSerialization.propertyList(from: original, options: [], format: nil),
           let displayed = try? PropertyListSerialization.propertyList(from: xmlInput(originalText), options: [], format: nil) {
            value = preservingValues(stored, displayed: displayed, edited: value)
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: value, format: format == .binary ? .binary : .xml, options: 0) else { throw FileError.invalidPlist }
        return data
    }
    private static func preservingValues(_ stored: Any, displayed: Any, edited: Any) -> Any {
        // Preserve binary-only details in values that were not changed in the XML view.
        if sameValue(displayed, edited) { return stored }
        if let old = stored as? [String: Any], let before = displayed as? [String: Any], let after = edited as? [String: Any] {
            return after.reduce(into: [String: Any]()) { result, entry in
                if let original = old[entry.key], let shown = before[entry.key] { result[entry.key] = preservingValues(original, displayed: shown, edited: entry.value) }
                else { result[entry.key] = entry.value }
            }
        }
        if let old = stored as? [Any], let before = displayed as? [Any], let after = edited as? [Any] {
            if old.count == before.count && before.count == after.count { return after.indices.map { preservingValues(old[$0], displayed: before[$0], edited: after[$0]) } }
            var used = Set<Int>()
            return after.map { value -> Any in
                if let index = before.indices.first(where: { !used.contains($0) && $0 < old.count && sameValue(before[$0], value) }) { used.insert(index); return old[index] }
                return value
            }
        }
        return edited
    }
    private static func sameValue(_ first: Any, _ second: Any) -> Bool {
        guard CFGetTypeID(first as CFTypeRef) == CFGetTypeID(second as CFTypeRef) else { return false }
        if let first = first as? [String: Any], let second = second as? [String: Any] {
            return first.count == second.count && first.allSatisfy { key, value in second[key].map { sameValue(value, $0) } ?? false }
        }
        if let first = first as? [Any], let second = second as? [Any] { return first.count == second.count && zip(first, second).allSatisfy { sameValue($0, $1) } }
        if let first = first as? NSNumber, let second = second as? NSNumber {
            let floating: Set<String> = ["d", "f"]
            guard floating.contains(String(cString: first.objCType)) == floating.contains(String(cString: second.objCType)) else { return false }
            if first.doubleValue == 0 && second.doubleValue == 0 && first.doubleValue.sign != second.doubleValue.sign { return false }
        }
        return CFEqual(first as CFTypeRef, second as CFTypeRef)
    }
    static func formatted(_ text: String, syntax: Syntax) throws -> String {
        if syntax == .plist { return xmlDeclaration(try plistXML(from: xmlInput(text)), encoding: xmlEncoding(in: text) ?? "UTF-8") }
        if syntax == .json {
            let value = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        }
        if syntax == .xml {
            let document = try XMLDocument(xmlString: text, options: [.nodePreserveCDATA, .nodeLoadExternalEntitiesNever])
            return document.xmlString(options: [.nodePrettyPrint])
        }
        return text
    }
    static func validate(_ text: String, syntax: Syntax) throws {
        if syntax == .plist { _ = try plistData(from: text, format: .xml) }
        else if syntax == .json { _ = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) }
        else if syntax == .xml {
            let parser = XMLParser(data: xmlInput(text)); parser.shouldResolveExternalEntities = false
            guard parser.parse() else { throw parser.parserError ?? FileError.unsupported }
        }
    }
}
