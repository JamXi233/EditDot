// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import AppKit
import UniformTypeIdentifiers

struct AssociationResult {
    var changed: [String] = []
    var failures: [String: Error] = [:]
}

enum AssociationError: LocalizedError {
    case applicationUnavailable, typeUnavailable, previousUnavailable, verificationFailed
    var errorDescription: String? {
        switch self {
        case .applicationUnavailable: return tr("associations.install_editdot_in_applications_first")
        case .typeUnavailable: return tr("associations.this_extension_could_not_be_recognized")
        case .previousUnavailable: return tr("associations.the_previous_app_is_unavailable_choose_an_app_in_finder_s")
        case .verificationFailed: return tr("associations.the_system_did_not_change_the_default_app")
        }
    }
}

enum ExtensionCategory: String, CaseIterable {
    case all, text, documents, configuration, web, source, scripts, custom
    var title: String {
        switch self {
        case .all: return tr("associations.all_types")
        case .text: return tr("associations.text_data")
        case .documents: return tr("associations.documents_markup")
        case .configuration: return tr("associations.config_plist")
        case .web: return "Web"
        case .source: return tr("associations.source_code")
        case .scripts: return tr("associations.scripts")
        case .custom: return tr("associations.custom")
        }
    }
}

final class FileAssociations {
    static let groups: [(ExtensionCategory, [String])] = [
        (.text, ["txt", "text", "log", "csv", "tsv", "diff", "patch"]),
        (.documents, ["md", "markdown", "mdown", "mkd", "xml", "svg", "xsd", "xsl", "xslt", "rss", "atom"]),
        (.configuration, ["plist", "stringsdict", "entitlements", "mobileconfig", "xcprivacy", "strings", "json", "jsonc", "yaml", "yml", "toml", "ini", "conf", "cfg", "properties", "env", "editorconfig"]),
        (.web, ["html", "htm", "xhtml", "css", "scss", "sass", "less", "js", "mjs", "cjs", "jsx", "ts", "tsx", "vue", "svelte", "graphql", "gql"]),
        (.source, ["swift", "c", "h", "cpp", "cc", "cxx", "hpp", "hxx", "m", "mm", "java", "kt", "kts", "cs", "go", "rs", "dart", "sql", "xaml", "storyboard", "xib"]),
        (.scripts, ["py", "pyw", "rb", "php", "lua", "sh", "bash", "zsh", "fish", "command", "ps1", "psm1", "psd1", "pl", "pm", "r", "rscript"])
    ]
    static let common = groups.flatMap { $0.1 }
    static func category(for ext: String) -> ExtensionCategory { groups.first { $0.1.contains(ext) }?.0 ?? .custom }
    let defaults: UserDefaults
    let applicationURL: URL
    let readHandler: (UTType) -> URL?
    let writeHandler: (URL, UTType, @escaping (Error?) -> Void) -> Void
    private(set) var isApplying = false
    var extensions: [String] { Self.common + customExtensions.filter { !Self.common.contains($0) } }
    var customExtensions: [String] { (defaults.stringArray(forKey: "fileAssociationExtensions") ?? []).compactMap(Self.normalizedExtension).reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
    var previousHandlers: [String: String] { defaults.dictionary(forKey: "fileAssociationPreviousHandlers") as? [String: String] ?? [:] }

    init(defaults: UserDefaults = .standard, applicationURL: URL = URL(fileURLWithPath: "/Applications/EditDot.app"),
         readHandler: @escaping (UTType) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) },
         writeHandler: @escaping (URL, UTType, @escaping (Error?) -> Void) -> Void = { NSWorkspace.shared.setDefaultApplication(at: $0, toOpen: $1, completion: $2) }) {
        self.defaults = defaults; self.applicationURL = applicationURL
        self.readHandler = readHandler; self.writeHandler = writeHandler
    }
    static func normalizedExtension(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix(".") { value.removeFirst() }
        guard value.range(of: #"^[a-z0-9][a-z0-9_+\-]{0,31}$"#, options: .regularExpression) != nil else { return nil }
        return value
    }
    func contentType(for ext: String) -> UTType? {
        let types = UTType.types(tag: ext, tagClass: .filenameExtension, conformingTo: nil)
        return types.first { !$0.isDynamic && $0.conforms(to: .text) } ?? UTType(filenameExtension: ext)
    }
    @discardableResult func add(_ input: String) -> Bool {
        guard let ext = Self.normalizedExtension(input) else { return false }
        if !extensions.contains(ext) { defaults.set(customExtensions + [ext], forKey: "fileAssociationExtensions") }
        return true
    }
    func remove(_ ext: String) { defaults.set(customExtensions.filter { $0 != ext }, forKey: "fileAssociationExtensions") }
    func currentApplication(for ext: String) -> URL? { contentType(for: ext).flatMap(readHandler) }
    func canRestore(_ ext: String) -> Bool { contentType(for: ext).flatMap { previousHandlers[$0.identifier] } != nil }
    static func sameApplication(_ first: URL?, _ second: URL) -> Bool {
        guard let first = first else { return false }
        if first.standardizedFileURL.resolvingSymlinksInPath() == second.standardizedFileURL.resolvingSymlinksInPath() { return true }
        guard let identifier = Bundle(url: second)?.bundleIdentifier else { return false }
        return Bundle(url: first)?.bundleIdentifier == identifier
    }
    func apply(_ extensions: [String], restoring: Bool = false, completion: @escaping (AssociationResult) -> Void) {
        guard !isApplying else { return }
        guard Bundle(url: applicationURL)?.bundleIdentifier == "cn.jamsg.editdot" else {
            completion(AssociationResult(failures: Dictionary(uniqueKeysWithValues: Set(extensions).map { ($0, AssociationError.applicationUnavailable as Error) }))); return
        }
        isApplying = true
        var result = AssociationResult(), types: [(UTType, [String])] = []
        for ext in Set(extensions).sorted() {
            guard let type = contentType(for: ext) else { result.failures[ext] = AssociationError.typeUnavailable; continue }
            if let index = types.firstIndex(where: { $0.0 == type }) { types[index].1.append(ext) }
            else { types.append((type, [ext])) }
        }
        func next(_ index: Int) {
            guard index < types.count else { isApplying = false; completion(result); return }
            let (type, names) = types[index]
            let previous = readHandler(type)
            let target: URL
            if restoring {
                guard let path = previousHandlers[type.identifier], Bundle(url: URL(fileURLWithPath: path)) != nil else {
                    for name in names { result.failures[name] = AssociationError.previousUnavailable }; next(index + 1); return
                }
                target = URL(fileURLWithPath: path)
            } else { target = applicationURL }
            if Self.sameApplication(previous, target) { result.changed += names; next(index + 1); return }
            writeHandler(target, type) { error in
                DispatchQueue.main.async {
                    let failure = error ?? (Self.sameApplication(self.readHandler(type), target) ? nil : AssociationError.verificationFailed)
                    if let failure = failure { for name in names { result.failures[name] = failure } }
                    else {
                        result.changed += names
                        var backups = self.previousHandlers
                        if restoring { backups.removeValue(forKey: type.identifier) }
                        else if backups[type.identifier] == nil, let previous = previous { backups[type.identifier] = previous.path }
                        self.defaults.set(backups, forKey: "fileAssociationPreviousHandlers")
                    }
                    next(index + 1)
                }
            }
        }
        next(0)
    }
}
