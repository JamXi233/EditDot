// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import AppKit

enum DocumentFeedback {
    case working, formatted, valid, invalid(Error), changed
    var title: String {
        switch self {
        case .working: return tr("document.working")
        case .formatted: return tr("document.formatted")
        case .valid: return tr("document.valid")
        case .invalid: return tr("document.invalid_format")
        case .changed: return tr("document.content_changed_try_again")
        }
    }
    var symbol: String {
        switch self { case .working: return "…"; case .invalid, .changed: return "!"; default: return "✓" }
    }
}

enum MarkdownEdit: Int, CaseIterable {
    case bold, italic, code, link, heading, bullet, task
    var title: String {
        switch self {
        case .bold: return tr("document.bold")
        case .italic: return tr("document.italic")
        case .code: return tr("document.inline_code")
        case .link: return tr("document.insert_link")
        case .heading: return tr("document.heading_1")
        case .bullet: return tr("document.bullet_list")
        case .task: return tr("document.task_list")
        }
    }
    func change(in text: String, selection: NSRange) -> (TextChange, NSRange) {
        let source = text as NSString
        if [.heading, .bullet, .task].contains(self) {
            let range = TextTools.lineRange(selection, in: source)
            let prefix = self == .heading ? "# " : self == .task ? "- [ ] " : "- "
            let value = TextTools.lines(source.substring(with: range)).map { prefix + $0.body + $0.ending }.joined()
            return (TextChange(range: range, text: value), NSRange(location: range.location + prefix.utf16.count, length: 0))
        }
        let value = source.substring(with: selection)
        if self == .link {
            let label = value.isEmpty ? tr("document.text") : value
            let replacement = "[" + label + "](https://)"
            return (TextChange(range: selection, text: replacement), value.isEmpty ? NSRange(location: selection.location + 1, length: (label as NSString).length) : NSRange(location: selection.location + (label as NSString).length + 3, length: 8))
        }
        let marker = self == .bold ? "**" : self == .italic ? "*" : "`"
        return (TextChange(range: selection, text: marker + value + marker), NSRange(location: selection.location + marker.utf16.count, length: selection.length))
    }
}

extension EditorController {
    var markdownMode: MarkdownViewMode {
        guard activeDocument.syntax == .markdown else { return .source }
        return activeDocument.markdownView ?? MarkdownViewMode(rawValue: UserDefaults.standard.integer(forKey: "markdownDefaultView")) ?? .source
    }
    func setupDocumentArea() {
        documentBar.drawsBottomLine = true
        documentContent.isVertical = true; documentContent.dividerStyle = .thin
        for view in [documentBar, documentContent] { view.translatesAutoresizingMaskIntoConstraints = false; documentHost.addSubview(view) }
        documentBarHeight = documentBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            documentBar.leadingAnchor.constraint(equalTo: documentHost.leadingAnchor), documentBar.trailingAnchor.constraint(equalTo: documentHost.trailingAnchor), documentBar.topAnchor.constraint(equalTo: documentHost.topAnchor), documentBarHeight,
            documentContent.leadingAnchor.constraint(equalTo: documentHost.leadingAnchor), documentContent.trailingAnchor.constraint(equalTo: documentHost.trailingAnchor), documentContent.topAnchor.constraint(equalTo: documentBar.bottomAnchor), documentContent.bottomAnchor.constraint(equalTo: documentHost.bottomAnchor)
        ])
        editingSplit.autoresizingMask = [.width, .height]; documentContent.addSubview(editingSplit)
        documentModes.segmentCount = 3; documentModes.trackingMode = .selectOne; documentModes.segmentStyle = .rounded; documentModes.controlSize = .small; documentModes.font = .systemFont(ofSize: 11)
        documentModes.target = self; documentModes.action = #selector(changeMarkdownMode(_:))
        plistStorage.controlSize = .small; plistStorage.font = .systemFont(ofSize: 11); plistStorage.target = self; plistStorage.action = #selector(choosePlistStorage(_:))
        for button in [formatButton, validateButton] { button.bezelStyle = .rounded; button.controlSize = .small; button.font = .systemFont(ofSize: 11); button.target = self }
        formatButton.action = #selector(formatDocument); validateButton.action = #selector(validateDocument)
        for view in [documentKind, documentModes, plistStorage, formatButton, validateButton, formatStatus] { view.translatesAutoresizingMaskIntoConstraints = false; documentBar.addSubview(view) }
        NSLayoutConstraint.activate([
            documentKind.leadingAnchor.constraint(equalTo: documentBar.leadingAnchor, constant: 12), documentKind.centerYAnchor.constraint(equalTo: documentBar.centerYAnchor), documentKind.widthAnchor.constraint(equalToConstant: 66),
            documentModes.leadingAnchor.constraint(equalTo: documentKind.trailingAnchor, constant: 8), documentModes.centerYAnchor.constraint(equalTo: documentBar.centerYAnchor),
            plistStorage.leadingAnchor.constraint(equalTo: documentKind.trailingAnchor, constant: 8), plistStorage.centerYAnchor.constraint(equalTo: documentBar.centerYAnchor), plistStorage.widthAnchor.constraint(equalToConstant: 120),
            formatButton.trailingAnchor.constraint(equalTo: validateButton.leadingAnchor, constant: -6), formatButton.centerYAnchor.constraint(equalTo: documentBar.centerYAnchor),
            validateButton.trailingAnchor.constraint(equalTo: documentBar.trailingAnchor, constant: -10), validateButton.centerYAnchor.constraint(equalTo: documentBar.centerYAnchor),
            formatStatus.trailingAnchor.constraint(equalTo: formatButton.leadingAnchor, constant: -8), formatStatus.widthAnchor.constraint(lessThanOrEqualToConstant: 180), formatStatus.centerYAnchor.constraint(equalTo: documentBar.centerYAnchor)
        ])
        formatStatus.lineBreakMode = .byTruncatingTail
    }
    func refreshDocumentArea() {
        guard documentBarHeight != nil, !documents.isEmpty else { return }
        let syntax = activeDocument.syntax, markdown = syntax == .markdown
        let structured = [.plist, .xml, .json].contains(syntax)
        documentBarHeight.constant = markdown || structured ? 32 : 0; documentBar.isHidden = !markdown && !structured
        documentKind.stringValue = syntax.title
        documentModes.isHidden = !markdown
        for mode in MarkdownViewMode.allCases { documentModes.setLabel(mode.title, forSegment: mode.rawValue) }
        documentModes.selectedSegment = markdownMode.rawValue
        documentModes.setAccessibilityLabel(tr("document.markdown_display_mode"))
        plistStorage.isHidden = syntax != .plist
        plistStorage.removeAllItems(); plistStorage.addItems(withTitles: PlistFormat.allCases.map(\.title)); plistStorage.selectItem(at: activeDocument.plistFormat == .binary ? 1 : 0)
        plistStorage.setAccessibilityLabel(tr("common.plist_save_format"))
        formatButton.title = tr("document.format"); validateButton.title = tr("document.validate")
        formatButton.isHidden = !structured; validateButton.isHidden = !structured
        formatButton.isEnabled = activeDocument.locked != true && formattingDocument != activeID
        validateButton.isEnabled = formattingDocument != activeID; plistStorage.isEnabled = activeDocument.locked != true
        refreshFormatFeedback()
        let mode = markdownMode
        if mode != .source && markdownPreview == nil {
            let preview = MarkdownPreviewView(frame: .zero)
            preview.autoresizingMask = [.width, .height]
            preview.onOpen = { [weak self] url in if url.isFileURL { self?.openURLs([url]) } else { NSWorkspace.shared.open(url) } }
            markdownPreview = preview
        }
        let desired: [NSView] = mode == .source ? [editingSplit] : mode == .preview ? [markdownPreview!] : [editingSplit, markdownPreview!]
        let changed = documentContent.subviews.count != desired.count || zip(documentContent.subviews, desired).contains { $0 !== $1 }
        if changed {
            documentContent.subviews.forEach { $0.removeFromSuperview() }
            desired.forEach { documentContent.addSubview($0) }
        }
        documentHost.layoutSubtreeIfNeeded(); layoutDocumentArea()
        if changed && desired.count == 2 { documentContent.setPosition((documentContent.isVertical ? documentContent.bounds.width : documentContent.bounds.height) / 2, ofDividerAt: 0) }
        applyEditorPreferences()
        if mode != .preview { synchronizeSplit() }
        scheduleMarkdownPreview(immediate: true)
    }
    func layoutDocumentArea() {
        guard documentBarHeight != nil, !documents.isEmpty else { return }
        documentHost.layoutSubtreeIfNeeded()
        let vertical = documentHost.bounds.width >= 680
        let changed = documentContent.isVertical != vertical
        documentContent.isVertical = vertical
        documentContent.adjustSubviews()
        if documentContent.subviews.count == 1 { documentContent.subviews[0].frame = documentContent.bounds }
        else if changed { documentContent.setPosition((vertical ? documentContent.bounds.width : documentContent.bounds.height) / 2, ofDividerAt: 0) }
        editingSplit.adjustSubviews()
        refreshFormatFeedback()
    }
    func showFormatFeedback(_ feedback: DocumentFeedback) { formatFeedback = (activeID, feedback); refreshFormatFeedback() }
    func refreshFormatFeedback() {
        guard let (id, feedback) = formatFeedback, id == activeID, [.plist, .xml, .json].contains(activeDocument.syntax) else { formatStatus.isHidden = true; formatStatus.stringValue = ""; return }
        formatStatus.isHidden = false
        formatStatus.stringValue = documentHost.bounds.width < 500 ? feedback.symbol : feedback.title
        if case .invalid(let error) = feedback { formatStatus.textColor = .systemRed; formatStatus.toolTip = feedback.title + "\n" + error.localizedDescription }
        else { formatStatus.textColor = .secondaryLabelColor; formatStatus.toolTip = feedback.title }
    }
    @objc func changeMarkdownMode(_ sender: NSSegmentedControl) { setMarkdownMode(MarkdownViewMode(rawValue: sender.selectedSegment) ?? .source) }
    func setMarkdownMode(_ mode: MarkdownViewMode) {
        guard activeDocument.syntax == .markdown else { return }
        stashPosition(); documents[activeIndex].markdownView = mode
        refreshDocumentArea(); refreshMainMenu(); scheduleRecovery()
        window?.makeFirstResponder(mode == .preview ? markdownPreview?.webView : textView)
    }
    @objc func selectMarkdownView(_ sender: NSMenuItem) { setMarkdownMode(MarkdownViewMode(rawValue: sender.tag) ?? .source) }
    @objc func cycleMarkdownPreview() { setMarkdownMode(markdownMode == .source ? .split : .source) }
    func scheduleMarkdownPreview(immediate: Bool = false) {
        previewJob?.cancel()
        guard activeDocument.syntax == .markdown, markdownMode != .source, let preview = markdownPreview else { return }
        let id = activeID
        let job = DispatchWorkItem { [weak self, weak preview] in
            guard let self = self, self.activeID == id, self.markdownMode != .source else { return }
            preview?.update(self.primaryEditor.string, directory: self.activeDocument.url?.deletingLastPathComponent(), dark: self.root.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua, documentID: id)
        }
        previewJob = job
        if immediate { job.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: job) }
    }
    @objc func markdownEdit(_ sender: NSMenuItem) {
        guard activeDocument.syntax == .markdown, activeDocument.locked != true, let tool = MarkdownEdit(rawValue: sender.tag) else { return }
        if markdownMode == .preview { setMarkdownMode(.source) }
        let change = tool.change(in: textView.string, selection: textView.selectedRange())
        if applyChange(change.0, name: tool.title) { textView.setSelectedRange(change.1); textView.scrollRangeToVisible(change.1) }
        window?.makeFirstResponder(textView)
    }
    @objc func formatDocument() { runDocumentFormat(format: true) }
    @objc func validateDocument() { runDocumentFormat(format: false) }
    func runDocumentFormat(format: Bool) {
        guard [.plist, .xml, .json].contains(activeDocument.syntax), !format || activeDocument.locked != true else { return }
        let text = textView.string, id = activeID, syntax = activeDocument.syntax, token = UUID()
        formattingDocument = id; formatOperation = token
        showFormatFeedback(.working); refreshDocumentArea()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () throws -> String in
                if format { return try DocumentFormats.formatted(text, syntax: syntax) }
                try DocumentFormats.validate(text, syntax: syntax); return text
            }
            DispatchQueue.main.async {
                guard let self = self, self.formatOperation == token else { return }
                self.formattingDocument = nil; self.formatOperation = nil
                guard self.activeID == id else { return }
                self.refreshDocumentArea()
                guard self.textView.string == text else { self.showFormatFeedback(.changed); return }
                switch result {
                case .success(let output):
                    if format { _ = self.applyChange(TextChange(range: NSRange(location: 0, length: (text as NSString).length), text: output), name: tr("common.format_document")) }
                    self.showFormatFeedback(format ? .formatted : .valid)
                case .failure(let error):
                    self.showFormatFeedback(.invalid(error))
                }
            }
        }
    }
    @objc func choosePlistStorage(_ sender: NSPopUpButton) { setPlistStorage(PlistFormat.allCases[max(0, sender.indexOfSelectedItem)], for: activeID) }
    @objc func selectPlistStorage(_ sender: NSMenuItem) { setPlistStorage(PlistFormat.allCases[sender.tag], for: activeID) }
    func setPlistStorage(_ format: PlistFormat?, for id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id }), documents[index].locked != true, documents[index].plistFormat != format else { return }
        let previous = documents[index].plistFormat
        buffers[id]?.undoManager?.registerUndo(withTarget: self) { $0.setPlistStorage(previous, for: id) }
        buffers[id]?.undoManager?.setActionName(tr("document.change_plist_save_format"))
        documents[index].plistFormat = format
        if id == activeID { refreshDocumentArea(); refreshStatus(); refreshTabs(); refreshWindowMetadata(); scheduleRecovery() }
    }
    func plistStorageMenu() -> NSMenu {
        let menu = NSMenu(title: tr("common.plist_save_format"))
        for (index, format) in PlistFormat.allCases.enumerated() {
            let entry = item(format.title, #selector(selectPlistStorage(_:)), tag: index)
            entry.state = activeDocument.plistFormat == format ? .on : .off; menu.addItem(entry)
        }
        return menu
    }
}
