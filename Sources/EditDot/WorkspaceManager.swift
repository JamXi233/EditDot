// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import AppKit

struct EditorTransfer {
    var document: EditorDocument
    var primary: EditorTextView?
    var secondary: EditorTextView?
    var position: (primary: NSPoint, secondary: NSPoint)?
}

final class WorkspaceManager: NSObject {
    let store: SessionStore
    var windows: [EditorWorkspaceWindow] = []
    weak var focusedWindow: EditorWorkspaceWindow?
    private var emptyHost: EditorWorkspaceWindow?
    var activeEditor: EditorController? { focusedWindow?.focused ?? windows.first?.focused }
    var mutating = false
    private var saveJob: DispatchWorkItem?
    init(store: SessionStore = SessionStore()) { self.store = store; super.init() }
    @objc func createDocument(_ sender: Any?) {
        if windows.isEmpty { newWindow() } else { activeEditor?.newDocument() }
    }
    @objc func createWindow(_ sender: Any?) { newWindow() }
    @objc func openDocuments(_ sender: Any?) {
        if windows.isEmpty { newWindow() }
        activeEditor?.openDocuments()
    }
    private func installEmptyMenu() {
        guard windows.isEmpty, let owner = emptyHost?.focused else { return }
        let full = owner.makeMainMenu(), menu = NSMenu()
        let appMenu = full.items[0].submenu; full.items[0].submenu = nil
        let app = NSMenuItem(title: "EditDot", action: nil, keyEquivalent: ""); app.submenu = appMenu; menu.addItem(app)
        let files = NSMenu(title: tr("common.documents"))
        for (title, action, key, modifiers) in [
            (tr("common.new"), #selector(createDocument(_:)), "n", NSEvent.ModifierFlags.command),
            (tr("common.new_window"), #selector(createWindow(_:)), "n", [.command, .shift]),
            (tr("common.open_2"), #selector(openDocuments(_:)), "o", .command)
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; item.keyEquivalentModifierMask = modifiers; files.addItem(item)
        }
        let entry = NSMenuItem(title: files.title, action: nil, keyEquivalent: ""); entry.submenu = files; menu.addItem(entry)
        NSApp.mainMenu = menu
    }
    func start(restore: Bool = true) {
        mutating = true
        if restore, let saved = store.loadWorkspace(), !saved.windows.isEmpty {
            for record in saved.windows {
                let host = EditorWorkspaceWindow(manager: self, id: record.id, frame: record.frame)
                windows.append(host); host.restore(record, store: store)
            }
            focusedWindow = windows.first { $0.id == saved.focusedWindow } ?? windows.first
        } else {
            let host = EditorWorkspaceWindow(manager: self); windows.append(host)
            host.installSingle(EditorController(store: store, restore: restore, host: host))
        }
        mutating = false
        for host in windows { host.resizeGroups(); host.window.makeKeyAndOrderFront(nil) }
        focusedWindow?.window.makeKeyAndOrderFront(nil)
        focusedWindow?.focus(focusedWindow!.focused, makeResponder: true)
        persist()
    }
    @discardableResult func newWindow(at point: NSPoint? = nil) -> EditorWorkspaceWindow {
        let host = EditorWorkspaceWindow(manager: self)
        windows.append(host)
        let editor = EditorController(store: store, restore: false, host: host); editor.workspacePlaceholder = true
        host.installSingle(editor)
        if let point = point { host.window.setFrameOrigin(NSPoint(x: point.x - 100, y: point.y - host.window.frame.height + 30)); host.constrainToScreen() }
        host.window.makeKeyAndOrderFront(nil); host.focus(host.focused, makeResponder: true)
        scheduleSave()
        return host
    }
    func owner(of id: UUID) -> EditorController? { windows.lazy.flatMap(\.groups).first { $0.documents.contains { $0.id == id } } }
    func editor(for url: URL) -> EditorController? { windows.lazy.flatMap(\.groups).first { $0.documents.contains { $0.url?.standardizedFileURL == url.standardizedFileURL } } }
    @discardableResult func transfer(_ id: UUID, to target: EditorController, beside other: UUID? = nil, after: Bool = true, preserveSource: Bool = false) -> Bool {
        guard let source = owner(of: id) else { return false }
        if source === target {
            if let other = other { return target.moveTab(id, beside: other, after: after) }
            guard let document = source.documents.first(where: { $0.id == id }), let last = source.documents.last(where: { ($0.pinned == true) == (document.pinned == true) }), last.id != id else { source.activateDocument(id); return true }
            return source.moveTab(id, beside: last.id, after: true)
        }
        if source.findVisible, source.documents.count == 1 { followFindPanel(to: target) }
        let previousMutation = mutating; mutating = true
        let packet = source.takeDocument(id)
        target.acceptDocument(packet)
        if let other = other, target.canMoveTab(id, to: other) { _ = target.moveTab(id, beside: other, after: after) }
        if source.documents.isEmpty, preserveSource {
            let blank = EditorDocument(); source.documents = [blank]; source.activateDocument(blank.id)
        } else if source.documents.isEmpty {
            if let host = source.workspaceHost {
                if host.groups.count > 1 { host.remove(source) }
                else { removeWindowWithoutPrompt(host) }
            }
        } else { source.activateDocument(source.documents[min(source.activeIndex, source.documents.count - 1)].id); source.refreshTabs() }
        mutating = previousMutation
        target.workspaceHost?.resizeGroups(); target.workspaceHost?.focus(target, makeResponder: true)
        target.window?.makeKeyAndOrderFront(nil)
        target.root.layoutSubtreeIfNeeded()
        if let position = packet.position {
            target.restoreScrollPosition(position.primary, in: target.editorScroll)
            if target.secondaryVisible { target.restoreScrollPosition(position.secondary, in: target.secondaryScroll) }
        }
        persist()
        return true
    }
    @discardableResult func drop(_ id: UUID, into target: EditorController, zone: EditorDropZone) -> Bool {
        if zone == .center {
            if owner(of: id) === target { target.activateDocument(id); return true }
            return transfer(id, to: target)
        }
        guard let host = target.workspaceHost, host.canSplit(target, zone: zone), owner(of: id) != nil else { return false }
        let new = EditorController(store: store, restore: false, host: host)
        new.workspacePlaceholder = true
        mutating = true
        guard host.insert(new, beside: target, zone: zone) else { mutating = false; return false }
        mutating = false
        let result = transfer(id, to: new, preserveSource: owner(of: id) === target && target.documents.count == 1)
        host.resizeGroups()
        return result
    }
    @discardableResult func detach(_ id: UUID, at point: NSPoint? = nil, onlyOutside: Bool = false) -> Bool {
        if let point = point, onlyOutside, windows.contains(where: { $0.window.isVisible && $0.window.frame.contains(point) }) { return false }
        guard owner(of: id) != nil else { return false }
        mutating = true
        let host = newWindow(at: point)
        mutating = false
        return transfer(id, to: host.focused)
    }
    func mergeGroups(in host: EditorWorkspaceWindow, into target: EditorController) {
        let ids = host.groups.filter { $0 !== target }.flatMap { $0.documents.map(\.id) }
        for id in ids { _ = transfer(id, to: target) }
        host.focus(target, makeResponder: true); persist()
    }
    func followFindPanel(to group: EditorController) {
        guard !mutating, let previous = windows.flatMap(\.groups).first(where: { $0.findVisible }), previous !== group else { return }
        let frame = previous.findPanel?.window?.frame
        group.findField.stringValue = previous.findField.stringValue
        group.replacementField.stringValue = previous.replacementField.stringValue
        group.caseButton.state = previous.caseButton.state; group.regexButton.state = previous.regexButton.state
        group.wholeWord = previous.wholeWord; group.extendedSearch = previous.extendedSearch; group.searchWraps = previous.searchWraps
        group.selectionOnly = false; group.searchScope = nil
        previous.dismissFind(restoreFocus: false)
        group.presentFind(focus: false, prefillSelection: false)
        if let frame = frame { group.findPanel?.window?.setFrame(frame, display: true) }
    }
    func confirmClose(_ groups: [EditorController]) -> Bool {
        for group in groups {
            for id in group.documents.filter(\.isDirty).map(\.id) {
                group.workspaceHost?.focus(group, makeResponder: true)
                group.window?.makeKeyAndOrderFront(nil)
                if !group.confirmSave(id) { return false }
            }
        }
        return true
    }
    func discardApprovedChanges(_ groups: [EditorController]) {
        for group in groups {
            group.recoveryJob?.cancel()
            for index in group.documents.indices where group.documents[index].isDirty {
                group.documents[index].discardChanges()
            }
        }
    }
    func closeWindow(_ host: EditorWorkspaceWindow) -> Bool {
        guard confirmClose(host.groups) else { return false }
        discardApprovedChanges(host.groups)
        for group in host.groups { group.recoveryJob?.cancel(); group.dismissFind(restoreFocus: false) }
        windows.removeAll { $0 === host }
        if focusedWindow === host { focusedWindow = windows.last }
        if windows.isEmpty { emptyHost = host; installEmptyMenu() }
        persist(); store.flush()
        return true
    }
    func closeGroup(_ group: EditorController) {
        guard let host = group.workspaceHost else { return }
        if host.groups.count == 1 { host.window.performClose(nil); return }
        guard confirmClose([group]) else { return }
        discardApprovedChanges([group]); group.dismissFind(restoreFocus: false); host.remove(group); persist()
    }
    func removeWindowWithoutPrompt(_ host: EditorWorkspaceWindow) {
        windows.removeAll { $0 === host }
        if focusedWindow === host { focusedWindow = windows.last }
        host.window.orderOut(nil)
        for group in host.groups { group.dismissFind(restoreFocus: false); group.workspaceHost = nil; group.window = nil }
        host.groups = []
    }
    func prepareToQuit() -> Bool {
        let groups = windows.flatMap(\.groups)
        guard confirmClose(groups) else { return false }
        discardApprovedChanges(groups)
        saveJob?.cancel(); persist(); store.flush()
        return true
    }
    func scheduleSave() {
        guard !mutating else { return }
        saveJob?.cancel()
        let job = DispatchWorkItem { [weak self] in self?.persist() }; saveJob = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: job)
    }
    func persist() {
        guard !mutating else { return }
        let saved = WorkspaceSession(windows: windows.map { $0.snapshot() }, focusedWindow: focusedWindow?.id)
        store.saveWorkspace(saved) { [weak self] error in
            guard let self = self else { return }
            for group in self.windows.flatMap(\.groups) { group.recoveryFailed = error != nil; group.refreshStatus() }
        }
        let groups = windows.flatMap(\.groups)
        store.save(EditorSession(documents: groups.flatMap(\.documents), activeID: activeEditor?.activeID, folderURL: activeEditor?.folderURL))
    }
    func refreshPreferences() {
        let active = focusedWindow
        for host in windows {
            for group in host.groups { group.applyEditorPreferences(); group.applyAppearance(); group.refreshLocalization() }
            host.focus(host.focused); host.resizeGroups()
        }
        if let active = active { active.focus(active.focused) }
        activeEditor?.refreshMainMenu()
        emptyHost?.focused.preferences?.refreshLocalization()
        emptyHost?.focused.about?.refreshLocalization()
        if windows.isEmpty { emptyHost?.focused.applyAppearance(); installEmptyMenu() }
    }
}

extension EditorController {
    func snapshotSession() -> EditorSession {
        stashPosition()
        return EditorSession(documents: documents, activeID: activeID, folderURL: folderURL)
    }
    func takeDocument(_ id: UUID) -> EditorTransfer {
        if activeID == id {
            stashPosition(); analysisJob?.cancel(); searchJob?.cancel(); selectionJob?.cancel(); recoveryJob?.cancel()
            analysisVersion += 1; searchVersion += 1; pendingEdit = nil
        }
        if macroRecording { stopMacro() }
        let index = documents.firstIndex { $0.id == id }!
        let packet = EditorTransfer(document: documents[index], primary: buffers[id], secondary: splitBuffers[id], position: panePositions[id])
        packet.primary?.breakUndoCoalescing(); packet.secondary?.breakUndoCoalescing()
        if activeID == id { isLoading = true; ruler?.editor = nil; secondaryRuler?.editor = nil }
        if editorScroll.documentView === packet.primary { editorScroll.documentView = nil }
        if secondaryScroll.documentView === packet.secondary { secondaryScroll.documentView = nil }
        documents.remove(at: index); buffers.removeValue(forKey: id); splitBuffers.removeValue(forKey: id); panePositions.removeValue(forKey: id)
        if activeID == id { primaryEditor = EditorTextView(frame: .zero); secondaryFocused = false }
        return packet
    }
    func acceptDocument(_ packet: EditorTransfer) {
        if workspacePlaceholder, documents.count == 1, let first = documents.first, first.url == nil, first.content.isEmpty, !first.isDirty, first.pinned != true, buffers[first.id]?.history.canUndo != true, buffers[first.id]?.history.canRedo != true {
            documents.removeAll(); buffers.removeAll(); splitBuffers.removeAll(); panePositions.removeAll()
        }
        workspacePlaceholder = false
        documents.append(packet.document)
        if let editor = packet.primary { buffers[packet.document.id] = editor; connectEditor(editor) }
        if let editor = packet.secondary { splitBuffers[packet.document.id] = editor; connectEditor(editor) }
        panePositions[packet.document.id] = packet.position
        activateDocument(packet.document.id)
    }
    func sharedPreferencesChanged() {
        if let manager = workspaceHost?.manager { manager.refreshPreferences() }
        else { applyEditorPreferences(); scheduleAnalysis(immediate: true); refreshMainMenu() }
    }
    func refreshWindowMetadata() {
        if let host = workspaceHost { host.updateMetadata() }
        else if !documents.isEmpty {
            window?.title = activeDocument.title + " — EditDot"; window?.representedURL = activeDocument.url; window?.isDocumentEdited = activeDocument.isDirty
        }
    }
    func refreshMainMenu() { installMainMenu(force: true) }
    func installMainMenu(force: Bool = false) {
        guard workspaceHost == nil || workspaceHost?.focused === self else { return }
        if let host = workspaceHost, host.manager?.focusedWindow !== host { return }
        if workspaceHost?.manager?.mutating == true { return }
        if !force, let installed = installedMainMenu, NSApp.mainMenu === installed { return }
        let menu = makeMainMenu()
        installedMainMenu = menu
        NSApp.mainMenu = menu
    }
    @objc func detachActiveDocument() { _ = workspaceHost?.manager?.detach(activeID) }
    @objc func splitDocument(_ sender: NSMenuItem) {
        guard let zone = EditorDropZone(rawValue: sender.tag), zone != .center else { return }
        _ = workspaceHost?.manager?.drop(activeID, into: self, zone: zone)
    }
    @objc func mergeEditorGroups() { if let host = workspaceHost { host.manager?.mergeGroups(in: host, into: self) } }
    @objc func closeEditorGroup() { workspaceHost?.manager?.closeGroup(self) }
    @objc func focusNextGroup() { focusAdjacentGroup(1) }
    @objc func focusPreviousGroup() { focusAdjacentGroup(-1) }
    func focusAdjacentGroup(_ offset: Int) {
        guard let host = workspaceHost, let index = host.groups.firstIndex(where: { $0 === self }) else { return }
        host.focus(host.groups[(index + offset + host.groups.count) % host.groups.count], makeResponder: true)
    }
    @objc func showWorkspaceWindow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let host = workspaceHost?.manager?.windows.first(where: { $0.id == id }) else { return }
        host.window.makeKeyAndOrderFront(nil); host.focus(host.focused, makeResponder: true)
    }
}
