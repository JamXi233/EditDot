#!/usr/bin/env swift
// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Sources/EditDot/Resources")
let strict = CommandLine.arguments.contains("--strict")
var failures: [String] = []
func fail(_ message: String) { failures.append(message) }
func matches(_ pattern: String, _ text: String) -> [NSTextCheckingResult] {
    (try! NSRegularExpression(pattern: pattern)).matches(in: text, range: NSRange(text.startIndex..., in: text))
}
func signature(_ text: String) -> [Int: String]? {
    let expression = try! NSRegularExpression(pattern: #"%%|%([1-9][0-9]*)\$(@|ld)"#)
    let value = text as NSString
    var result: [Int: String] = [:]
    let found = expression.matches(in: text, range: NSRange(location: 0, length: value.length))
    let stripped = expression.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: value.length), withTemplate: "")
    guard !stripped.contains("%") else { return nil }
    for item in found where item.range(at: 1).location != NSNotFound {
        guard let index = Int(value.substring(with: item.range(at: 1))), index <= 64 else { return nil }
        let type = value.substring(with: item.range(at: 2))
        if let previous = result[index], previous != type { return nil }
        result[index] = type
    }
    return result
}
let folders = ((try? FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "lproj" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
var tables: [String: [String: String]] = [:]
for folder in folders {
    let code = folder.deletingPathExtension().lastPathComponent
    guard code.range(of: #"^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil else { fail("Invalid language identifier: \(code)"); continue }
    do {
        let file = folder.appendingPathComponent("Localizable.strings")
        let data = try Data(contentsOf: file)
        guard let table = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: String],
              let source = String(data: data, encoding: .utf8) else { fail("\(code): expected a UTF-8 strings dictionary"); continue }
        let declarations = matches(#"(?m)^\s*\"([a-z0-9._]+)\"\s*="#, source)
        var keys = Set<String>()
        for entry in declarations {
            let key = (source as NSString).substring(with: entry.range(at: 1))
            if !keys.insert(key).inserted { fail("\(code): duplicate key \(key)") }
        }
        if keys != Set(table.keys) { fail("\(code): use one quoted, stable key per line") }
        if table["language.name"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { fail("\(code): language.name must contain the language's own name") }
        tables[code] = table
    } catch { fail("\(code): \(error.localizedDescription)") }
}
if let english = tables["en"], !english.isEmpty {
    var referenced = Set(["language.name"])
    let files = (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Sources/EditDot"), includingPropertiesForKeys: nil)) ?? []
    for file in files where file.pathExtension == "swift" {
        let text = (try? String(contentsOf: file)) ?? ""
        for call in matches(#"\btr\(\s*\"([a-z0-9._]+)\""#, text) { referenced.insert((text as NSString).substring(with: call.range(at: 1))) }
    }
    for key in referenced.subtracting(english.keys).sorted() { fail("en: missing referenced key \(key)") }
    for key in Set(english.keys).subtracting(referenced).sorted() { fail("en: unused key \(key)") }
    for (key, value) in english {
        guard let fields = signature(value) else { fail("en: invalid placeholders in \(key)"); continue }
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fail("en: empty value for \(key)") }
        if let maximum = fields.keys.max(), Set(fields.keys) != Set(1...maximum) { fail("en: skipped argument number in \(key)") }
    }
    for (code, table) in tables.sorted(by: { $0.key < $1.key }) {
        for key in Set(table.keys).subtracting(english.keys).sorted() { fail("\(code): unknown key \(key)") }
        var missing = Set(english.keys).subtracting(table.keys)
        for (key, value) in table {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.insert(key); continue }
            if signature(value) == nil || signature(value) != signature(english[key] ?? "") { fail("\(code): placeholders do not match English in \(key)") }
        }
        if !missing.isEmpty {
            let message = "\(code): \(missing.count) untranslated entries use English"
            if strict { fail(message) } else { print("Warning: \(message)") }
        }
        print("\(code): \(table.count) entries checked")
    }
} else { fail("The English catalog is missing or invalid") }
if !failures.isEmpty {
    for message in failures { fputs("Error: \(message)\n", stderr) }
    exit(1)
}
print("Localization checks passed")
