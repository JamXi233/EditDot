// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import AppKit

struct PickerEntry {
    var title: String
    var detail: String
    var shortcut = ""
    var keywords = ""
    var action: () -> Void
}

final class PickerPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { close() }
}

final class QuickPicker: NSWindowController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let search = NSSearchField()
    let table = ResultTableView()
    let empty = label("", size: 12)
    let entries: [PickerEntry]
    var filtered: [PickerEntry] = []
    init(title: String, prompt: String, entries: [PickerEntry]) {
        self.entries = entries
        let panel = PickerPanel(contentRect: NSRect(x: 0, y: 0, width: 530, height: 354), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = title; panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        let content = NSView(); panel.contentView = content
        search.placeholderString = prompt; search.font = .systemFont(ofSize: 13); search.focusRingType = .none; search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(search)
        search.setAccessibilityLabel(prompt)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(scroll)
        table.headerView = nil; table.rowHeight = 42; table.backgroundColor = Palette.canvas; table.focusRingType = .none
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry")); column.width = 500
        table.addTableColumn(column); table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(choose)
        table.onActivate = { [weak self] in self?.choose() }; scroll.documentView = table
        empty.stringValue = tr("picker.no_matching_items"); content.addSubview(empty)
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14), search.topAnchor.constraint(equalTo: content.topAnchor, constant: 13), search.heightAnchor.constraint(equalToConstant: 28),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor), scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 11), scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: content.centerXAnchor), empty.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 32)
        ])
        filter("")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func present(relativeTo parent: NSWindow?) {
        window?.appearance = parent?.appearance
        if let parent = parent, let window = window {
            window.setFrameOrigin(NSPoint(x: parent.frame.midX - window.frame.width / 2, y: parent.frame.maxY - window.frame.height - 85))
        } else { window?.center() }
        showWindow(nil); window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(search)
    }
    func filter(_ query: String) {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        filtered = entries.filter { entry in words.allSatisfy { (entry.title + " " + entry.detail + " " + entry.keywords).range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil } }
        table.reloadData(); empty.isHidden = !filtered.isEmpty
        if !filtered.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }
    func controlTextDidChange(_ obj: Notification) { filter(search.stringValue) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { choose(); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { close(); return true }
        if commandSelector == #selector(NSResponder.moveDown(_:)) || commandSelector == #selector(NSResponder.moveUp(_:)) {
            guard !filtered.isEmpty else { return true }
            let offset = commandSelector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = max(0, min(filtered.count - 1, table.selectedRow + offset))
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row); return true
        }
        return false
    }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = filtered[row], view = NSView()
        let title = label(entry.title, size: 12, color: .labelColor), detail = label(entry.detail, size: 10.5), key = label(entry.shortcut, size: 11)
        for item in [title, detail, key] { view.addSubview(item) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14), title.topAnchor.constraint(equalTo: view.topAnchor, constant: 5), title.trailingAnchor.constraint(lessThanOrEqualTo: key.leadingAnchor, constant: -10),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor), detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2), detail.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            key.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14), key.centerYAnchor.constraint(equalTo: title.centerYAnchor)
        ])
        return view
    }
    @objc func choose() {
        let row = table.selectedRow
        guard filtered.indices.contains(row) else { return }
        let action = filtered[row].action
        close(); action()
    }
    func windowDidResignKey(_ notification: Notification) { close() }
}

struct DocumentSymbol {
    var name: String
    var kind: String
    var line: Int
    var range: NSRange
}

enum DocumentOutline {
    static func symbols(in text: String, syntax: Syntax) -> [DocumentSymbol] {
        guard text.utf8.count <= 2 * 1024 * 1024 else { return [] }
        let source = text as NSString, index = TextIndex(linesIn: text)
        var rules: [(String, String, Int)]
        switch syntax {
        case .markdown: rules = [(#"(?m)^#{1,6}[\t ]+([^\r\n]+)"#, tr("picker.heading"), 1)]
        case .plist: rules = [(#"<key>([^<]+)</key>"#, tr("picker.key"), 1)]
        case .xml, .html: rules = [(#"<([a-zA-Z][\w:.-]*)\b[^>]*>"#, tr("picker.element"), 1)]
        case .json, .yaml, .toml, .ini:
            rules = [(#"(?m)^[\t ]*\"([^\"\r\n]+)\"[\t ]*:"#, tr("common.property"), 1), (#"(?m)^[\t ]*([\p{L}_][\p{L}\p{N}_.-]*)[\t ]*[:=]"#, tr("common.property"), 1), (#"(?m)^[\t ]*\[([^\]\r\n]+)\]"#, tr("picker.section"), 1)]
        default:
            rules = [(#"(?m)^[\t ]*(?:(?:public|private|internal|fileprivate|open|static|final|override|async|export|default|abstract|pub)[\t ]+)*(class|struct|enum|interface|protocol|extension|func|function|def|fn|trait|type|module)[\t ]+([\p{L}_][\p{L}\p{N}_]*)"#, "", 2), (#"(?m)^[\t ]*(?:const|let|var)[\t ]+([\p{L}_][\p{L}\p{N}_]*)[\t ]*=[^\r\n]{0,160}=>"#, "function", 1), (#"(?mi)^[\t ]*CREATE[\t ]+(?:OR[\t ]+REPLACE[\t ]+)?(?:TABLE|VIEW|FUNCTION|PROCEDURE)[\t ]+([\w.]+)"#, "SQL", 1)]
        }
        var symbols: [DocumentSymbol] = []
        for (pattern, kind, nameGroup) in rules {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            expression.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, stop in
                if symbols.count >= 2000 { stop.pointee = true; return }
                guard let match = match else { return }
                let range = match.range(at: nameGroup)
                symbols.append(DocumentSymbol(name: source.substring(with: range), kind: kind.isEmpty ? source.substring(with: match.range(at: 1)) : kind, line: index.line(at: range.location) + 1, range: range))
            }
        }
        return symbols.sorted { $0.range.location < $1.range.location }
    }
}
