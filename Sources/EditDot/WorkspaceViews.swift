// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import AppKit
import Darwin

final class FileNode {
    let url: URL
    let directory: Bool
    var children: [FileNode]?
    init(_ url: URL) {
        self.url = url
        directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
    func load() -> [FileNode] {
        if let children = children { return children }
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
        let nodes = urls.filter { !["node_modules", ".build", "__pycache__"].contains($0.lastPathComponent) }.map(FileNode.init).sorted {
            $0.directory != $1.directory ? $0.directory : $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        children = nodes
        return nodes
    }
}

final class FileBrowserView: ChromeView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = NSOutlineView()
    let title = label("", size: 11)
    let closeButton: NSButton
    var rootNode: FileNode?
    var onOpen: ((URL) -> Void)?
    var onClose: (() -> Void)?
    override init(frame frameRect: NSRect) {
        closeButton = symbolButton("xmark", tooltip: "", target: nil, action: nil)
        super.init(frame: frameRect)
        closeButton.target = self; closeButton.action = #selector(close)
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        outline.headerView = nil; outline.rowHeight = 25; outline.indentationPerLevel = 13
        outline.backgroundColor = Palette.chrome; outline.focusRingType = .none
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file")); column.width = 195
        outline.addTableColumn(column); outline.outlineTableColumn = column
        outline.dataSource = self; outline.delegate = self
        outline.target = self; outline.doubleAction = #selector(openSelected)
        scroll.documentView = outline
        addSubview(title); addSubview(closeButton); addSubview(scroll)
        activateCollapsibleConstraints([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), title.topAnchor.constraint(equalTo: topAnchor, constant: 9), title.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -3),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4), closeButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1), scroll.topAnchor.constraint(equalTo: topAnchor, constant: 33), scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        refreshLocalization()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func setFolder(_ url: URL) { rootNode = FileNode(url); title.stringValue = url.lastPathComponent; title.toolTip = url.path; outline.reloadData() }
    func clearFolder() { rootNode = nil; title.stringValue = ""; title.toolTip = nil; outline.reloadData() }
    func refreshLocalization() { closeButton.toolTip = tr("workspace.close_folder"); closeButton.setAccessibilityLabel(closeButton.toolTip); outline.setAccessibilityLabel(tr("workspace.folder")) }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { ((item as? FileNode) ?? rootNode)?.load().count ?? 0 }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ((item as? FileNode) ?? rootNode)!.load()[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FileNode else { return false }
        return node.directory && (try? node.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let cell = NSTableCellView()
        let text = label(node.url.lastPathComponent, size: 11, color: .labelColor)
        let icon = NSImageView(image: NSImage(systemSymbolName: node.directory ? "folder" : "doc.text", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = node.directory ? Palette.accent : .tertiaryLabelColor; icon.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text); cell.addSubview(icon); cell.textField = text; cell.imageView = icon; cell.toolTip = node.url.path
        NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 13), icon.heightAnchor.constraint(equalToConstant: 14), text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    @objc func openSelected() {
        guard outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
        if node.directory { outline.isItemExpanded(node) ? outline.collapseItem(node) : outline.expandItem(node) }
        else { onOpen?(node.url) }
    }
    @objc func close() { onClose?() }
}

struct FileSearchHit {
    var documentID: UUID?
    var url: URL?
    var filename: String
    var range: NSRange
    var line: Int
    var excerpt: String
    var matched: String
}

final class SearchCancellation {
    private let lock = NSLock()
    private var stopped = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
}

struct FileSearchReport {
    var hits: [FileSearchHit] = []
    var scanned = 0
    var skipped = 0
    var limited = false
    var cancelled = false
}

enum FileSearch {
    static func hits(in document: EditorDocument, query: String, matchCase: Bool, regex: Bool, wholeWord: Bool, limit: Int = 5000, searchResult: SearchResult? = nil) -> [FileSearchHit] {
        let result = searchResult ?? SearchResult.find(query, in: document.content, matchCase: matchCase, regex: regex, wholeWord: wholeWord)
        let source = document.content as NSString, index = TextIndex(document.content)
        return result.matches.prefix(limit).map { match in
            let line = index.line(at: match.range.location)
            let range = source.lineRange(for: NSRange(location: match.range.location, length: 0))
            let preview = source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            return FileSearchHit(documentID: document.id, url: document.url, filename: document.title, range: match.range, line: line + 1, excerpt: String(preview.prefix(300)), matched: source.substring(with: match.range))
        }
    }
    static func scan(folder: URL?, documents: [EditorDocument], query: String, matchCase: Bool, regex: Bool, wholeWord: Bool, filters: String, recursive: Bool, cancellation: SearchCancellation) -> FileSearchReport {
        var report = FileSearchReport(), bytes = 0
        let patterns = filters.split(whereSeparator: { $0 == ";" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        func allowed(_ name: String) -> Bool { patterns.isEmpty || patterns.contains { fnmatch($0, name, FNM_CASEFOLD) == 0 } }
        func append(_ document: EditorDocument) {
            report.scanned += 1
            let search = SearchResult.find(query, in: document.content, matchCase: matchCase, regex: regex, wholeWord: wholeWord, cancelled: { cancellation.cancelled })
            if search.timedOut { report.skipped += 1; report.cancelled = cancellation.cancelled; return }
            let found = hits(in: document, query: query, matchCase: matchCase, regex: regex, wholeWord: wholeWord, limit: 5001, searchResult: search)
            report.hits += found.prefix(max(0, 5000 - report.hits.count))
            if report.hits.count >= 5000 { report.limited = true }
        }
        guard let folder = folder else {
            for document in documents where allowed(document.title) {
                if cancellation.cancelled { report.cancelled = true; break }
                append(document)
                if report.limited { break }
            }
            return report
        }
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in report.skipped += 1; return !cancellation.cancelled }) else { return report }
        for case let url as URL in enumerator {
            if cancellation.cancelled { report.cancelled = true; break }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]) else { report.skipped += 1; continue }
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isDirectory == true {
                if !recursive || ["node_modules", ".build", "__pycache__"].contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, allowed(url.lastPathComponent) else { continue }
            let size = values.fileSize ?? 0
            if size > 8 * 1024 * 1024 { report.skipped += 1; continue }
            if report.scanned >= 10000 || bytes + size > 128 * 1024 * 1024 { report.limited = true; break }
            bytes += size
            if let open = documents.first(where: { $0.url?.standardizedFileURL == url.standardizedFileURL }) { append(open) }
            else if let document = try? EditorDocument.open(url) { append(document) }
            else { report.skipped += 1 }
            if report.limited { break }
        }
        return report
    }
}

final class ResultTableView: NSTableView {
    var onActivate: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onActivate?() }
        else { super.keyDown(with: event) }
    }
}

final class SearchResultsView: ChromeView, NSTableViewDataSource, NSTableViewDelegate {
    let table = ResultTableView()
    let title = label("", size: 11)
    let closeButton: NSButton
    let cancelButton: NSButton
    var hits: [FileSearchHit] = [] { didSet { table.reloadData() } }
    var onOpen: ((FileSearchHit) -> Void)?
    var onClose: (() -> Void)?
    var onCancel: (() -> Void)?
    override init(frame frameRect: NSRect) {
        closeButton = symbolButton("xmark", tooltip: "", target: nil, action: nil)
        cancelButton = symbolButton("stop.circle", tooltip: "", target: nil, action: nil)
        super.init(frame: frameRect)
        drawsTopLine = true
        closeButton.target = self; closeButton.action = #selector(close)
        cancelButton.target = self; cancelButton.action = #selector(cancel)
        cancelButton.isHidden = true
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.translatesAutoresizingMaskIntoConstraints = false
        table.headerView = nil; table.rowHeight = 24; table.backgroundColor = Palette.canvas; table.usesAlternatingRowBackgroundColors = false
        let location = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("location")); location.width = 205; location.minWidth = 115
        let preview = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("preview")); preview.width = 650; preview.minWidth = 150
        table.addTableColumn(location); table.addTableColumn(preview); table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(openSelected)
        table.onActivate = { [weak self] in self?.openSelected() }
        scroll.documentView = table
        addSubview(title); addSubview(closeButton); addSubview(cancelButton); addSubview(scroll)
        activateCollapsibleConstraints([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), title.topAnchor.constraint(equalTo: topAnchor, constant: 9), title.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -8),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7), closeButton.centerYAnchor.constraint(equalTo: title.centerYAnchor), cancelButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4), cancelButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.topAnchor.constraint(equalTo: topAnchor, constant: 33), scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        refreshLocalization()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func refreshLocalization() {
        closeButton.toolTip = tr("workspace.close_search_results"); closeButton.setAccessibilityLabel(closeButton.toolTip)
        cancelButton.toolTip = tr("workspace.stop_search"); cancelButton.setAccessibilityLabel(cancelButton.toolTip)
        table.setAccessibilityLabel(tr("workspace.search_results_double_click_or_press_return_to_open"))
    }
    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let hit = hits[row]
        let text = label(tableColumn?.identifier.rawValue == "location" ? "\(hit.filename):\(hit.line)" : hit.excerpt, size: 11, color: tableColumn?.identifier.rawValue == "location" ? .secondaryLabelColor : .labelColor)
        text.toolTip = hit.url?.path ?? hit.filename
        return text
    }
    @objc func openSelected() { let row = table.selectedRow; if hits.indices.contains(row) { onOpen?(hits[row]) } }
    @objc func close() { onClose?() }
    @objc func cancel() { onCancel?() }
}

private func activateCollapsibleConstraints(_ constraints: [NSLayoutConstraint]) {
    for constraint in constraints { constraint.priority = NSLayoutConstraint.Priority(999) }
    NSLayoutConstraint.activate(constraints)
}
