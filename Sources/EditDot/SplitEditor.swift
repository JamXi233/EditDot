// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import AppKit

extension EditorController {
    var splitEnabled: Bool { twinEnabledOverride ?? UserDefaults.standard.bool(forKey: "splitEditor") }
    var secondaryVisible: Bool { secondaryScroll.superview === editingSplit }
    var secondaryEditor: EditorTextView? { splitBuffers[activeID] }
    var activeScroll: NSScrollView { secondaryFocused && secondaryVisible ? secondaryScroll : editorScroll }
    var editorPanes: [(EditorTextView, NSScrollView, LineNumberView?)] {
        var panes: [(EditorTextView, NSScrollView, LineNumberView?)] = [(primaryEditor, editorScroll, ruler)]
        if let editor = secondaryEditor, editor.textStorage === primaryEditor.textStorage { panes.append((editor, secondaryScroll, secondaryRuler)) }
        return panes
    }
    func setupSplitEditor() {
        editingSplit.isVertical = true; editingSplit.dividerStyle = .thin
        editorScroll.translatesAutoresizingMaskIntoConstraints = true
        editorScroll.autoresizingMask = [.width, .height]
        editingSplit.addSubview(editorScroll)
        secondaryScroll.borderType = .noBorder; secondaryScroll.drawsBackground = true
        secondaryScroll.contentView = EditorClipView(frame: secondaryScroll.contentView.frame)
        secondaryScroll.backgroundColor = Palette.canvas; secondaryScroll.hasVerticalScroller = true
        secondaryScroll.autohidesScrollers = true; secondaryScroll.scrollerStyle = .overlay
        secondaryScroll.autoresizingMask = [.width, .height]
        secondaryScroll.contentView.postsBoundsChangedNotifications = true
        splitScrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: secondaryScroll.contentView, queue: .main) { [weak self] _ in
            self?.secondaryRuler?.needsDisplay = true; self?.highlightMatches()
        }
    }
    func synchronizeSplit() {
        let available = markdownMode == .split ? editingSplit.bounds.width : groupWidth - (browserWidth?.constant ?? 0)
        let shouldShow = splitEnabled && available >= 680 && buffers[activeID] != nil
        guard shouldShow else {
            if secondaryVisible {
                let wasFocused = window?.firstResponder === secondaryEditor
                secondaryFocused = false; secondaryScroll.removeFromSuperview(); editingSplit.adjustSubviews()
                if wasFocused { window?.makeFirstResponder(primaryEditor) }
            }
            return
        }
        guard let storage = primaryEditor.textStorage else { return }
        let editor: EditorTextView
        if let cached = splitBuffers[activeID], cached.textStorage === storage { editor = cached }
        else {
            let manager = NSLayoutManager()
            let container = NSTextContainer(containerSize: NSSize(width: max(300, available / 2), height: CGFloat.greatestFiniteMagnitude))
            manager.addTextContainer(container); storage.addLayoutManager(manager)
            editor = makeEditor(container: container); editor.history = primaryEditor.history
            splitBuffers[activeID] = editor
        }
        let adding = !secondaryVisible
        if adding { editingSplit.addSubview(secondaryScroll) }
        if secondaryScroll.documentView !== editor {
            secondaryScroll.documentView = editor
            secondaryRuler = LineNumberView(editor: editor, scrollView: secondaryScroll)
            secondaryRuler?.index = currentIndex
            secondaryRuler?.toggleBookmark = { [weak self] location in self?.toggleBookmark(at: location) }
            secondaryScroll.verticalRulerView = secondaryRuler
        }
        if adding {
            window?.contentView?.layoutSubtreeIfNeeded()
            editingSplit.adjustSubviews()
            editingSplit.setPosition(max(1, editingSplit.bounds.width / 2), ofDividerAt: 0)
            applyEditorPreferences()
        }
        refreshGutters()
    }
    func refreshGutters() {
        for (_, _, gutter) in editorPanes { gutter?.index = currentIndex; gutter?.bookmarks = activeDocument.bookmarks ?? [] }
    }
    @objc func toggleSplitEditor() {
        if workspaceHost != nil { twinEnabledOverride = !splitEnabled; workspaceHost?.manager?.scheduleSave() }
        else { UserDefaults.standard.set(!splitEnabled, forKey: "splitEditor") }
        synchronizeSplit(); applyEditorPreferences(); scheduleAnalysis(immediate: true)
        refreshToolbar()
        refreshMainMenu()
    }
    @objc func switchEditingPane() {
        guard secondaryVisible, let secondary = secondaryEditor else { return }
        window?.makeFirstResponder(secondaryFocused ? primaryEditor : secondary)
    }
}
