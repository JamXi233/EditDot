// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import AppKit

extension EditorController {
    func quickActionEntries() -> [PickerEntry] {
        var entries: [PickerEntry] = []
        let native = [#selector(NSText.cut(_:)), #selector(NSText.copy(_:)), #selector(NSText.paste(_:)), #selector(NSText.selectAll(_:)), #selector(EditorTextView.undo(_:)), #selector(EditorTextView.redo(_:))]
        func collect(_ menu: NSMenu, path: [String]) {
            for source in menu.items where !source.isSeparatorItem {
                if let submenu = source.submenu { collect(submenu, path: path + [source.title]); continue }
                let global = source.target is WorkspaceManager && source.target === workspaceHost?.manager
                guard let action = source.action, action != #selector(showQuickActions), source.target === self || global || native.contains(action) else { continue }
                let own = source.target === self
                if own && !validateMenuItem(source) { continue }
                let sender = NSMenuItem(title: source.title, action: action, keyEquivalent: "")
                sender.tag = source.tag; sender.representedObject = source.representedObject
                let modifiers = source.keyEquivalentModifierMask
                let shortcut = (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "") + (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "")
                let key = source.keyEquivalent == String(UnicodeScalar(NSF2FunctionKey)!) ? "F2" : source.keyEquivalent.uppercased()
                entries.append(PickerEntry(title: source.title, detail: path.joined(separator: " › "), shortcut: key.isEmpty ? "" : shortcut + key, keywords: NSStringFromSelector(action), action: { [weak self] in
                    guard let self = self else { return }
                    self.window?.makeKeyAndOrderFront(nil); self.window?.makeFirstResponder(self.textView)
                    if !own || self.validateMenuItem(sender) { NSApp.sendAction(action, to: global ? self.workspaceHost?.manager : own ? self : nil, from: sender) }
                }))
            }
        }
        collect(makeMainMenu(), path: [])
        return entries
    }
    @objc func showQuickActions() {
        presentPicker(title: tr("navigation.quick_actions"), prompt: tr("navigation.find_an_action"), entries: quickActionEntries())
    }
    func presentPicker(title: String, prompt: String, entries: [PickerEntry]) {
        quickPicker?.close()
        quickPicker = QuickPicker(title: title, prompt: prompt, entries: entries)
        quickPicker?.present(relativeTo: window)
    }
    @objc func showDocumentOutline() {
        let text = textView.string, document = activeDocument
        guard text.utf8.count <= 2 * 1024 * 1024 else {
            presentError(nil, operation: tr("navigation.document_is_too_large_for_an_outline"), detail: tr("navigation.outline_navigation_supports_documents_up_to_2_mb")); return
        }
        let symbols = DocumentOutline.symbols(in: text, syntax: document.syntax)
        let entries = symbols.map { symbol in
            PickerEntry(title: symbol.name, detail: symbol.kind + " · " + tr("navigation.line", symbol.line), action: { [weak self] in
                guard let self = self, self.documents.contains(where: { $0.id == document.id }) else { return }
                if self.activeID != document.id { self.activateDocument(document.id) }
                let source = self.textView.string as NSString
                guard NSMaxRange(symbol.range) <= source.length, source.substring(with: symbol.range) == symbol.name else { return }
                self.window?.makeKeyAndOrderFront(nil); self.window?.makeFirstResponder(self.textView)
                self.textView.setSelectedRange(symbol.range); self.textView.scrollRangeToVisible(symbol.range)
            })
        }
        presentPicker(title: tr("navigation.document_outline"), prompt: tr("navigation.find_a_heading_type_or_function"), entries: entries)
    }
}
