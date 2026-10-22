// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import AppKit

extension EditorController {
    func togglePin(_ id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].pinned = documents[index].pinned != true
        refreshTabs(); scheduleRecovery()
    }
    @objc func toggleActivePin() { togglePin(activeID) }
    func canMoveTab(_ source: UUID, to target: UUID) -> Bool {
        guard source != target, let first = documents.first(where: { $0.id == source }),
              let second = documents.first(where: { $0.id == target }) else { return false }
        return (first.pinned == true) == (second.pinned == true)
    }
    @discardableResult func moveTab(_ source: UUID, beside target: UUID, after: Bool) -> Bool {
        guard canMoveTab(source, to: target), let index = documents.firstIndex(where: { $0.id == source }) else { return false }
        let document = documents.remove(at: index)
        let destination = documents.firstIndex(where: { $0.id == target })!
        documents.insert(document, at: destination + (after ? 1 : 0))
        refreshTabs(); scheduleRecovery()
        return true
    }
    func adjacentTab(_ offset: Int) -> UUID? {
        let destination = activeIndex + offset
        guard documents.indices.contains(destination), canMoveTab(activeID, to: documents[destination].id) else { return nil }
        return documents[destination].id
    }
    @objc func moveTabEarlier() { if let target = adjacentTab(-1) { moveTab(activeID, beside: target, after: false) } }
    @objc func moveTabLater() { if let target = adjacentTab(1) { moveTab(activeID, beside: target, after: true) } }
    func sideTabIDs(after: Bool) -> [UUID] {
        documents.enumerated().filter { (after ? $0.offset > activeIndex : $0.offset < activeIndex) && $0.element.pinned != true }.map { $0.element.id }
    }
    @objc func closeEarlierTabs() { closeTabs(sideTabIDs(after: false)) }
    @objc func closeLaterTabs() { closeTabs(sideTabIDs(after: true)) }
    func extendTabMenu(_ menu: NSMenu) {
        menu.addItem(.separator())
        let pin = item(activeDocument.pinned == true ? tr("common.unpin_document") : tr("common.pin_document"), #selector(toggleActivePin))
        pin.state = activeDocument.pinned == true ? .on : .off
        menu.addItem(pin)
        menu.addItem(item(tr("tabs.shift_tab_left"), #selector(moveTabEarlier)))
        menu.addItem(item(tr("tabs.shift_tab_right"), #selector(moveTabLater)))
        if workspaceHost != nil {
            let directions = NSMenu(title: tr("tabs.move_to_a_new_group"))
            for zone in EditorDropZone.allCases where zone != .center { directions.addItem(item(zone.title, #selector(splitDocument(_:)), tag: zone.rawValue)) }
            let entry = item(directions.title, nil); entry.submenu = directions; menu.addItem(entry)
            menu.addItem(item(tr("tabs.move_to_a_separate_window"), #selector(detachActiveDocument)))
        }
        menu.addItem(.separator())
        menu.addItem(item(tr("tabs.close_unpinned_tabs_before"), #selector(closeEarlierTabs)))
        menu.addItem(item(tr("tabs.close_unpinned_tabs_after"), #selector(closeLaterTabs)))
    }
    func documentPickerEntries() -> [PickerEntry] {
        documents.map { document in
            let details = [document.url?.path ?? tr("tabs.not_saved_to_a_file"), document.pinned == true ? tr("tabs.pinned") : nil, document.isDirty ? tr("common.unsaved_changes") : nil].compactMap { $0 }.joined(separator: " · ")
            return PickerEntry(title: document.title, detail: details, action: { [weak self] in
                guard let self = self else { return }
                self.window?.makeKeyAndOrderFront(nil); self.activateDocument(document.id)
            })
        }
    }
    @objc func showDocumentPicker() {
        presentPicker(title: tr("tabs.switch_document"), prompt: tr("tabs.find_a_filename_or_path"), entries: documentPickerEntries())
    }
    @objc func showDocumentInfo() {
        documentInfo?.closeSheet()
        let source = textView.string as NSString, range = textView.selectedRange()
        let selection = range.length > 0 && NSMaxRange(range) <= source.length ? source.substring(with: range) : nil
        documentInfo = DocumentInfoController(document: activeDocument, selection: selection)
        documentInfo?.present(relativeTo: window)
    }
}
