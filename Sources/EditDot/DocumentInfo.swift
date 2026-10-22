// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import AppKit

struct DocumentStatistics {
    let characters: Int
    let nonWhitespace: Int
    let lines: Int
    let utf8Bytes: Int
    let encodedBytes: Int?
    let selectionCharacters: Int?
    let selectionLines: Int?
    init(text: String, encoding: TextEncoding, selection: String?, plistFormat: PlistFormat? = nil) {
        characters = text.count
        nonWhitespace = text.reduce(into: 0) { if !$1.isWhitespace { $0 += 1 } }
        lines = TextIndex(linesIn: text).starts.count
        utf8Bytes = text.utf8.count
        encodedBytes = plistFormat == .binary ? (try? DocumentFormats.plistData(from: text, format: .binary))?.count : (try? encoding.encode(text))?.count
        selectionCharacters = selection?.count
        selectionLines = selection.map { TextIndex(linesIn: $0).starts.count }
    }
    static func size(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}

final class DocumentInfoController: NSWindowController, NSWindowDelegate {
    let snapshot: EditorDocument
    let selection: String?
    private let path = NSTextField(wrappingLabelWithString: "")
    private let state = label("", size: 11)
    private var names: [NSTextField] = []
    private var values: [NSTextField] = []
    private let done = NSButton()
    private(set) var statistics: DocumentStatistics?
    init(document: EditorDocument, selection: String?) {
        self.snapshot = document; self.selection = selection
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 430), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        let content = NSView(); panel.contentView = content
        path.stringValue = document.url?.path ?? document.title
        path.font = .systemFont(ofSize: 12, weight: .medium); path.isSelectable = true
        path.maximumNumberOfLines = 2; path.lineBreakMode = .byTruncatingMiddle
        path.toolTip = path.stringValue; path.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(path); content.addSubview(state)
        var rows: [[NSView]] = []
        for _ in 0..<8 {
            let name = label("", size: 12), value = label("—", size: 12, color: .labelColor)
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); value.isSelectable = true
            names.append(name); values.append(value); rows.append([name, value])
        }
        let grid = NSGridView(views: rows); grid.rowSpacing = 9; grid.columnSpacing = 28
        grid.column(at: 1).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(grid)
        done.bezelStyle = .rounded; done.keyEquivalent = "\r"; done.target = self; done.action = #selector(closeSheet)
        done.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(done)
        NSLayoutConstraint.activate([
            path.topAnchor.constraint(equalTo: content.topAnchor, constant: 18), path.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22), path.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            state.leadingAnchor.constraint(equalTo: path.leadingAnchor), state.topAnchor.constraint(equalTo: path.bottomAnchor, constant: 5), state.trailingAnchor.constraint(equalTo: path.trailingAnchor),
            grid.topAnchor.constraint(equalTo: state.bottomAnchor, constant: 19), grid.leadingAnchor.constraint(equalTo: path.leadingAnchor), grid.trailingAnchor.constraint(equalTo: path.trailingAnchor),
            done.topAnchor.constraint(greaterThanOrEqualTo: grid.bottomAnchor, constant: 18), done.trailingAnchor.constraint(equalTo: path.trailingAnchor), done.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16), done.widthAnchor.constraint(greaterThanOrEqualToConstant: 72)
        ])
        refreshLocalization()
        content.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: 420, height: content.fittingSize.height))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = DocumentStatistics(text: document.content, encoding: document.encoding, selection: selection, plistFormat: document.plistFormat)
            DispatchQueue.main.async { [weak self] in self?.statistics = result; self?.refreshLocalization() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func refreshLocalization() {
        window?.title = tr("details.document_details")
        path.stringValue = snapshot.url?.path ?? snapshot.title
        done.title = tr("details.done")
        state.stringValue = statistics == nil ? tr("details.counting") : snapshot.isDirty ? tr("details.current_content_includes_unsaved_changes") : tr("details.current_document_content")
        let titles = [tr("details.characters"), tr("details.non_whitespace"), tr("details.lines"), "UTF-8", tr("details.size_on_save"), tr("common.write_encoding"), tr("details.selected_characters"), tr("details.selected_lines")]
        for (field, title) in zip(names, titles) { field.stringValue = title }
        guard let stats = statistics else { return }
        let entries = [String(stats.characters), String(stats.nonWhitespace), String(stats.lines), DocumentStatistics.size(stats.utf8Bytes), stats.encodedBytes.map(DocumentStatistics.size) ?? tr("details.cannot_encode"), snapshot.plistFormat == .binary ? PlistFormat.binary.title : snapshot.encoding.title, stats.selectionCharacters.map(String.init) ?? "—", stats.selectionLines.map(String.init) ?? "—"]
        for (field, value) in zip(values, entries) { field.stringValue = value }
    }
    func present(relativeTo parent: NSWindow?) {
        guard let panel = window else { return }
        panel.appearance = parent?.appearance
        if let parent = parent { parent.beginSheet(panel) }
        else { showWindow(nil) }
    }
    @objc func closeSheet() {
        if let panel = window, let parent = panel.sheetParent { parent.endSheet(panel) }
        window?.orderOut(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { closeSheet(); return false }
    override func cancelOperation(_ sender: Any?) { closeSheet() }
}
