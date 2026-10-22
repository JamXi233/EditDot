// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import AppKit

final class CommandToolbarItem: NSToolbarItem {
    var refresh: ((CommandToolbarItem) -> Void)?
    override func validate() { refresh?(self) }
}

extension EditorController {
    struct ToolbarCommand {
        var symbol: String
        var title: String
        var keys: String
        var action: Selector
    }
    var toolbarCommands: [String: ToolbarCommand] {
        if cachedToolbarLanguage == Language.current { return cachedToolbarCommands }
        let commands = [
            "new": ToolbarCommand(symbol: "doc.badge.plus", title: tr("common.new"), keys: "⌘N", action: #selector(newDocument)),
            "open": ToolbarCommand(symbol: "folder", title: tr("common.open"), keys: "⌘O", action: #selector(openDocuments)),
            "save": ToolbarCommand(symbol: "square.and.arrow.down", title: tr("common.save"), keys: "⌘S", action: #selector(saveDocument)),
            "saveAll": ToolbarCommand(symbol: "square.and.arrow.down.on.square", title: tr("common.save_all"), keys: "⌥⌘S", action: #selector(saveAll)),
            "undo": ToolbarCommand(symbol: "arrow.uturn.backward", title: tr("common.undo"), keys: "⌘Z", action: #selector(undoFromToolbar)),
            "redo": ToolbarCommand(symbol: "arrow.uturn.forward", title: tr("common.redo"), keys: "⇧⌘Z", action: #selector(redoFromToolbar)),
            "find": ToolbarCommand(symbol: "magnifyingglass", title: tr("common.find_and_replace"), keys: "⌘F", action: #selector(showFind)),
            "split": ToolbarCommand(symbol: "rectangle.split.2x1", title: tr("common.twin_editing"), keys: "⌥⌘\\", action: #selector(toggleSplitEditor))
        ]
        cachedToolbarLanguage = Language.current; cachedToolbarCommands = commands
        return commands
    }
    func makeActionToolbarItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        guard let command = toolbarCommands[identifier.rawValue] else { return nil }
        let item = CommandToolbarItem(itemIdentifier: identifier)
        item.target = self; item.action = command.action
        item.view = symbolButton(command.symbol, tooltip: command.title, target: self, action: command.action)
        item.autovalidates = false
        item.menuFormRepresentation = self.item(command.title, command.action)
        item.visibilityPriority = ["open", "save", "find"].contains(identifier.rawValue) ? .high : ["saveAll", "split"].contains(identifier.rawValue) ? .low : .standard
        item.refresh = { [weak self] item in self?.refreshToolbarItem(item) }
        refreshToolbarItem(item)
        return item
    }
    var toolbarTextEditor: NSTextView { (window?.firstResponder as? NSTextView) ?? textView }
    func toolbarEnabled(_ identifier: String) -> Bool {
        switch identifier {
        case "save": return activeDocument.isDirty || activeDocument.url == nil
        case "saveAll": return (workspaceHost?.manager?.windows.flatMap(\.groups).flatMap(\.documents) ?? documents).contains(where: \.isDirty)
        case "undo": return toolbarTextEditor.isEditable && toolbarTextEditor.undoManager?.canUndo == true
        case "redo": return toolbarTextEditor.isEditable && toolbarTextEditor.undoManager?.canRedo == true
        default: return true
        }
    }
    func refreshToolbarItem(_ item: NSToolbarItem) {
        guard !documents.isEmpty, let command = toolbarCommands[item.itemIdentifier.rawValue] else { return }
        let tooltip = command.title + " " + command.keys
        item.label = command.title; item.paletteLabel = command.title; item.toolTip = tooltip
        item.isEnabled = toolbarEnabled(item.itemIdentifier.rawValue)
        item.menuFormRepresentation?.title = command.title
        item.menuFormRepresentation?.isEnabled = item.isEnabled
        let selected = item.itemIdentifier.rawValue == "split" && splitEnabled
        item.menuFormRepresentation?.state = selected ? .on : .off
        if let button = item.view as? NSButton {
            button.isEnabled = item.isEnabled; button.toolTip = tooltip
            button.setAccessibilityLabel(command.title)
            button.contentTintColor = selected ? Palette.accent : .secondaryLabelColor
        }
    }
    func refreshToolbar() {
        guard workspaceHost == nil || workspaceHost?.focused === self else { return }
        (window?.toolbar?.items ?? []).forEach { refreshToolbarItem($0) }
    }
    func observeToolbarHistory() {
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange, .NSUndoManagerDidCloseUndoGroup, NSWindow.didBecomeKeyNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refreshToolbar() }
            toolbarObservers.append(observer)
        }
    }
    @objc func undoFromToolbar() {
        guard toolbarEnabled("undo") else { return }
        toolbarTextEditor.undoManager?.undo(); refreshToolbar()
    }
    @objc func redoFromToolbar() {
        guard toolbarEnabled("redo") else { return }
        toolbarTextEditor.undoManager?.redo(); refreshToolbar()
    }
}
