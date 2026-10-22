// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import AppKit

final class WorkspaceNativeWindow: NSWindow {
    var routeMouse: ((NSEvent) -> Bool)?
    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown, .otherMouseUp].contains(event.type), routeMouse?(event) == true { return }
        super.sendEvent(event)
    }
}

final class EditorWorkspaceWindow: NSObject, NSWindowDelegate, NSSplitViewDelegate {
    let id: UUID
    let window: WorkspaceNativeWindow
    let canvas = NSView()
    weak var manager: WorkspaceManager?
    var groups: [EditorController] = []
    private(set) var focused: EditorController!
    var building = false
    private var routingFocus = false
    private var middleTab: UUID?
    init(manager: WorkspaceManager, id: UUID = UUID(), frame: NSRect? = nil) {
        self.id = id; self.manager = manager
        window = WorkspaceNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.delegate = self; window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 520, height: 360)
        window.titleVisibility = .hidden; window.toolbarStyle = .unified; window.tabbingMode = .disallowed
        window.backgroundColor = Palette.canvas; window.contentView = canvas
        switch UserDefaults.standard.string(forKey: "theme") ?? "system" {
        case "light": window.appearance = NSAppearance(named: .aqua)
        case "dark": window.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        if let frame = frame { window.setFrame(frame, display: false) } else { window.center() }
        constrainToScreen()
        window.routeMouse = { [weak self] event in self?.route(event) ?? false }
    }
    func constrainToScreen() {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        frame.size.width = min(visible.width, max(520, frame.width))
        frame.size.height = min(visible.height, max(360, frame.height))
        frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
        frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
        window.setFrame(frame, display: false)
    }
    func attach(_ group: EditorController) {
        let oldWindow = group.window
        if oldWindow !== window { oldWindow?.orderOut(nil); oldWindow?.contentView = nil }
        group.window = window; group.workspaceHost = self
        groups.append(group)
        group.root.autoresizingMask = [.width, .height]
        group.root.translatesAutoresizingMaskIntoConstraints = true
        group.root.proposeTabDrop = { [weak self, weak group] id, point in
            guard let self = self, let group = group, self.manager?.owner(of: id) != nil else { return nil }
            let rect = group.root.convert(group.documentContent.bounds, from: group.documentContent)
            guard let zone = EditorDropZone.at(point, in: rect), zone == .center || self.canSplit(group, zone: zone) else { return nil }
            return (zone, rect)
        }
        group.root.receiveTabDrop = { [weak self, weak group] id, zone in
            guard let self = self, let group = group else { return false }
            return self.manager?.drop(id, into: group, zone: zone) ?? false
        }
        group.tabsBar.acceptsTab = { [weak self] id in self?.manager?.owner(of: id) != nil }
        group.tabsBar.receivesTab = { [weak self, weak group] id in
            guard let self = self, let group = group else { return false }
            return self.manager?.transfer(id, to: group) ?? false
        }
        if oldWindow !== window { group.refreshTabs() }
    }
    func installSingle(_ group: EditorController) {
        attach(group); group.root.frame = canvas.bounds; canvas.addSubview(group.root)
        focus(group); resizeGroups()
    }
    func focus(_ group: EditorController, makeResponder: Bool = false) {
        guard groups.contains(where: { $0 === group }), !routingFocus else { return }
        routingFocus = true
        let changed = focused !== group
        focused = group; manager?.focusedWindow = self
        if changed || window.toolbar?.delegate !== group { group.setupToolbar() }
        group.installMainMenu(); updateMetadata()
        if makeResponder { window.makeFirstResponder(group.textView) }
        routingFocus = false
        group.refreshToolbar()
        manager?.followFindPanel(to: group)
    }
    func updateMetadata() {
        guard let group = focused, !group.documents.isEmpty else { return }
        window.title = group.activeDocument.title + " — EditDot"
        window.representedURL = group.activeDocument.url
        window.isDocumentEdited = groups.contains { $0.documents.contains(where: \.isDirty) }
    }
    private func route(_ event: NSEvent) -> Bool {
        guard let group = groups.first(where: { $0.root.bounds.contains($0.root.convert(event.locationInWindow, from: nil)) }) else { return false }
        if event.type == .otherMouseDown || event.type == .otherMouseUp, event.buttonNumber == 2 {
            let point = group.tabStack.convert(event.locationInWindow, from: nil)
            if let tab = group.tabStack.arrangedSubviews.compactMap({ $0 as? TabItemView }).first(where: { $0.frame.contains(point) }) {
                if event.type == .otherMouseDown { middleTab = tab.documentID }
                else { let pressed = middleTab; middleTab = nil; if pressed == tab.documentID { group.closeDocument(tab.documentID) } }
                return true
            }
            middleTab = nil
        }
        focus(group)
        return false
    }
    func canSplit(_ group: EditorController, zone: EditorDropZone) -> Bool {
        guard zone != .center, groups.count < 32 else { return false }
        return zone.vertical ? group.root.bounds.width >= 640 : group.root.bounds.height >= 440
    }
    func insert(_ new: EditorController, beside target: EditorController, zone: EditorDropZone) -> Bool {
        guard canSplit(target, zone: zone), let parent = target.root.superview else { return false }
        building = true
        let frame = target.root.frame
        let split = NSSplitView(frame: frame)
        split.isVertical = zone.vertical; split.dividerStyle = .thin; split.delegate = self
        split.autoresizingMask = [.width, .height]
        parent.replaceSubview(target.root, with: split)
        attach(new)
        let first = zone == .left || (zone == .top && split.isFlipped) || (zone == .bottom && !split.isFlipped)
        for view in first ? [new.root, target.root] : [target.root, new.root] { split.addSubview(view) }
        split.adjustSubviews()
        split.setPosition((zone.vertical ? split.bounds.width : split.bounds.height) / 2, ofDividerAt: 0)
        building = false
        resizeGroups(); focus(new, makeResponder: true)
        return true
    }
    func remove(_ group: EditorController) {
        guard groups.count > 1, let split = group.root.superview as? NSSplitView, let parent = split.superview,
              let sibling = split.subviews.first(where: { $0 !== group.root }) else { return }
        group.dismissFind(restoreFocus: false)
        building = true
        let frame = split.frame
        group.root.removeFromSuperview(); sibling.removeFromSuperview()
        parent.replaceSubview(split, with: sibling); sibling.frame = frame; sibling.autoresizingMask = [.width, .height]
        groups.removeAll { $0 === group }
        group.workspaceHost = nil; group.window = nil
        building = false
        focus(groups.first!, makeResponder: true); resizeGroups()
    }
    func resizeGroups() {
        guard !building, manager?.mutating != true else { return }
        canvas.layoutSubtreeIfNeeded()
        if let root = canvas.subviews.first {
            let minimum = minimumSize(of: root)
            let chrome = max(0, window.frame.height - canvas.bounds.height)
            window.minSize = NSSize(width: max(520, minimum.width), height: max(360, minimum.height + chrome))
        }
        for group in groups { group.resizeWorkspace(); group.refreshStatus(); group.refreshGutters() }
    }
    private func minimumSize(of view: NSView) -> NSSize {
        guard let split = view as? NSSplitView, split.subviews.count == 2 else { return NSSize(width: 320, height: 220) }
        let first = minimumSize(of: split.subviews[0]), second = minimumSize(of: split.subviews[1])
        return split.isVertical ? NSSize(width: first.width + second.width + split.dividerThickness, height: max(first.height, second.height)) : NSSize(width: max(first.width, second.width), height: first.height + second.height + split.dividerThickness)
    }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        resizeGroups()
        if !building { manager?.scheduleSave() }
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let minimum = minimumSize(of: splitView.subviews[0])
        let other = minimumSize(of: splitView.subviews[1])
        let extent = (splitView.isVertical ? splitView.bounds.width : splitView.bounds.height) - splitView.dividerThickness
        let low = splitView.isVertical ? minimum.width : minimum.height, high = splitView.isVertical ? other.width : other.height
        return low + high <= extent ? proposedMinimumPosition + low : extent / 2
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let minimum = minimumSize(of: splitView.subviews[1])
        let other = minimumSize(of: splitView.subviews[0])
        let extent = (splitView.isVertical ? splitView.bounds.width : splitView.bounds.height) - splitView.dividerThickness
        let high = splitView.isVertical ? minimum.width : minimum.height, low = splitView.isVertical ? other.width : other.height
        return low + high <= extent ? proposedMaximumPosition - high : extent / 2
    }
    func windowDidResize(_ notification: Notification) { resizeGroups(); manager?.scheduleSave() }
    func windowDidMove(_ notification: Notification) { manager?.scheduleSave() }
    func windowDidBecomeKey(_ notification: Notification) { if let focused = focused { focus(focused) } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { manager?.closeWindow(self) ?? true }
    func snapshot() -> SavedEditorWindow {
        func layout(_ view: NSView) -> WorkspaceLayout {
            if let group = groups.first(where: { $0.root === view }) { return .group(group.groupID) }
            let split = view as! NSSplitView
            let full = max(1, (split.isVertical ? split.bounds.width : split.bounds.height) - split.dividerThickness)
            let first = split.subviews[0]
            let fraction = Double((split.isVertical ? first.frame.width : first.frame.height) / full)
            return .split(vertical: split.isVertical, fraction: fraction, first: layout(first), second: layout(split.subviews[1]))
        }
        return SavedEditorWindow(id: id, frame: window.frame, focusedGroup: focused.groupID, groups: groups.map { SavedEditorGroup(id: $0.groupID, session: $0.snapshotSession(), twinEnabled: $0.splitEnabled) }, layout: layout(canvas.subviews[0]))
    }
    func restore(_ saved: SavedEditorWindow, store: SessionStore) {
        building = true
        for record in saved.groups {
            let group = EditorController(store: store, restore: false, initialSession: record.session, groupID: record.id, host: self)
            group.twinEnabledOverride = record.twinEnabled
            attach(group)
        }
        func build(_ layout: WorkspaceLayout, frame: NSRect) -> NSView {
            switch layout {
            case .group(let id):
                let group = groups.first { $0.groupID == id }!; group.root.frame = frame; return group.root
            case .split(let vertical, let fraction, let first, let second):
                let split = NSSplitView(frame: frame); split.isVertical = vertical; split.dividerStyle = .thin; split.delegate = self; split.autoresizingMask = [.width, .height]
                split.addSubview(build(first, frame: split.bounds)); split.addSubview(build(second, frame: split.bounds))
                split.adjustSubviews(); split.setPosition((vertical ? split.bounds.width : split.bounds.height) * CGFloat(fraction.isFinite ? min(0.9, max(0.1, fraction)) : 0.5), ofDividerAt: 0)
                return split
            }
        }
        canvas.addSubview(build(saved.layout, frame: canvas.bounds))
        building = false
        focus(groups.first { $0.groupID == saved.focusedGroup } ?? groups[0], makeResponder: true)
        window.setFrame(saved.frame, display: false)
        constrainToScreen()
        resizeGroups()
    }
}
