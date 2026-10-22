// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import AppKit

final class SearchFloatingPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

final class FindPanelController: NSWindowController, NSWindowDelegate {
    weak var editor: EditorController?
    let documentLabel = label("", size: 11)
    let findCaption = label("", size: 12, color: .labelColor)
    let replaceCaption = label("", size: 12, color: .labelColor)
    let wordButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let escapesButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let selectionButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let wrapButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let allButton = NSButton()
    let previousButton: NSButton
    let nextButton: NSButton
    private var appObservers: [NSObjectProtocol] = []
    private var positioned = false

    init(editor: EditorController) {
        self.editor = editor
        previousButton = symbolButton("chevron.up", tooltip: "", target: editor, action: #selector(EditorController.findPrevious))
        nextButton = symbolButton("chevron.down", tooltip: "", target: editor, action: #selector(EditorController.findNext))
        let panel = SearchFloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 232), styleMask: [.titled, .closable, .utilityWindow, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = false
        panel.contentMinSize = NSSize(width: 520, height: 232)
        panel.contentMaxSize = NSSize(width: 900, height: 232)
        super.init(window: panel)
        panel.delegate = self
        panel.onEscape = { [weak editor] in editor?.hideFind() }
        let content = NSView(); panel.contentView = content
        let navigation = row([previousButton, nextButton], spacing: 4)
        let spacer = NSView(); spacer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([navigation.widthAnchor.constraint(equalToConstant: 60), spacer.widthAnchor.constraint(equalToConstant: 60)])
        let find = row([findCaption, editor.findField, navigation], spacing: 10)
        let replacement = row([replaceCaption, editor.replacementField, spacer], spacing: 10)
        for caption in [findCaption, replaceCaption] { caption.widthAnchor.constraint(equalToConstant: 76).isActive = true }
        for field in [editor.findField, editor.replacementField] {
            field.heightAnchor.constraint(equalToConstant: 22).isActive = true
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let options = row([editor.caseButton, wordButton, editor.regexButton], spacing: 16)
        let scope = row([escapesButton, selectionButton, wrapButton], spacing: 16)
        for button in [wordButton, escapesButton, selectionButton, wrapButton] {
            button.controlSize = .small; button.font = .systemFont(ofSize: 11)
            button.target = self; button.action = #selector(optionChanged(_:))
        }
        allButton.bezelStyle = .rounded; allButton.controlSize = .small; allButton.font = .systemFont(ofSize: 12)
        allButton.target = editor; allButton.action = #selector(EditorController.listDocumentMatches)
        let flexible = NSView(); flexible.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = row([allButton, flexible, editor.replaceOneButton, editor.replaceAllButton], spacing: 8)
        for button in [allButton, editor.replaceOneButton, editor.replaceAllButton] {
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let stack = NSStackView(views: [documentLabel, find, replacement, options, scope, editor.matchLabel, actions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14), stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -14)
        ])
        for view in [documentLabel, find, replacement, options, scope, editor.matchLabel, actions] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        appObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.window?.alphaValue = 0.72 })
        appObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.updateOpacity() })
        refreshLocalization()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    deinit {
        appObservers.forEach { NotificationCenter.default.removeObserver($0) }
        window?.orderOut(nil)
    }
    private func row(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let row = NSStackView(views: views); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = spacing
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }
    func refreshLocalization() {
        window?.title = tr("common.find_and_replace")
        findCaption.stringValue = tr("common.find")
        replaceCaption.stringValue = tr("common.replace_with")
        wordButton.title = tr("common.whole_words")
        escapesButton.title = tr("find.escaped_text")
        escapesButton.toolTip = tr("find.interpret_n_r_t_and_exclusive_with_regex")
        selectionButton.title = tr("find.in_selection")
        wrapButton.title = tr("find.wrap_search")
        allButton.title = tr("common.list_document_matches")
        previousButton.toolTip = tr("find.previous_match_g")
        nextButton.toolTip = tr("find.next_match_g")
        for button in [wordButton, escapesButton, selectionButton, wrapButton, allButton] { button.setAccessibilityLabel(button.title) }
        for button in [previousButton, nextButton] { button.setAccessibilityLabel(button.toolTip) }
        if let editor = editor {
            let menu = NSMenu()
            for (title, tag) in [(tr("find.recent_searches"), NSSearchField.recentsTitleMenuItemTag), ("", NSSearchField.recentsMenuItemTag), (tr("find.clear_recent_searches"), NSSearchField.clearRecentsMenuItemTag), (tr("find.no_recent_searches"), NSSearchField.noRecentsMenuItemTag)] {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.tag = tag; menu.addItem(item)
            }
            editor.findField.searchMenuTemplate = menu
        }
        syncOptions(); refreshDocument()
    }
    func refreshDocument() {
        guard let editor = editor, !editor.documents.isEmpty else { return }
        documentLabel.stringValue = editor.activeDocument.title + (editor.activeDocument.locked == true ? tr("find.read_only") : "")
        documentLabel.toolTip = editor.activeDocument.url?.path ?? editor.activeDocument.title
    }
    func syncOptions() {
        guard let editor = editor else { return }
        wordButton.state = editor.wholeWord ? .on : .off
        escapesButton.state = editor.extendedSearch ? .on : .off
        selectionButton.state = editor.selectionOnly ? .on : .off
        wrapButton.state = editor.searchWraps ? .on : .off
    }
    @objc private func optionChanged(_ sender: NSButton) {
        guard let editor = editor else { return }
        if sender === wordButton { editor.toggleWholeWord() }
        else if sender === escapesButton { editor.toggleExtendedSearch() }
        else if sender === selectionButton { editor.toggleSelectionSearch() }
        else { editor.searchWraps = sender.state == .on; editor.scheduleSearch() }
        syncOptions()
    }
    func present(focus: Bool) {
        guard let panel = window, let editor = editor else { return }
        panel.appearance = editor.window?.appearance
        if !positioned {
            positioned = true
            if !panel.setFrameUsingName("EditDotSearchPanel"), let parent = editor.window {
                panel.setFrameTopLeftPoint(NSPoint(x: parent.frame.maxX - panel.frame.width - 24, y: parent.frame.maxY - 90))
            }
            panel.setFrameAutosaveName("EditDotSearchPanel")
            if let screen = editor.window?.screen ?? NSScreen.main {
                var frame = panel.frame; let visible = screen.visibleFrame
                frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
                frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
                panel.setFrame(frame, display: false)
            }
        }
        if panel.parent == nil { editor.window?.addChildWindow(panel, ordered: .above) }
        syncOptions(); refreshDocument()
        if focus {
            panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(editor.findField); editor.findField.selectText(nil)
        } else { panel.orderFront(nil) }
        updateOpacity()
    }
    func dismiss() {
        if let panel = window { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
    }
    func updateOpacity() { window?.alphaValue = window?.isKeyWindow == true ? 1 : 0.72 }
    func windowDidBecomeKey(_ notification: Notification) {
        window?.alphaValue = 1
        if let editor = editor { editor.workspaceHost?.focus(editor) }
    }
    func windowDidResignKey(_ notification: Notification) { window?.alphaValue = 0.72 }
    func windowShouldClose(_ sender: NSWindow) -> Bool { editor?.hideFind(); return false }
}

extension EditorController {
    @objc func listDocumentMatches() {
        guard !effectiveQuery.isEmpty else { return }
        if !findVisible { presentFind(focus: false, prefillSelection: false) }
        rememberFindQuery()
        searchJob?.cancel(); searchVersion += 1
        let version = searchVersion, id = activeID, document = activeDocument, query = effectiveQuery
        let matchCase = caseButton.state == .on, regex = regexButton.state == .on, word = wholeWord, scope = effectiveScope
        matchLabel.stringValue = tr("common.searching")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = SearchResult.find(query, in: document.content, matchCase: matchCase, regex: regex, wholeWord: word, range: scope)
            let hits = FileSearch.hits(in: document, query: query, matchCase: matchCase, regex: regex, wholeWord: word, limit: 5000, searchResult: result)
            DispatchQueue.main.async {
                guard let self = self, self.activeID == id, self.searchVersion == version, self.findVisible else { return }
                self.searchResult = result; self.refreshFindStatus(); self.highlightMatches()
                guard !result.invalid, !result.timedOut else { return }
                self.fileSearchCancellation?.cancel(); self.fileSearchVersion += 1
                self.fileSearchQuery = query
                self.fileSearchReport = FileSearchReport(hits: hits, scanned: 1, limited: result.limited || result.matches.count > hits.count)
                self.results.hits = hits; self.results.cancelButton.isHidden = true
                self.resultsVisible = true; self.resizeWorkspace(); self.refreshSearchSummary()
            }
        }
    }
}
