// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import AppKit

extension EditorController {
    func extendFileMenu(_ menu: NSMenu) {
        let openIndex = menu.items.firstIndex { $0.action == #selector(openDocuments) || $0.action == #selector(WorkspaceManager.openDocuments(_:)) } ?? 1
        menu.insertItem(item(tr("menu.browse_folder"), #selector(openFolder), key: "o", modifiers: [.command, .shift]), at: openIndex + 1)
        menu.addItem(item(tr("menu.leave_current_folder"), #selector(closeFolder)))
        let recent = NSMenu(title: tr("menu.open_recent"))
        for path in UserDefaults.standard.stringArray(forKey: "recentFiles") ?? [] {
            let entry = item((path as NSString).lastPathComponent, #selector(openRecent(_:)))
            entry.representedObject = path; entry.toolTip = path; recent.addItem(entry)
        }
        if !recent.items.isEmpty { recent.addItem(.separator()) }
        recent.addItem(item(tr("menu.clear_menu"), #selector(clearRecent)))
        let entry = item(recent.title, nil); entry.submenu = recent; menu.insertItem(entry, at: (menu.items.firstIndex { $0.action == #selector(openFolder) } ?? 2) + 1)
        let saveIndex = menu.items.firstIndex { $0.action == #selector(saveAs) } ?? 0
        menu.insertItem(item(tr("common.save_all"), #selector(saveAll), key: "s", modifiers: [.command, .option]), at: saveIndex + 1)
        let tabs = NSMenu(title: tr("menu.arrange_tabs"))
        tabs.addItem(item(tr("common.keep_current_and_pinned_documents"), #selector(closeOtherTabs)))
        tabs.addItem(item(tr("common.close_all_unpinned_tabs"), #selector(closeAllTabs)))
        extendTabMenu(tabs)
        tabs.addItem(.separator())
        tabs.addItem(item(tr("menu.reopen_closed_tab"), #selector(reopenClosedTab), key: "t", modifiers: [.command, .shift]))
        let tabEntry = item(tabs.title, nil); tabEntry.submenu = tabs; menu.addItem(tabEntry)
        menu.addItem(.separator())
        menu.addItem(item(tr("menu.reload_from_disk"), #selector(reloadFromDisk)))
        menu.addItem(item(tr("common.copy_file_path"), #selector(copyFilePath)))
        menu.addItem(item(tr("common.reveal_in_finder"), #selector(revealInFinder)))
        menu.addItem(item(tr("menu.document_details"), #selector(showDocumentInfo)))
        menu.addItem(.separator())
        menu.addItem(item(tr("menu.import_session"), #selector(showImportSession)))
        menu.addItem(item(tr("menu.export_session"), #selector(showExportSession)))
        menu.addItem(.separator())
        let storage = encodingMenu()
        let storageItem = item(tr("menu.text_storage"), nil); storageItem.submenu = storage; menu.addItem(storageItem)
        if activeDocument.syntax == .plist { let entry = item(tr("common.plist_save_format"), nil); entry.submenu = plistStorageMenu(); menu.addItem(entry) }
        menu.addItem(.separator())
        menu.addItem(item(tr("menu.print"), #selector(printDocument), key: "p"))
    }
    func extendEditMenu(_ menu: NSMenu) {
        menu.addItem(.separator())
        menu.addItem(item(tr("common.format_document"), #selector(formatDocument), key: "i", modifiers: [.command, .shift]))
        menu.addItem(item(tr("menu.validate_document"), #selector(validateDocument)))
        let markdown = NSMenu(title: "Markdown")
        for tool in MarkdownEdit.allCases { markdown.addItem(item(tool.title, #selector(markdownEdit(_:)), tag: tool.rawValue)) }
        let writing = item("Markdown", nil); writing.submenu = markdown; menu.addItem(writing)
        let groups: [(String, [TextTool])] = [
            (tr("menu.arrange_lines"), [.duplicate, .deleteLine, .moveUp, .moveDown, .sortAscending, .sortDescending, .uniqueLines, .removeEmpty, .joinLines, .reverseLines]),
            (tr("menu.arrange_spacing"), [.indent, .outdent, .trimTrailing, .tabsToSpaces, .spacesToTabs]),
            (tr("menu.characters_and_structure"), [.uppercase, .lowercase, .formatJSON, .compactJSON]),
            (tr("menu.text_conversions"), [.encodeBase64, .decodeBase64, .encodeURL, .decodeURL, .quoteJSON, .unquoteJSON])
        ]
        for (title, tools) in groups {
            let sub = NSMenu(title: title)
            for tool in tools {
                let entry = item(tool.title, #selector(textTool(_:)), tag: tool.rawValue)
                if tool == .duplicate { entry.keyEquivalent = "d" }
                if tool == .deleteLine { entry.keyEquivalent = "k"; entry.keyEquivalentModifierMask = [.command, .shift] }
                if tool == .moveUp { entry.keyEquivalent = String(UnicodeScalar(NSUpArrowFunctionKey)!); entry.keyEquivalentModifierMask = [.option, .command] }
                if tool == .moveDown { entry.keyEquivalent = String(UnicodeScalar(NSDownArrowFunctionKey)!); entry.keyEquivalentModifierMask = [.option, .command] }
                sub.addItem(entry)
            }
            let entry = item(title, nil); entry.submenu = sub; menu.addItem(entry)
        }
        let insertion = NSMenu(title: tr("menu.insert_content"))
        for content in TextInsertion.allCases { insertion.addItem(item(content.title, #selector(insertContent(_:)), tag: content.rawValue)) }
        let insertionItem = item(insertion.title, nil); insertionItem.submenu = insertion; menu.addItem(insertionItem)
        menu.addItem(item(TextTool.comment.title, #selector(textTool(_:)), key: "/", tag: TextTool.comment.rawValue))
        menu.addItem(item(tr("menu.fill_by_column"), #selector(columnEditor), key: "c", modifiers: [.command, .option]))
        menu.addItem(item(tr("menu.complete_word"), #selector(completeWord), key: "j"))
        menu.addItem(.separator())
        let lock = item(tr("menu.read_only"), #selector(toggleReadOnly)); lock.state = activeDocument.locked == true ? .on : .off; menu.addItem(lock)
    }
    func searchMenu() -> NSMenu {
        let menu = NSMenu(title: tr("menu.navigate"))
        menu.addItem(item(tr("menu.find_and_replace"), #selector(showFind), key: "f"))
        menu.addItem(item(tr("menu.replace_text"), #selector(showReplace), key: "f", modifiers: [.command, .option]))
        menu.addItem(item(tr("common.list_document_matches"), #selector(listDocumentMatches)))
        menu.addItem(item(tr("menu.find_next"), #selector(findNext), key: "g"))
        menu.addItem(item(tr("menu.find_previous"), #selector(findPrevious), key: "g", modifiers: [.command, .shift]))
        menu.addItem(item(tr("menu.search_open_documents"), #selector(findAllOpenDocuments), key: "f", modifiers: [.command, .option, .shift]))
        menu.addItem(item(tr("menu.rewrite_open_documents"), #selector(replaceInAllTabs)))
        menu.addItem(item(tr("menu.search_a_directory"), #selector(findInFolder), key: "f", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        for (title, selector, checked) in [
            (tr("menu.whole_words"), #selector(toggleWholeWord), wholeWord),
            (tr("menu.extended_escapes_n_r_t"), #selector(toggleExtendedSearch), extendedSearch),
            (tr("menu.in_selection_only"), #selector(toggleSelectionSearch), selectionOnly)
        ] { let entry = item(title, selector); entry.state = checked ? .on : .off; menu.addItem(entry) }
        menu.addItem(.separator())
        menu.addItem(item(tr("menu.go_to_line"), #selector(goToLine), key: "l"))
        menu.addItem(item(tr("menu.switch_document"), #selector(showDocumentPicker), key: "k"))
        menu.addItem(item(tr("menu.document_outline"), #selector(showDocumentOutline), key: "l", modifiers: [.command, .shift]))
        menu.addItem(item(tr("menu.go_to_matching_bracket"), #selector(jumpToBracket), key: "b", modifiers: [.command, .shift]))
        let bookmarks = NSMenu(title: tr("menu.line_marks"))
        bookmarks.addItem(item(tr("menu.mark_this_line"), #selector(toggleCurrentBookmark), key: "b", modifiers: [.command, .option]))
        bookmarks.addItem(item(tr("menu.following_mark"), #selector(nextBookmark), key: String(UnicodeScalar(NSF2FunctionKey)!), modifiers: []))
        bookmarks.addItem(item(tr("menu.preceding_mark"), #selector(previousBookmark), key: String(UnicodeScalar(NSF2FunctionKey)!), modifiers: [.shift]))
        bookmarks.addItem(item(tr("menu.mark_result_lines"), #selector(markMatches)))
        bookmarks.addItem(.separator())
        bookmarks.addItem(item(tr("menu.extract_marked_lines"), #selector(copyBookmarkedLines)))
        bookmarks.addItem(item(tr("common.remove_marked_lines"), #selector(removeBookmarkedLines)))
        bookmarks.addItem(item(tr("menu.clear_line_marks"), #selector(clearBookmarks)))
        let entry = item(bookmarks.title, nil); entry.submenu = bookmarks; menu.addItem(entry)
        return menu
    }
    func encodingMenu() -> NSMenu {
        let menu = NSMenu(title: tr("menu.encoding"))
        let conversion = NSMenu(title: tr("common.write_encoding"))
        let reload = NSMenu(title: tr("menu.reopen_as_encoding"))
        for (index, encoding) in TextEncoding.allCases.enumerated() {
            let entry = item(encoding.title, #selector(selectEncoding(_:)), tag: index); entry.state = activeDocument.encoding == encoding ? .on : .off; conversion.addItem(entry)
            reload.addItem(item(encoding.title, #selector(reloadWithEncoding(_:)), tag: index))
        }
        let convert = item(conversion.title, nil); convert.submenu = conversion; menu.addItem(convert)
        let reopen = item(reload.title, nil); reopen.submenu = reload; menu.addItem(reopen)
        let endings = NSMenu(title: tr("menu.line_endings"))
        for (index, ending) in [LineEnding.lf, .crlf, .cr].enumerated() {
            let entry = item(ending.title, #selector(selectEnding(_:)), tag: index); entry.state = (activeDocument.preferredEnding ?? currentIndex.ending) == ending ? .on : .off; endings.addItem(entry)
        }
        menu.addItem(.separator())
        let ending = item(endings.title, nil); ending.submenu = endings; menu.addItem(ending)
        return menu
    }
    func syntaxMenu() -> NSMenu {
        let menu = NSMenu(title: tr("menu.syntax"))
        for (index, syntax) in Syntax.allCases.enumerated() {
            let entry = item(syntax.title, #selector(selectSyntax(_:)), tag: index); entry.state = activeDocument.syntax == syntax ? .on : .off; menu.addItem(entry)
        }
        return menu
    }
    func macroMenu() -> NSMenu {
        let menu = NSMenu(title: tr("menu.actions"))
        menu.addItem(item(macroRecording ? tr("common.end_capture") : tr("common.capture_edits"), #selector(toggleMacro), key: "r", modifiers: [.command, .option]))
        menu.addItem(item(tr("menu.replay_current_steps"), #selector(playMacro), key: "p", modifiers: [.command, .option]))
        menu.addItem(item(tr("menu.run_multiple_times"), #selector(repeatMacro)))
        return menu
    }
    func extendViewMenu(_ menu: NSMenu) {
        let markdown = NSMenu(title: tr("common.markdown_view"))
        for mode in MarkdownViewMode.allCases {
            let entry = item(mode.title, #selector(selectMarkdownView(_:)), tag: mode.rawValue); entry.state = markdownMode == mode ? .on : .off; markdown.addItem(entry)
        }
        let preview = item(markdown.title, nil); preview.submenu = markdown; menu.addItem(preview)
        menu.addItem(item(tr("menu.toggle_markdown_preview"), #selector(cycleMarkdownPreview), key: "m", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        let split = item(tr("common.twin_editing"), #selector(toggleSplitEditor), key: "\\", modifiers: [.command, .option])
        split.state = splitEnabled ? .on : .off; menu.addItem(split)
        menu.addItem(item(tr("menu.switch_editing_pane"), #selector(switchEditingPane), key: "`", modifiers: [.command, .option]))
        menu.addItem(.separator())
        for (title, selector, checked) in [
            (tr("menu.folder_tree"), #selector(toggleFolder), folderVisible),
            (tr("menu.result_panel"), #selector(toggleResults), resultsVisible)
        ] { let entry = item(title, selector); entry.state = checked ? .on : .off; menu.addItem(entry) }
        menu.addItem(item(tr("menu.refresh_folder_tree"), #selector(refreshFolder)))
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return true }
        if action == #selector(formatDocument) { return [.plist, .xml, .json].contains(activeDocument.syntax) && activeDocument.locked != true && formattingDocument != activeID }
        if action == #selector(validateDocument) { return [.plist, .xml, .json].contains(activeDocument.syntax) && formattingDocument != activeID }
        if action == #selector(markdownEdit(_:)) { return activeDocument.syntax == .markdown && activeDocument.locked != true }
        if [#selector(selectMarkdownView(_:)), #selector(cycleMarkdownPreview)].contains(action) { return activeDocument.syntax == .markdown }
        if action == #selector(selectPlistStorage(_:)) { return activeDocument.syntax == .plist && activeDocument.locked != true }
        if action == #selector(selectEncoding(_:)), activeDocument.plistFormat == .binary { return false }
        if action == #selector(undoFromToolbar) { return toolbarEnabled("undo") }
        if action == #selector(redoFromToolbar) { return toolbarEnabled("redo") }
        if action == #selector(saveAll) { return toolbarEnabled("saveAll") }
        if action == #selector(toggleReadOnly) { menuItem.state = activeDocument.locked == true ? .on : .off }
        if action == #selector(toggleMacro) { menuItem.title = macroRecording ? tr("common.end_capture") : tr("common.capture_edits") }
        if action == #selector(selectDocument(_:)) { menuItem.state = (menuItem.representedObject as? String) == activeID.uuidString ? .on : .off }
        if action == #selector(selectEncoding(_:)) { menuItem.state = activeDocument.encoding == TextEncoding.allCases[menuItem.tag] ? .on : .off }
        if action == #selector(selectSyntax(_:)) { menuItem.state = activeDocument.syntax == Syntax.allCases[menuItem.tag] ? .on : .off }
        if action == #selector(selectEnding(_:)) { menuItem.state = (activeDocument.preferredEnding ?? currentIndex.ending) == [LineEnding.lf, .crlf, .cr][menuItem.tag] ? .on : .off }
        if [#selector(textTool(_:)), #selector(insertContent(_:)), #selector(columnEditor), #selector(completeWord), #selector(selectEncoding(_:)), #selector(selectEnding(_:)), #selector(replaceOne), #selector(replaceAll)].contains(action) { return activeDocument.locked != true }
        if [#selector(revealInFinder), #selector(copyFilePath), #selector(reloadFromDisk), #selector(reloadWithEncoding(_:))].contains(action) { return activeDocument.url != nil }
        if action == #selector(closeFolder) { return folderURL != nil }
        if action == #selector(switchEditingPane) { return secondaryVisible }
        if action == #selector(reopenClosedTab) { return !closedDocuments.isEmpty }
        if action == #selector(closeOtherTabs) { return documents.contains { $0.id != activeID && $0.pinned != true } }
        if action == #selector(closeAllTabs) { return documents.contains { $0.pinned != true } }
        if action == #selector(moveTabEarlier) { return adjacentTab(-1) != nil }
        if action == #selector(moveTabLater) { return adjacentTab(1) != nil }
        if action == #selector(closeEarlierTabs) { return !sideTabIDs(after: false).isEmpty }
        if action == #selector(closeLaterTabs) { return !sideTabIDs(after: true).isEmpty }
        if action == #selector(toggleActivePin) {
            menuItem.title = activeDocument.pinned == true ? tr("common.unpin_document") : tr("common.pin_document")
            menuItem.state = activeDocument.pinned == true ? .on : .off
        }
        if [#selector(playMacro), #selector(repeatMacro)].contains(action) { return !macroRecording && !recordedMacro.isEmpty && activeDocument.locked != true }
        if [#selector(nextBookmark), #selector(previousBookmark), #selector(copyBookmarkedLines), #selector(clearBookmarks), #selector(removeBookmarkedLines)].contains(action) { return !(activeDocument.bookmarks ?? []).isEmpty && (action != #selector(removeBookmarkedLines) || activeDocument.locked != true) }
        if action == #selector(listDocumentMatches) { return !effectiveQuery.isEmpty }
        if action == #selector(markMatches) { return !findField.stringValue.isEmpty }
        if action == #selector(splitDocument(_:)), let zone = EditorDropZone(rawValue: menuItem.tag) { return workspaceHost?.canSplit(self, zone: zone) == true }
        if [#selector(mergeEditorGroups), #selector(focusNextGroup), #selector(focusPreviousGroup)].contains(action) { return (workspaceHost?.groups.count ?? 0) > 1 }
        if [#selector(detachActiveDocument), #selector(closeEditorGroup)].contains(action) { return workspaceHost != nil }
        return true
    }
    @objc func printDocument() {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit; info.verticalPagination = .automatic
        let operation = NSPrintOperation(view: textView, printInfo: info)
        operation.jobTitle = activeDocument.title
        operation.run()
    }
}
