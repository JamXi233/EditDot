// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import Foundation

final class LocalizationCatalog {
    static let shared = LocalizationCatalog(directory: resourceDirectory)
    private let tables: [String: [String: String]]
    private let formats: [String: [Int: String]]
    var codes: [String] { tables.keys.sorted() }

    private static var resourceDirectory: URL {
        if let directory = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: directory.appendingPathComponent("en.lproj/Localizable.strings").path) {
            return directory
        }
        if let url = Bundle.main.resourceURL?.appendingPathComponent("EditDot_EditDot.bundle"),
           let bundle = Bundle(url: url), let directory = bundle.resourceURL {
            return directory
        }
        #if SWIFT_PACKAGE
        return Bundle.module.resourceURL!
        #else
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/EditDot/Resources")
        #endif
    }

    init(directory: URL) {
        let directories = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var loaded: [String: [String: String]] = [:]
        for folder in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where folder.pathExtension == "lproj" {
            let file = folder.appendingPathComponent("Localizable.strings")
            guard let data = try? Data(contentsOf: file),
                  let dictionary = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: String] else { continue }
            loaded[Self.canonicalCode(folder.deletingPathExtension().lastPathComponent)] = dictionary
        }
        let english = loaded["en"] ?? [:]
        formats = english.mapValues { Self.placeholders(in: $0) ?? [:] }
        tables = loaded.mapValues { table in
            table.filter { key, value in
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let reference = english[key] else { return false }
                return Self.placeholders(in: value) == Self.placeholders(in: reference)
            }
        }
    }

    static func canonicalCode(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").split(separator: "-").enumerated().map { index, part in
            if index == 0 { return part.lowercased() }
            return part.count == 4 ? part.prefix(1).uppercased() + part.dropFirst().lowercased() : part.uppercased()
        }.joined(separator: "-")
    }

    static func placeholders(in value: String) -> [Int: String]? {
        let bytes = Array(value.utf8)
        var result: [Int: String] = [:], offset = 0
        while offset < bytes.count {
            guard bytes[offset] == 37 else { offset += 1; continue }
            offset += 1
            if offset < bytes.count, bytes[offset] == 37 { offset += 1; continue }
            let start = offset
            while offset < bytes.count, (48...57).contains(bytes[offset]) { offset += 1 }
            guard offset > start, let index = Int(String(decoding: bytes[start..<offset], as: UTF8.self)),
                  (1...64).contains(index), offset < bytes.count, bytes[offset] == 36 else { return nil }
            offset += 1
            let type: String
            if offset < bytes.count, bytes[offset] == 64 { type = "@"; offset += 1 }
            else if offset + 1 < bytes.count, bytes[offset] == 108, bytes[offset + 1] == 100 { type = "ld"; offset += 2 }
            else { return nil }
            if let existing = result[index], existing != type { return nil }
            result[index] = type
        }
        return result
    }

    func name(for code: String) -> String {
        tables[code]?["language.name"] ?? Locale(identifier: code).localizedString(forIdentifier: code) ?? code
    }

    func text(_ key: String, language: String, arguments: [CVarArg] = []) -> String {
        let english = tables["en"]?[key] ?? key
        let value = tables[language]?[key] ?? english
        guard !arguments.isEmpty else { return value.replacingOccurrences(of: "%%", with: "%") }
        guard let signature = formats[key], signature.keys.max() == arguments.count else { return english }
        for (position, type) in signature {
            let argument = arguments[position - 1]
            guard type == "@" ? argument is String || argument is NSString : argument is Int else { return english }
        }
        return String(format: value, arguments: arguments)
    }
}

struct Language: RawRepresentable, Codable, Hashable {
    let rawValue: String
    static let chinese = Language(identifier: "zh-Hans")
    static let english = Language(identifier: "en")
    private static let lock = NSLock()
    private static var selected = resolved(saved: UserDefaults.standard.string(forKey: "language"), preferences: Locale.preferredLanguages)

    private init(identifier: String) { rawValue = identifier }
    init?(rawValue: String) {
        let code = LocalizationCatalog.canonicalCode(rawValue)
        guard LocalizationCatalog.shared.codes.contains(code) else { return nil }
        self.init(identifier: code)
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let identifier = try container.decode(String.self)
        guard let language = Language(rawValue: identifier) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported language identifier")
        }
        self = language
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    static var available: [Language] { available(in: .shared) }
    static func available(in catalog: LocalizationCatalog) -> [Language] {
        let order = ["zh-Hans", "en"]
        return catalog.codes.map { Language(identifier: $0) }.sorted {
            let first = order.firstIndex(of: $0.rawValue) ?? 2, second = order.firstIndex(of: $1.rawValue) ?? 2
            return first == second ? $0.rawValue < $1.rawValue : first < second
        }
    }
    static func resolved(saved: String?, preferences: [String], catalog: LocalizationCatalog = .shared) -> Language {
        let codes = catalog.codes
        if let saved = saved {
            let code = LocalizationCatalog.canonicalCode(saved)
            if codes.contains(code) { return Language(identifier: code) }
        }
        let candidates = ["en"] + codes.filter { $0 != "en" }
        let code = Bundle.preferredLocalizations(from: candidates, forPreferences: preferences).first ?? "en"
        return Language(identifier: codes.contains(code) ? code : "en")
    }
    static var current: Language {
        get { lock.lock(); defer { lock.unlock() }; return selected }
        set { lock.lock(); defer { lock.unlock() }; selected = newValue }
    }
    var title: String { LocalizationCatalog.shared.name(for: rawValue) }
}

func tr(_ key: String, _ arguments: CVarArg...) -> String {
    LocalizationCatalog.shared.text(key, language: Language.current.rawValue, arguments: arguments)
}
