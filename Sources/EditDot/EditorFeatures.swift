// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import AppKit

extension EditorController {
    var indentWidth: Int { let width = UserDefaults.standard.integer(forKey: "indentWidth"); return [2, 4, 8].contains(width) ? width : 4 }
    var usesTabs: Bool { UserDefaults.standard.bool(forKey: "usesTabs") }
    var effectiveQuery: String { extendedSearch && regexButton.state != .on ? TextTools.expandEscapes(findField.stringValue) : findField.stringValue }
    var effectiveReplacement: String { extendedSearch && regexButton.state != .on ? TextTools.expandEscapes(replacementField.stringValue) : replacementField.stringValue }
    var effectiveScope: NSRange? {
        guard selectionOnly else { return nil }
        let length = (textView.string as NSString).length
        let range = searchScope ?? textView.selectedRange()
        return NSRange(location: min(length, range.location), length: min(range.length, max(0, length - range.location)))
    }

    func installPanel(_ panel: NSView, in host: NSView) {
        panel.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: host.leadingAnchor), panel.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            panel.topAnchor.constraint(equalTo: host.topAnchor), panel.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
    }
    func setupWorkspace() {
        for view in [browserHost, documentHost, resultsHost] { view.translatesAutoresizingMaskIntoConstraints = false; workspace.addSubview(view) }
        browserWidth = browserHost.widthAnchor.constraint(equalToConstant: 0)
        resultsHeight = resultsHost.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            browserHost.leadingAnchor.constraint(equalTo: workspace.leadingAnchor), browserHost.topAnchor.constraint(equalTo: workspace.topAnchor), browserHost.bottomAnchor.constraint(equalTo: workspace.bottomAnchor), browserWidth,
            documentHost.leadingAnchor.constraint(equalTo: browserHost.trailingAnchor), documentHost.trailingAnchor.constraint(equalTo: workspace.trailingAnchor), documentHost.topAnchor.constraint(equalTo: workspace.topAnchor), documentHost.bottomAnchor.constraint(equalTo: resultsHost.topAnchor),
            resultsHost.leadingAnchor.constraint(equalTo: browserHost.trailingAnchor), resultsHost.trailingAnchor.constraint(equalTo: workspace.trailingAnchor), resultsHost.bottomAnchor.constraint(equalTo: workspace.bottomAnchor), resultsHeight
        ])
        setupDocumentArea()
        setupSplitEditor()
        if let folder = folderURL { browser.setFolder(folder) }
        dropObserver = NotificationCenter.default.addObserver(forName: .editorDroppedFiles, object: nil, queue: .main) { [weak self] note in
            guard let self = self, let editor = note.object as? EditorTextView, editor === self.textView, let urls = note.userInfo?["urls"] as? [URL] else { return }
            self.openURLs(urls)
        }
        if let data = UserDefaults.standard.data(forKey: "lastMacro"), data.count <= 6 * 1024 * 1024,
           let steps = try? JSONDecoder().decode([MacroEdit].self, from: data), steps.count <= 2000,
           steps.allSatisfy({ $0.length >= 0 && (-64 * 1024 * 1024...64 * 1024 * 1024).contains($0.offset) }) { recordedMacro = steps }
        resizeWorkspace()
    }
    func resizeWorkspace() {
        guard browserWidth != nil, resultsHeight != nil else { return }
        let showBrowser = folderVisible && folderURL != nil && groupWidth >= 760
        browserWidth.constant = showBrowser ? 200 : 0
        browserHost.isHidden = !showBrowser
        if browserLoaded || showBrowser { browser.isHidden = !showBrowser }
        resultsHeight.constant = resultsVisible ? min(185, max(100, workspace.bounds.height * 0.42)) : 0
        resultsHost.isHidden = !resultsVisible
        if resultsLoaded || resultsVisible { results.isHidden = !resultsVisible }
        synchronizeSplit()
        layoutDocumentArea()
    }
    func setFolder(_ url: URL) { folderURL = url; folderVisible = true; browser.setFolder(url); resizeWorkspace(); scheduleRecovery(); refreshMainMenu() }
    @objc func openFolder() {
        let panel = NSOpenPanel(); panel.title = tr("editor.open_folder"); panel.prompt = tr("common.open")
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.directoryURL = folderURL
        if panel.runModal() == .OK, let url = panel.url { setFolder(url) }
    }
    @objc func toggleFolder() { if folderURL == nil { openFolder() } else { folderVisible.toggle(); resizeWorkspace(); refreshMainMenu() } }
    @objc func closeFolder() {
        folderURL = nil; folderVisible = false
        browser.clearFolder(); resizeWorkspace(); persistSession()
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(textView)
        refreshMainMenu()
    }
    @objc func refreshFolder() { if let url = folderURL { browser.setFolder(url) } }
    @objc func hideResults() { fileSearchCancellation?.cancel(); resultsVisible = false; resizeWorkspace(); refreshMainMenu() }
    @objc func toggleResults() { resultsVisible.toggle(); resizeWorkspace(); refreshMainMenu() }

    func rememberRecent(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: "recentFiles") ?? []
        paths.removeAll { $0 == url.path }; paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(15)), forKey: "recentFiles")
        refreshMainMenu()
    }
    @objc func openRecent(_ sender: NSMenuItem) { if let path = sender.representedObject as? String { openURLs([URL(fileURLWithPath: path)]) } }
    @objc func clearRecent() { UserDefaults.standard.removeObject(forKey: "recentFiles"); refreshMainMenu() }
    @objc func saveAll() {
        if let manager = workspaceHost?.manager {
            let original = manager.activeEditor
            for group in manager.windows.flatMap(\.groups) {
                for document in group.documents.filter(\.isDirty) { if !group.save(document.id) { return } }
            }
            if let original = original { original.workspaceHost?.focus(original, makeResponder: true) }
            manager.persist()
        } else {
            let original = activeID
            for document in documents.filter(\.isDirty) { if !save(document.id) { return } }
            activateDocument(original)
        }
    }
    @objc func closeOtherTabs() { closeTabs(documents.filter { $0.id != activeID && $0.pinned != true }.map(\.id)) }
    @objc func closeAllTabs() { closeTabs(documents.filter { $0.pinned != true }.map(\.id)) }
    func closeTabs(_ ids: [UUID]) {
        for id in ids {
            let count = documents.count
            closeDocument(id)
            if documents.contains(where: { $0.id == id }) || (count == 1 && documents[0].id == id) { break }
        }
    }
    @objc func reopenClosedTab() {
        guard var document = closedDocuments.popLast() else { return }
        if let url = document.url, var fresh = try? EditorDocument.open(url) { fresh.pinned = document.pinned; fresh.markdownView = document.markdownView; document = fresh }
        if let existing = documents.first(where: { $0.url == document.url && $0.url != nil }) { activateDocument(existing.id); return }
        if let url = document.url, !FileManager.default.fileExists(atPath: url.path) { document.requiresSave = true }
        documents.append(document); activateDocument(document.id)
    }
    @objc func revealInFinder() { if let url = activeDocument.url { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    @objc func copyFilePath() {
        guard let url = activeDocument.url else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string)
    }
    @objc func selectDocument(_ sender: NSMenuItem) { if let value = sender.representedObject as? String, let id = UUID(uuidString: value) { activateDocument(id) } }
    @objc func completeWord() { if activeDocument.locked != true { window?.makeFirstResponder(textView); textView.complete(nil) } }
    func tabMenu(_ id: UUID) -> NSMenu {
        activateDocument(id)
        let menu = NSMenu()
        menu.addItem(item(tr("common.save"), #selector(saveDocument)))
        menu.addItem(item(tr("common.close_tab"), #selector(closeActiveDocument)))
        menu.addItem(item(tr("common.keep_current_and_pinned_documents"), #selector(closeOtherTabs)))
        menu.addItem(item(tr("common.close_all_unpinned_tabs"), #selector(closeAllTabs)))
        extendTabMenu(menu)
        menu.addItem(.separator())
        menu.addItem(item(tr("common.copy_file_path"), #selector(copyFilePath)))
        menu.addItem(item(tr("common.reveal_in_finder"), #selector(revealInFinder)))
        return menu
    }
    @objc func toggleReadOnly() {
        documents[activeIndex].locked = activeDocument.locked != true
        applyEditorPreferences(); refreshStatus(); scheduleRecovery(); refreshMainMenu()
        if findVisible { refreshFindStatus() }
    }
    @objc func reloadFromDisk() { reloadFile(encoding: nil) }
    @objc func reloadWithEncoding(_ sender: NSMenuItem) { reloadFile(encoding: TextEncoding.allCases[sender.tag]) }
    func reloadFile(encoding: TextEncoding?) {
        guard let url = activeDocument.url, confirmSave(activeID) else { return }
        do {
            var document = try EditorDocument.open(url, encoding: encoding)
            document.id = activeID; document.bookmarks = activeDocument.bookmarks; document.locked = activeDocument.locked; document.pinned = activeDocument.pinned; document.markdownView = activeDocument.markdownView
            documents[activeIndex] = document
            buffers.removeValue(forKey: activeID)
            activateDocument(activeID)
        } catch { presentError(error, operation: tr("editor.could_not_reload_file"), filename: url.lastPathComponent) }
    }
    @objc func showExportSession() {
        let panel = NSSavePanel(); panel.title = tr("editor.export_session"); panel.prompt = tr("editor.export"); panel.nameFieldStringValue = "Workspace.editdot-session"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try exportSession(to: url) } catch { presentError(error, operation: tr("editor.could_not_export_session")) }
    }
    func exportSession(to url: URL) throws {
        persistSession()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(EditorSession(documents: documents, activeID: activeID, folderURL: folderURL)).write(to: url, options: .atomic)
    }
    @objc func showImportSession() {
        let panel = NSOpenPanel(); panel.title = tr("editor.import_session"); panel.prompt = tr("editor.import"); panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try importSession(from: url) } catch { presentError(error, operation: tr("editor.could_not_import_session")) }
    }
    func importSession(from url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count <= 128 * 1024 * 1024 else { throw FileError.tooLarge }
        let session = try JSONDecoder().decode(EditorSession.self, from: data)
        guard !session.documents.isEmpty, session.documents.count <= 200, session.folderURL?.isFileURL != false,
              session.documents.allSatisfy({ $0.content.utf8.count <= 32 * 1024 * 1024 && $0.selectionLocation >= 0 && $0.selectionLength >= 0 && $0.scrollY.isFinite && $0.url?.isFileURL != false }) else { throw FileError.unsupported }
        var target: UUID?
        for var document in session.documents {
            if let existing = documents.first(where: { $0.id == document.id || ($0.url != nil && $0.url == document.url) }) { if document.id == session.activeID { target = existing.id }; continue }
            if !document.isDirty, let url = document.url {
                if let fresh = try? EditorDocument.open(url, encoding: document.encoding) { document.content = fresh.content; document.savedContent = fresh.content; document.diskData = fresh.diskData; document.plistFormat = fresh.plistFormat; document.savedPlistFormat = fresh.savedPlistFormat }
                else { document.requiresSave = true }
            }
            document.normalizeBookmarks()
            documents.append(document)
            if document.id == session.activeID { target = document.id }
        }
        if let folder = session.folderURL { setFolder(folder) }
        activateDocument(target ?? documents.last!.id)
    }

    @discardableResult func applyChange(_ change: TextChange, name: String) -> Bool {
        guard activeDocument.locked != true, change.range.location >= 0, NSMaxRange(change.range) <= (textView.string as NSString).length else { return false }
        let before = textView.string
        if (before as NSString).substring(with: change.range) == change.text { return false }
        textView.breakUndoCoalescing()
        textView.literalInsertion = true
        textView.insertText(change.text, replacementRange: change.range)
        textView.literalInsertion = false
        textView.breakUndoCoalescing()
        textView.undoManager?.setActionName(name)
        return textView.string != before
    }
    @objc func textTool(_ sender: NSMenuItem) { if let tool = TextTool(rawValue: sender.tag) { performTextTool(tool) } }
    @objc func columnEditor() {
        guard activeDocument.locked != true else { return }
        let alert = NSAlert(); alert.messageText = tr("common.fill_by_column")
        alert.informativeText = tr("editor.applies_to_selected_lines_short_lines_are_padded_columns_count_characters")
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 136))
        let column = NSTextField(), width = NSTextField(), value = NSTextField()
        for (index, entry) in [(tr("editor.starting_column_from_1"), column), (tr("editor.characters_to_replace_0_to_insert"), width), (tr("editor.insert_text"), value)].enumerated() {
            let caption = NSTextField(labelWithString: entry.0); caption.frame = NSRect(x: 0, y: 111 - index * 34, width: 210, height: 20); caption.font = .systemFont(ofSize: 11)
            entry.1.frame = NSRect(x: 212, y: 110 - index * 34, width: 128, height: 24)
            view.addSubview(caption); view.addSubview(entry.1)
        }
        column.stringValue = "1"; width.stringValue = "0"
        let numbers = NSButton(checkboxWithTitle: tr("editor.append_sequential_numbers_from_1"), target: nil, action: nil); numbers.frame = NSRect(x: 0, y: 3, width: 340, height: 24); view.addSubview(numbers)
        alert.accessoryView = view; alert.addButton(withTitle: tr("editor.apply")); alert.addButton(withTitle: tr("common.cancel")); alert.window.initialFirstResponder = value
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let start = Int(column.stringValue), let count = Int(width.stringValue), (1...10000).contains(start), (0...10000).contains(count), !value.stringValue.contains("\n"), !value.stringValue.contains("\r") else { presentError(nil, operation: tr("editor.invalid_column_parameters")); return }
        let change = TextTools.columnChange(text: textView.string, selection: textView.selectedRange(), column: start - 1, length: count, value: value.stringValue, firstNumber: numbers.state == .on ? 1 : nil)
        if applyChange(change, name: tr("common.fill_by_column")) { textView.setSelectedRange(NSRange(location: change.range.location, length: (change.text as NSString).length)) }
    }
    func performTextTool(_ tool: TextTool) {
        guard activeDocument.locked != true else { return }
        do {
            let selection = textView.selectedRange()
            if tool == .duplicate {
                let result = TextTools.duplicateLines(in: textView.string, selection: selection, fallbackEnding: textView.newline)
                if applyChange(result.change, name: tool.title) {
                    textView.setSelectedRange(result.selection)
                    textView.scrollRangeToVisible(result.selection)
                }
                return
            }
            let change = try TextTools.change(tool, text: textView.string, selection: selection, syntax: activeDocument.syntax, width: indentWidth, tabs: usesTabs)
            if applyChange(change, name: tool.title) {
                if [.indent, .outdent, .comment, .moveUp, .moveDown].contains(tool) || selection.length > 0 { textView.setSelectedRange(NSRange(location: change.range.location, length: (change.text as NSString).length)) }
            }
        } catch let error as TextConversionError {
            presentError(nil, operation: tr("editor.could_not_convert_text"), detail: error.localizedDescription)
        } catch { presentError(nil, operation: tr("editor.invalid_json"), detail: tr("editor.check_the_json_syntax_in_the_selection_or_document")) }
    }
    @objc func insertContent(_ sender: NSMenuItem) {
        guard activeDocument.locked != true, let content = TextInsertion(rawValue: sender.tag) else { return }
        _ = applyChange(TextChange(range: textView.selectedRange(), text: content.value()), name: content.title)
    }
    @objc func selectIndentWidth(_ sender: NSMenuItem) { UserDefaults.standard.set(sender.tag, forKey: "indentWidth"); applyEditorPreferences(); refreshMainMenu() }
    @objc func toggleTabs() { UserDefaults.standard.set(!usesTabs, forKey: "usesTabs"); applyEditorPreferences(); refreshMainMenu() }
    @objc func toggleWhitespace() { UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "whitespace"), forKey: "whitespace"); applyEditorPreferences(); refreshMainMenu() }
    @objc func toggleAutoClose() { UserDefaults.standard.set(!(UserDefaults.standard.object(forKey: "closeBrackets") as? Bool ?? true), forKey: "closeBrackets"); applyEditorPreferences(); refreshMainMenu() }
    func highlightBrackets() {
        guard let manager = textView.layoutManager else { return }
        let range = NSRange(location: 0, length: (textView.string as NSString).length)
        for (editor, _, _) in editorPanes { editor.layoutManager?.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range) }
        guard textView.selectedRange().length == 0 else { return }
        for bracket in TextTools.bracketPair(in: textView.string, at: textView.selectedRange().location) { manager.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, forCharacterRange: bracket) }
    }
    @objc func jumpToBracket() {
        let ranges = TextTools.bracketPair(in: textView.string, at: textView.selectedRange().location)
        guard ranges.count == 2 else { NSSound.beep(); return }
        let location = textView.selectedRange().location
        let target = location == ranges[0].location || location == ranges[0].location + 1 ? ranges[1] : ranges[0]
        textView.setSelectedRange(NSRange(location: target.location, length: 0)); textView.scrollRangeToVisible(target)
    }

    @objc func toggleCurrentBookmark() { toggleBookmark(at: textView.selectedRange().location) }
    func toggleBookmark(at location: Int) {
        let index = TextIndex(textView.string), anchor = index.starts[index.line(at: location)]
        var anchors = activeDocument.bookmarks ?? []
        if anchors.contains(anchor) { anchors.removeAll { $0 == anchor } } else { anchors.append(anchor) }
        documents[activeIndex].bookmarks = anchors.sorted(); ruler?.bookmarks = anchors; scheduleRecovery()
    }
    @objc func nextBookmark() { navigateBookmark(forward: true) }
    @objc func previousBookmark() { navigateBookmark(forward: false) }
    func navigateBookmark(forward: Bool) {
        let anchors = (activeDocument.bookmarks ?? []).sorted()
        guard !anchors.isEmpty else { NSSound.beep(); return }
        let location = textView.selectedRange().location
        let target = forward ? (anchors.first { $0 > location } ?? anchors[0]) : (anchors.last { $0 < location } ?? anchors.last!)
        let range = NSRange(location: min(target, (textView.string as NSString).length), length: 0)
        window?.makeFirstResponder(textView); textView.setSelectedRange(range); textView.scrollRangeToVisible(range)
    }
    @objc func clearBookmarks() { documents[activeIndex].bookmarks = []; ruler?.bookmarks = []; scheduleRecovery() }
    @objc func markMatches() {
        let index = TextIndex(textView.string)
        let matches = SearchResult.find(effectiveQuery, in: textView.string, matchCase: caseButton.state == .on, regex: regexButton.state == .on, wholeWord: wholeWord, range: effectiveScope)
        let anchors = Set((activeDocument.bookmarks ?? []) + matches.matches.map { index.starts[index.line(at: $0.range.location)] })
        documents[activeIndex].bookmarks = anchors.sorted(); ruler?.bookmarks = anchors.sorted(); scheduleRecovery()
    }
    @objc func copyBookmarkedLines() {
        let source = textView.string as NSString
        let text = (activeDocument.bookmarks ?? []).sorted().filter { $0 <= source.length }.map { source.substring(with: source.lineRange(for: NSRange(location: $0, length: 0))) }.joined()
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    @objc func removeBookmarkedLines() {
        guard activeDocument.locked != true else { return }
        let source = NSMutableString(string: textView.string)
        for anchor in (activeDocument.bookmarks ?? []).sorted(by: >) where anchor <= source.length { source.deleteCharacters(in: source.lineRange(for: NSRange(location: anchor, length: 0))) }
        if applyChange(TextChange(range: NSRange(location: 0, length: (textView.string as NSString).length), text: source as String), name: tr("common.remove_marked_lines")) { clearBookmarks() }
    }

    @objc func toggleWholeWord() { wholeWord.toggle(); findPanel?.syncOptions(); scheduleSearch(); refreshMainMenu() }
    @objc func toggleExtendedSearch() { extendedSearch.toggle(); if extendedSearch { regexButton.state = .off }; findPanel?.syncOptions(); scheduleSearch(); refreshMainMenu() }
    @objc func toggleSelectionSearch() {
        selectionOnly.toggle()
        if selectionOnly { searchScope = textView.selectedRange(); if !findVisible { showFind() } }
        findPanel?.syncOptions(); scheduleSearch(); refreshMainMenu()
    }
    @objc func findAllOpenDocuments() { if let options = searchOptions(folder: false) { startFileSearch(folder: nil, query: options.query, filters: options.filters, recursive: true) } }
    @objc func replaceInAllTabs() {
        guard let options = searchOptions(folder: false) else { return }
        let alert = NSAlert(); alert.messageText = tr("editor.rewrite_open_documents")
        alert.informativeText = tr("editor.editable_tabs_will_be_changed_and_can_be_undone_separately_save")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24)); field.placeholderString = tr("common.replace_with"); field.stringValue = replacementField.stringValue
        alert.accessoryView = field; alert.window.initialFirstResponder = field
        alert.addButton(withTitle: tr("common.replace_all")); alert.addButton(withTitle: tr("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        replacementField.stringValue = field.stringValue
        let replacement = extendedSearch && regexButton.state != .on ? TextTools.expandEscapes(field.stringValue) : field.stringValue
        let count = replaceAcrossTabs(query: options.query, replacement: replacement, filters: options.filters)
        if count >= 0 {
            let summary = NSAlert(); summary.messageText = tr("editor.replaced_matches", count)
            summary.addButton(withTitle: tr("common.ok")); summary.runModal()
        }
    }
    @discardableResult func replaceAcrossTabs(query: String, replacement: String, filters: String) -> Int {
        let patterns = filters.split(whereSeparator: { $0 == ";" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var plans: [(UUID, String)] = [], count = 0
        for document in documents where document.locked != true {
            if !patterns.isEmpty && !patterns.contains(where: { NSPredicate(format: "SELF LIKE[c] %@", $0).evaluate(with: document.title) }) { continue }
            let result = SearchResult.find(query, in: document.content, matchCase: caseButton.state == .on, regex: regexButton.state == .on, wholeWord: wholeWord)
            if result.invalid || result.limited {
                presentError(nil, operation: tr("editor.batch_replacement_could_not_complete"), detail: tr("editor.the_expression_is_invalid_timed_out_or_exceeded_the_match_limit")); return -1
            }
            guard !result.matches.isEmpty, let expression = result.expression else { continue }
            let template = regexButton.state == .on ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
            let text = NSMutableString(string: document.content)
            for match in result.matches.reversed() { text.replaceCharacters(in: match.range, with: expression.replacementString(for: match, in: document.content, offset: 0, template: template)) }
            plans.append((document.id, text as String)); count += result.matches.count
        }
        let original = activeID
        for (id, text) in plans { activateDocument(id); applyChange(TextChange(range: NSRange(location: 0, length: (textView.string as NSString).length), text: text), name: tr("editor.replace_in_tabs")) }
        activateDocument(original)
        return count
    }
    @objc func findInFolder() {
        let panel = NSOpenPanel(); panel.title = tr("editor.choose_search_folder"); panel.prompt = tr("editor.choose"); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.directoryURL = folderURL
        guard panel.runModal() == .OK, let folder = panel.url, let options = searchOptions(folder: true) else { return }
        startFileSearch(folder: folder, query: options.query, filters: options.filters, recursive: options.recursive)
    }
    func searchOptions(folder: Bool) -> (query: String, filters: String, recursive: Bool)? {
        let alert = NSAlert(); alert.messageText = folder ? tr("editor.search_a_directory") : tr("editor.search_open_documents")
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: folder ? 143 : 116))
        let query = NSTextField(frame: NSRect(x: 0, y: folder ? 113 : 86, width: 340, height: 24)); query.placeholderString = tr("common.find"); query.stringValue = findField.stringValue
        let filters = NSTextField(frame: NSRect(x: 0, y: folder ? 67 : 40, width: 340, height: 24)); filters.placeholderString = "*.swift;*.json"; filters.stringValue = UserDefaults.standard.string(forKey: "searchFilters") ?? "*"
        let hint = NSTextField(labelWithString: tr("editor.filename_filters_separated_by_semicolons")); hint.frame = NSRect(x: 0, y: folder ? 94 : 67, width: 340, height: 17); hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        let options = NSTextField(labelWithString: [caseButton.state == .on ? tr("common.match_case") : tr("editor.ignore_case"), regexButton.state == .on ? tr("editor.regex") : extendedSearch ? tr("editor.escapes") : tr("editor.text"), wholeWord ? tr("common.whole_words") : ""].filter { !$0.isEmpty }.joined(separator: " · ")); options.frame = NSRect(x: 0, y: 9, width: 340, height: 17); options.font = .systemFont(ofSize: 11); options.textColor = .secondaryLabelColor
        let recursive = NSButton(checkboxWithTitle: tr("editor.include_subfolders"), target: nil, action: nil); recursive.frame = NSRect(x: 0, y: 36, width: 340, height: 20); recursive.state = .on
        for field in [query, filters, hint, options] { view.addSubview(field) }
        if folder { view.addSubview(recursive) }
        alert.accessoryView = view; alert.addButton(withTitle: tr("common.find")); alert.addButton(withTitle: tr("common.cancel")); alert.window.initialFirstResponder = query
        guard alert.runModal() == .alertFirstButtonReturn, !query.stringValue.isEmpty else { return nil }
        findField.stringValue = query.stringValue
        let text = extendedSearch && regexButton.state != .on ? TextTools.expandEscapes(query.stringValue) : query.stringValue
        guard !SearchResult.find(text, in: "", matchCase: true, regex: regexButton.state == .on).invalid else { presentError(nil, operation: tr("editor.invalid_regular_expression")); return nil }
        UserDefaults.standard.set(filters.stringValue, forKey: "searchFilters")
        return (text, filters.stringValue, recursive.state == .on)
    }
    func startFileSearch(folder: URL?, query: String, filters: String, recursive: Bool) {
        fileSearchCancellation?.cancel(); fileSearchVersion += 1
        let version = fileSearchVersion, cancellation = SearchCancellation()
        fileSearchCancellation = cancellation; fileSearchReport = nil; fileSearchQuery = query
        results.hits = []; resultsVisible = true; resizeWorkspace(); results.cancelButton.isHidden = false
        results.title.stringValue = tr("common.searching")
        let documents = self.documents, matchCase = caseButton.state == .on, regex = regexButton.state == .on, word = wholeWord
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let report = FileSearch.scan(folder: folder, documents: documents, query: query, matchCase: matchCase, regex: regex, wholeWord: word, filters: filters, recursive: recursive, cancellation: cancellation)
            DispatchQueue.main.async {
                guard let self = self, self.fileSearchVersion == version else { return }
                self.fileSearchReport = report; self.results.hits = report.hits; self.results.cancelButton.isHidden = true; self.refreshSearchSummary()
            }
        }
    }
    func refreshSearchSummary() {
        guard let report = fileSearchReport else { if resultsVisible { results.title.stringValue = tr("common.searching") }; return }
        let suffix = report.cancelled ? tr("editor.stopped") : report.limited ? tr("editor.search_limit_reached") : ""
        results.title.stringValue = tr("editor.matches_files", report.hits.count, report.scanned) + (report.skipped > 0 ? tr("editor.skipped", report.skipped) : "") + suffix
    }
    func openSearchHit(_ hit: FileSearchHit) {
        if let id = hit.documentID, documents.contains(where: { $0.id == id }) { activateDocument(id) }
        else if let url = hit.url { openURLs([url]); guard activeDocument.url == url.standardizedFileURL else { return } }
        else { return }
        let source = textView.string as NSString
        var range = hit.range
        if NSMaxRange(range) > source.length || source.substring(with: range) != hit.matched {
            let result = SearchResult.find(fileSearchQuery, in: textView.string, matchCase: caseButton.state == .on, regex: regexButton.state == .on, wholeWord: wholeWord)
            let index = TextIndex(textView.string)
            guard let closest = result.matches.min(by: { abs(index.line(at: $0.range.location) + 1 - hit.line) < abs(index.line(at: $1.range.location) + 1 - hit.line) }) else { results.title.stringValue = tr("editor.content_changed_search_again"); return }
            range = closest.range
        }
        window?.makeFirstResponder(textView); textView.setSelectedRange(range); textView.scrollRangeToVisible(range)
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard activeDocument.locked != true else { return false }
        if let replacement = replacementString { pendingEdit = (activeID, affectedCharRange, replacement) }
        if macroRecording, !macroReplaying, let replacement = replacementString {
            macroBytes += replacement.utf8.count
            if recordedMacro.count >= 2000 || macroBytes > 5 * 1024 * 1024 { stopMacro() }
            else { recordedMacro.append(MacroEdit(offset: affectedCharRange.location - macroCursor, length: affectedCharRange.length, text: replacement)); macroCursor = affectedCharRange.location + (replacement as NSString).length }
        }
        return true
    }
    @objc func toggleMacro() {
        if macroRecording { stopMacro(); return }
        recordedMacro = []; macroBytes = 0; macroCursor = textView.selectedRange().location; macroRecording = true
        refreshStatus(); refreshMainMenu()
    }
    func stopMacro() {
        macroRecording = false
        if let data = try? JSONEncoder().encode(recordedMacro) { UserDefaults.standard.set(data, forKey: "lastMacro") }
        refreshStatus(); refreshMainMenu()
    }
    @objc func playMacro() { replayMacro(count: 1) }
    @objc func repeatMacro() {
        let alert = NSAlert(); alert.messageText = tr("editor.repeat_edit_steps"); alert.informativeText = tr("editor.repetitions_1_1000")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24)); input.stringValue = "10"; alert.accessoryView = input
        alert.addButton(withTitle: tr("editor.run")); alert.addButton(withTitle: tr("common.cancel")); alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn, let count = Int(input.stringValue), (1...1000).contains(count) else { return }
        replayMacro(count: count)
    }
    @discardableResult func replayMacro(count: Int) -> Bool {
        guard !macroRecording, !recordedMacro.isEmpty, activeDocument.locked != true, (1...1000).contains(count) else { return false }
        guard recordedMacro.count * count <= 20000, recordedMacro.reduce(0, { $0 + $1.text.utf8.count }) * count <= 16 * 1024 * 1024 else {
            presentError(nil, operation: tr("editor.too_many_edit_steps"), detail: tr("editor.reduce_the_number_of_repetitions")); return false
        }
        let result = NSMutableString(string: textView.string)
        var cursor = textView.selectedRange().location
        for _ in 0..<count {
            for edit in recordedMacro {
                let location = cursor + edit.offset
                guard location >= 0, edit.length >= 0, location <= result.length, edit.length <= result.length - location, result.length + (edit.text as NSString).length <= 32 * 1024 * 1024 else {
                    presentError(nil, operation: tr("common.edit_steps_cannot_run_here"), detail: tr("editor.an_edit_is_outside_the_document_the_document_was_not_changed")); return false
                }
                for boundary in [location, location + edit.length] where boundary > 0 && boundary < result.length {
                    let unit = result.character(at: boundary)
                    if (0xDC00...0xDFFF).contains(unit) {
                        presentError(nil, operation: tr("common.edit_steps_cannot_run_here"), detail: tr("editor.an_edit_would_split_a_character_the_document_was_not_changed")); return false
                    }
                }
                result.replaceCharacters(in: NSRange(location: location, length: edit.length), with: edit.text)
                cursor = location + (edit.text as NSString).length
            }
        }
        macroReplaying = true
        let changed = applyChange(TextChange(range: NSRange(location: 0, length: (textView.string as NSString).length), text: result as String), name: tr("editor.replay_edit_steps"))
        textView.setSelectedRange(NSRange(location: min(cursor, (textView.string as NSString).length), length: 0))
        macroReplaying = false
        return changed
    }
}
