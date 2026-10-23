// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import AppKit

final class EditorController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSSearchFieldDelegate, NSToolbarDelegate, NSMenuItemValidation {
    var documents: [EditorDocument]
    var activeID: UUID
    let sessionStore: SessionStore
    let groupID: UUID
    weak var workspaceHost: EditorWorkspaceWindow?
    var groupWidth: CGFloat { workspaceHost == nil ? window?.frame.width ?? 1040 : root.bounds.width }
    var buffers: [UUID: EditorTextView] = [:]
    var panePositions: [UUID: (primary: NSPoint, secondary: NSPoint)] = [:]
    lazy var primaryEditor = EditorTextView(frame: .zero)
    var textView: EditorTextView {
        get { !isLoading && secondaryFocused && secondaryVisible ? secondaryEditor ?? primaryEditor : primaryEditor }
        set { primaryEditor = newValue }
    }
    let editorScroll = NSScrollView()
    let editingSplit = NSSplitView()
    let secondaryScroll = NSScrollView()
    var secondaryRuler: LineNumberView?
    var splitBuffers: [UUID: EditorTextView] = [:]
    var secondaryFocused = false
    var twinEnabledOverride: Bool?
    var workspacePlaceholder = false
    var splitScrollObserver: NSObjectProtocol?
    var ruler: LineNumberView?
    let tabScroll = NSScrollView()
    let tabStack = NSStackView()
    let root = AppearanceView()
    let tabsBar = TabBarDropView()
    let footer = ChromeView()
    let workspace = NSView()
    let documentHost = NSView()
    let documentBar = ChromeView()
    let documentContent = NSSplitView()
    let documentKind = label("", size: 11)
    let documentModes = NSSegmentedControl()
    let plistStorage = NSPopUpButton()
    let formatButton = NSButton()
    let validateButton = NSButton()
    let formatStatus = label("", size: 11)
    var documentBarHeight: NSLayoutConstraint!
    var markdownPreview: MarkdownPreviewView?
    var previewJob: DispatchWorkItem?
    var formattingDocument: UUID?
    var formatOperation: UUID?
    var formatFeedback: (UUID, DocumentFeedback)?
    let browserHost = NSView()
    let resultsHost = NSView()
    var browserLoaded = false
    var resultsLoaded = false
    lazy var browser: FileBrowserView = {
        let view = FileBrowserView()
        view.isHidden = browserHost.isHidden
        installPanel(view, in: browserHost)
        view.onOpen = { [weak self] in self?.openURLs([$0]) }
        view.onClose = { [weak self] in self?.closeFolder() }
        browserLoaded = true
        return view
    }()
    lazy var results: SearchResultsView = {
        let view = SearchResultsView()
        view.isHidden = resultsHost.isHidden
        installPanel(view, in: resultsHost)
        view.onOpen = { [weak self] in self?.openSearchHit($0) }
        view.onClose = { [weak self] in self?.hideResults() }
        view.onCancel = { [weak self] in self?.fileSearchCancellation?.cancel() }
        resultsLoaded = true
        return view
    }()
    var browserWidth: NSLayoutConstraint!
    var resultsHeight: NSLayoutConstraint!
    var folderURL: URL?
    var folderVisible = false
    var resultsVisible = false
    var fileSearchCancellation: SearchCancellation?
    var fileSearchVersion = 0
    var fileSearchReport: FileSearchReport?
    var fileSearchQuery = ""
    var wholeWord = false
    var extendedSearch = false
    var selectionOnly = false
    var searchScope: NSRange?
    var closedDocuments: [EditorDocument] = []
    var macroRecording = false
    var macroReplaying = false
    var macroCursor = 0
    var recordedMacro: [MacroEdit] = []
    var macroBytes = 0
    var dropObserver: NSObjectProtocol?
    var pendingEdit: (id: UUID, range: NSRange, replacement: String)?
    var selectionJob: DispatchWorkItem?
    var toolbarObservers: [NSObjectProtocol] = []
    var cachedToolbarCommands: [String: ToolbarCommand] = [:]
    var cachedToolbarLanguage: Language?
    let findField = NSSearchField()
    let replacementField = NSTextField()
    let matchLabel = label("")
    let positionLabel = label("")
    let countLabel = label("")
    let recoveryLabel = label("")
    let encodingButton = NSButton()
    let endingButton = NSButton()
    let syntaxButton = NSButton()
    let caseButton = NSButton()
    let regexButton = NSButton()
    let replaceOneButton = NSButton()
    let replaceAllButton = NSButton()
    var about: AboutController?
    var preferences: PreferencesController?
    weak var installedMainMenu: NSMenu?
    var quickPicker: QuickPicker?
    var documentInfo: DocumentInfoController?
    var findPanel: FindPanelController?
    var searchWraps = true
    var findVisible = false
    var currentIndex = TextIndex("")
    var searchResult = SearchResult()
    var analysisJob: DispatchWorkItem?
    var recoveryJob: DispatchWorkItem?
    var searchJob: DispatchWorkItem?
    var analysisVersion = 0
    var searchVersion = 0
    var scrollObserver: NSObjectProtocol?
    var recoveryFailed = false
    var isLoading = false
    var compactSyntaxWidth: NSLayoutConstraint?
    var compactEncodingWidth: NSLayoutConstraint?
    var wraps: Bool { UserDefaults.standard.object(forKey: "wrap") as? Bool ?? true }
    var showsLines: Bool { UserDefaults.standard.object(forKey: "lineNumbers") as? Bool ?? true }
    var fontSize: CGFloat { CGFloat(UserDefaults.standard.object(forKey: "fontSize") as? Double ?? 14) }
    var activeIndex: Int { documents.firstIndex(where: { $0.id == activeID }) ?? 0 }
    var activeDocument: EditorDocument { documents[activeIndex] }

    init(store: SessionStore = SessionStore(), restore: Bool = true, initialSession: EditorSession? = nil, groupID: UUID = UUID(), host: EditorWorkspaceWindow? = nil) {
        self.groupID = groupID
        sessionStore = store
        if let session = initialSession ?? (restore ? store.load() : nil), !session.documents.isEmpty {
            documents = session.documents.map { saved in
                var document = saved
                if !saved.isDirty, let url = saved.url {
                    if var current = try? EditorDocument.open(url, encoding: saved.encoding) {
                        current.id = saved.id
                        current.selectionLocation = saved.selectionLocation
                        current.selectionLength = saved.selectionLength
                        current.scrollY = saved.scrollY
                        current.syntax = saved.syntax
                        current.bookmarks = saved.bookmarks
                        current.locked = saved.locked
                        current.pinned = saved.pinned
                        current.preferredEnding = saved.preferredEnding
                        current.markdownView = saved.markdownView
                        document = current
                    } else { document.requiresSave = true }
                }
                document.normalizeBookmarks()
                return document
            }
            activeID = session.documents.first(where: { $0.id == session.activeID })?.id ?? session.documents[0].id
            folderURL = session.folderURL
            folderVisible = session.folderURL != nil
        } else {
            let document = EditorDocument()
            documents = [document]; activeID = document.id
        }
        let window = host?.window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        workspaceHost = host
        if let host = host { root.frame = host.canvas.bounds }
        else {
            window.delegate = self
            window.minSize = NSSize(width: 520, height: 360)
            window.title = "EditDot"
            window.titleVisibility = .hidden
            window.backgroundColor = Palette.canvas
            window.tabbingMode = .disallowed
            window.toolbarStyle = .unified
            window.setFrameAutosaveName("EditDotMainWindow")
            window.center()
        }
        setupLayout()
        setupWorkspace()
        if host != nil { root.layoutSubtreeIfNeeded() }
        if host == nil { setupToolbar() }
        observeToolbarHistory()
        if host == nil { applyAppearance() }
        activateDocument(activeID)
        refreshLocalization(rebuildTabs: false)
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: editorScroll.contentView, queue: .main) { [weak self] _ in
            self?.ruler?.needsDisplay = true
            self?.highlightMatches()
        }
        editorScroll.contentView.postsBoundsChangedNotifications = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    deinit {
        if let observer = scrollObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = dropObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = splitScrollObserver { NotificationCenter.default.removeObserver(observer) }
        toolbarObservers.forEach { NotificationCenter.default.removeObserver($0) }
        fileSearchCancellation?.cancel()
    }

    private func setupLayout() {
        if workspaceHost == nil { window?.contentView = root }
        root.appearanceChanged = { [weak self] in
            self?.scheduleAnalysis(immediate: true)
            self?.scheduleMarkdownPreview(immediate: true)
            self?.ruler?.needsDisplay = true
        }
        for view in [tabsBar, workspace, footer] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        tabsBar.drawsBottomLine = true
        footer.drawsTopLine = true
        NSLayoutConstraint.activate([
            tabsBar.leadingAnchor.constraint(equalTo: root.leadingAnchor), tabsBar.trailingAnchor.constraint(equalTo: root.trailingAnchor), tabsBar.topAnchor.constraint(equalTo: root.topAnchor), tabsBar.heightAnchor.constraint(equalToConstant: 36),
            workspace.leadingAnchor.constraint(equalTo: root.leadingAnchor), workspace.trailingAnchor.constraint(equalTo: root.trailingAnchor), workspace.topAnchor.constraint(equalTo: tabsBar.bottomAnchor), workspace.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor), footer.trailingAnchor.constraint(equalTo: root.trailingAnchor), footer.bottomAnchor.constraint(equalTo: root.bottomAnchor), footer.heightAnchor.constraint(equalToConstant: 29)
        ])
        tabScroll.drawsBackground = false
        tabScroll.borderType = .noBorder
        tabScroll.hasHorizontalScroller = true
        tabScroll.hasVerticalScroller = false
        tabScroll.scrollerStyle = .overlay
        tabScroll.autohidesScrollers = true
        tabScroll.translatesAutoresizingMaskIntoConstraints = false
        tabStack.orientation = .horizontal; tabStack.spacing = 0
        tabStack.alignment = .centerY
        tabScroll.documentView = tabStack
        let newTab = symbolButton("plus", tooltip: tr("common.new_document_n"), target: self, action: #selector(newDocument))
        newTab.identifier = NSUserInterfaceItemIdentifier("newTab")
        tabsBar.addSubview(tabScroll); tabsBar.addSubview(newTab)
        NSLayoutConstraint.activate([
            tabScroll.leadingAnchor.constraint(equalTo: tabsBar.leadingAnchor), tabScroll.topAnchor.constraint(equalTo: tabsBar.topAnchor), tabScroll.bottomAnchor.constraint(equalTo: tabsBar.bottomAnchor), tabScroll.trailingAnchor.constraint(equalTo: newTab.leadingAnchor, constant: -4),
            newTab.trailingAnchor.constraint(equalTo: tabsBar.trailingAnchor, constant: -7), newTab.centerYAnchor.constraint(equalTo: tabsBar.centerYAnchor)
        ])
        editorScroll.borderType = .noBorder
        editorScroll.contentView = EditorClipView(frame: editorScroll.contentView.frame)
        editorScroll.drawsBackground = true
        editorScroll.backgroundColor = Palette.canvas
        editorScroll.hasVerticalScroller = true
        editorScroll.hasHorizontalScroller = true
        editorScroll.autohidesScrollers = true
        editorScroll.scrollerStyle = .overlay
        editorScroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        setupSearchControls()
        setupFooter()
        tabsBar.newDocument = { [weak self] in self?.newDocument() }
    }

    private func setupSearchControls() {
        for field in [findField, replacementField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.controlSize = .regular; field.font = .systemFont(ofSize: 12)
            field.delegate = self; field.target = self
        }
        findField.action = #selector(findNext)
        findField.sendsWholeSearchString = true
        findField.sendsSearchStringImmediately = false
        findField.maximumRecents = 20
        findField.recentsAutosaveName = NSSearchField.RecentsAutosaveName("EditDotFindHistory")
        replacementField.bezelStyle = .roundedBezel
        replacementField.action = #selector(replaceOne)
        for button in [caseButton, regexButton] {
            button.setButtonType(.switch); button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.target = self; button.action = #selector(searchOptionsChanged)
        }
        for button in [replaceOneButton, replaceAllButton] {
            button.bezelStyle = .rounded; button.controlSize = .small
            button.font = .systemFont(ofSize: 12); button.target = self
        }
        replaceOneButton.action = #selector(replaceOne); replaceAllButton.action = #selector(replaceAll)
    }

    private func setupFooter() {
        positionLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        countLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        for button in [encodingButton, endingButton, syntaxButton] {
            button.isBordered = false
            button.font = .systemFont(ofSize: 10.5)
            button.contentTintColor = .secondaryLabelColor
            button.target = self
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        encodingButton.action = #selector(showEncodingMenu)
        endingButton.action = #selector(showEndingMenu)
        syntaxButton.action = #selector(showSyntaxMenu)
        for view in [positionLabel, countLabel, recoveryLabel, encodingButton, endingButton, syntaxButton] { footer.addSubview(view) }
        NSLayoutConstraint.activate([
            positionLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 14), positionLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            countLabel.leadingAnchor.constraint(equalTo: positionLabel.trailingAnchor, constant: 20), countLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            syntaxButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -12), syntaxButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor), syntaxButton.widthAnchor.constraint(lessThanOrEqualToConstant: 100),
            endingButton.trailingAnchor.constraint(equalTo: syntaxButton.leadingAnchor, constant: -16), endingButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            encodingButton.trailingAnchor.constraint(equalTo: endingButton.leadingAnchor, constant: -16), encodingButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            recoveryLabel.trailingAnchor.constraint(equalTo: encodingButton.leadingAnchor, constant: -18), recoveryLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor), recoveryLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 180)
        ])
        recoveryLabel.textColor = .systemOrange
        compactSyntaxWidth = syntaxButton.widthAnchor.constraint(equalToConstant: 0)
        compactEncodingWidth = encodingButton.widthAnchor.constraint(equalToConstant: 0)
    }

    func setupToolbar() {
        let toolbar = NSToolbar(identifier: "EditDotToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false
        window?.toolbar = toolbar
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return ["brand", "new", "open", "save", "saveAll"].map { NSToolbarItem.Identifier($0) }
            + [.space] + ["undo", "redo"].map { NSToolbarItem.Identifier($0) }
            + [.flexibleSpace] + ["find", "split"].map { NSToolbarItem.Identifier($0) }
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier.rawValue {
        case "brand":
            let mark = EditorBrandMark()
            mark.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([mark.widthAnchor.constraint(equalToConstant: 17), mark.heightAnchor.constraint(equalToConstant: 17)])
            let name = label("EditDot", size: 13, color: .labelColor)
            name.font = .systemFont(ofSize: 13, weight: .semibold)
            let stack = NSStackView(views: [mark, name]); stack.spacing = 7
            item.view = stack
            item.autovalidates = false
            item.isEnabled = true
            stack.widthAnchor.constraint(equalToConstant: 90).isActive = true
            stack.heightAnchor.constraint(equalToConstant: 26).isActive = true
        default: return makeActionToolbarItem(identifier)
        }
        return item
    }

    func makeEditor(container: NSTextContainer? = nil) -> EditorTextView {
        let frame = NSRect(origin: .zero, size: editorScroll.contentView.bounds.size)
        let editor = container.map { EditorTextView(frame: frame, textContainer: $0) } ?? EditorTextView(frame: frame)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.usesFindPanel = false
        editor.usesFontPanel = false
        editor.layoutManager?.allowsNonContiguousLayout = true
        editor.registerForDraggedTypes([.fileURL])
        editor.textContainerInset = NSSize(width: 12, height: 16)
        editor.isVerticallyResizable = true
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.backgroundColor = Palette.canvas
        editor.textColor = .labelColor
        editor.insertionPointColor = Palette.accent
        editor.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor, .foregroundColor: NSColor.selectedTextColor]
        connectEditor(editor)
        return editor
    }
    func connectEditor(_ editor: EditorTextView) {
        editor.delegate = self
        editor.pressedEscape = { [weak self] in self?.hideFind() }
        editor.performTool = { [weak self] tool in self?.performTextTool(tool) }
        editor.receivedFocus = { [weak self, weak editor] in
            guard let self = self, let editor = editor, !self.isLoading, editor.textStorage === self.primaryEditor.textStorage else { return }
            self.secondaryFocused = editor !== self.primaryEditor
            self.workspaceHost?.focus(self)
            self.refreshStatus(); self.scheduleSelectionDecoration()
        }
    }

    func activateDocument(_ id: UUID) {
        guard documents.contains(where: { $0.id == id }) else { return }
        if id == activeID, buffers[id] === primaryEditor {
            window?.makeFirstResponder(textView)
            return
        }
        if id != activeID && macroRecording { stopMacro() }
        stashPosition()
        secondaryFocused = false
        analysisJob?.cancel(); searchJob?.cancel(); analysisVersion += 1; searchVersion += 1
        activeID = id
        pendingEdit = nil
        searchScope = nil
        isLoading = true
        if let buffer = buffers[id] { textView = buffer }
        else {
            textView = makeEditor()
            textView.string = activeDocument.content
            buffers[id] = textView
            panePositions.removeValue(forKey: id)
        }
        currentIndex = TextIndex(linesIn: primaryEditor.string)
        editorScroll.documentView = primaryEditor
        ruler = LineNumberView(editor: textView, scrollView: editorScroll)
        ruler?.index = currentIndex
        ruler?.bookmarks = activeDocument.bookmarks ?? []
        ruler?.toggleBookmark = { [weak self] location in self?.toggleBookmark(at: location) }
        editorScroll.verticalRulerView = ruler
        synchronizeSplit()
        applyEditorPreferences()
        let length = (textView.string as NSString).length
        let location = min(activeDocument.selectionLocation, length)
        textView.setSelectedRange(NSRange(location: location, length: min(activeDocument.selectionLength, length - location)))
        restoreScrollPosition(panePositions[id]?.primary ?? NSPoint(x: 0, y: max(0, activeDocument.scrollY)), in: editorScroll)
        if secondaryVisible { restoreScrollPosition(panePositions[id]?.secondary ?? .zero, in: secondaryScroll) }
        isLoading = false
        refreshDocumentArea()
        refreshGutters()
        for (editor, _, _) in editorPanes { editor.newline = (activeDocument.preferredEnding ?? currentIndex.ending).sequence }
        refreshTabs()
        refreshStatus()
        scheduleAnalysis(immediate: true)
        if findVisible { scheduleSearch() }
        else { window?.makeFirstResponder(textView) }
        refreshWindowMetadata()
        scheduleRecovery()
    }

    func stashPosition() {
        guard documents.contains(where: { $0.id == activeID }), buffers[activeID] != nil else { return }
        let selection = primaryEditor.selectedRange()
        documents[activeIndex].selectionLocation = selection.location
        documents[activeIndex].selectionLength = selection.length
        documents[activeIndex].scrollY = editorScroll.contentView.bounds.origin.y
        func position(_ scroll: NSScrollView) -> NSPoint {
            let clip = scroll.contentView
            return NSPoint(x: clip.bounds.minX + clip.contentInsets.left, y: clip.bounds.minY)
        }
        panePositions[activeID] = (position(editorScroll), secondaryVisible ? position(secondaryScroll) : panePositions[activeID]?.secondary ?? .zero)
    }
    func restoreScrollPosition(_ position: NSPoint, in scroll: NSScrollView) {
        let clip = scroll.contentView
        var bounds = clip.bounds
        bounds.origin = NSPoint(x: (wraps ? 0 : position.x) - clip.contentInsets.left, y: position.y)
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
    }
    func refreshTabs() {
        documents = documents.filter { $0.pinned == true } + documents.filter { $0.pinned != true }
        tabStack.arrangedSubviews.forEach { tabStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        tabStack.frame = NSRect(x: 0, y: 0, width: max(126, CGFloat(documents.count) * 160), height: 35)
        var activeTab: TabItemView?
        for document in documents {
            let tab = TabItemView(document: document, active: document.id == activeID)
            tab.onSelect = { [weak self] in self?.activateDocument($0) }
            tab.onClose = { [weak self] in self?.closeDocument($0) }
            tab.onPin = { [weak self] in self?.togglePin($0) }
            tab.canMove = { [weak self] source in
                guard let self = self else { return false }
                if let owner = self.workspaceHost?.manager?.owner(of: source), owner !== self { return true }
                return self.canMoveTab(source, to: document.id)
            }
            tab.onMove = { [weak self] source, after in
                guard let self = self else { return }
                if let manager = self.workspaceHost?.manager { _ = manager.transfer(source, to: self, beside: document.id, after: after) }
                else { self.moveTab(source, beside: document.id, after: after) }
            }
            tab.onDetach = { [weak self] id, point in _ = self?.workspaceHost?.manager?.detach(id, at: point, onlyOutside: true) }
            tab.contextMenu = { [weak self] in self?.tabMenu(document.id) ?? NSMenu() }
            tabStack.addArrangedSubview(tab)
            if document.id == activeID { activeTab = tab }
        }
        tabStack.frame = NSRect(origin: .zero, size: NSSize(width: max(1, tabStack.fittingSize.width), height: 35))
        tabStack.layoutSubtreeIfNeeded()
        if let tab = activeTab { tabStack.scrollToVisible(tab.frame) }
        if NSApp.mainMenu != nil { refreshMainMenu() }
    }

    func applyEditorPreferences() {
        for (editor, scroll, gutter) in editorPanes {
            (scroll.contentView as? EditorClipView)?.wraps = wraps
            if editor.frame.origin != .zero { editor.setFrameOrigin(.zero) }
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsetsZero
            scroll.hasHorizontalScroller = !wraps
            scroll.hasVerticalRuler = showsLines
            scroll.rulersVisible = showsLines
            scroll.tile()
            let insets = scroll.contentView.contentInsets
            let width = max(1, scroll.contentView.bounds.width - insets.left - insets.right)
            editor.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            editor.typingAttributes = [.font: editor.font!, .foregroundColor: NSColor.labelColor]
            editor.isHorizontallyResizable = !wraps
            editor.autoresizingMask = wraps ? [.width] : []
            editor.textContainer?.widthTracksTextView = wraps
            editor.textContainer?.containerSize = NSSize(width: wraps ? max(1, width - editor.textContainerInset.width * 2) : CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            if wraps {
                editor.setFrameSize(NSSize(width: width, height: max(editor.frame.height, scroll.contentSize.height)))
                restoreScrollPosition(NSPoint(x: 0, y: scroll.contentView.bounds.minY), in: scroll)
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            paragraph.defaultTabInterval = fontSize * 2.4
            paragraph.tabStops = []
            editor.defaultParagraphStyle = paragraph
            if let storage = editor.textStorage, storage.length > 0 {
                storage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: storage.length))
            }
            editor.typingAttributes[.paragraphStyle] = paragraph
            editor.isEditable = activeDocument.locked != true
            editor.indentWidth = indentWidth
            editor.usesTabs = usesTabs
            editor.closesBrackets = UserDefaults.standard.object(forKey: "closeBrackets") as? Bool ?? true
            editor.layoutManager?.showsInvisibleCharacters = UserDefaults.standard.bool(forKey: "whitespace")
            gutter?.needsDisplay = true
        }
    }

    func textDidChange(_ notification: Notification) {
        guard !isLoading, let changed = notification.object as? NSTextView, changed.textStorage === primaryEditor.textStorage,
              documents[activeIndex].content != primaryEditor.string else { return }
        let wasDirty = activeDocument.isDirty
        workspacePlaceholder = false
        let oldText = documents[activeIndex].content
        let actualEdit = pendingEdit.flatMap { $0.id == activeID ? TextChange(range: $0.range, text: $0.replacement) : nil }
        if let edit = pendingEdit, edit.id == activeID {
            currentIndex = currentIndex.replacing(in: oldText, with: textView.string, range: edit.range, replacement: edit.replacement)
        } else { currentIndex = TextIndex(linesIn: textView.string) }
        pendingEdit = nil
        ruler?.index = currentIndex
        ruler?.needsDisplay = true
        refreshStatus()
        if let anchors = activeDocument.bookmarks, !anchors.isEmpty {
            documents[activeIndex].bookmarks = TextTools.shiftedBookmarks(anchors, old: oldText, new: textView.string, edit: actualEdit)
            ruler?.bookmarks = activeDocument.bookmarks ?? []
        }
        documents[activeIndex].content = textView.string
        formatFeedback = nil
        formatStatus.stringValue = ""
        scheduleMarkdownPreview()
        refreshGutters()
        searchScope = nil
        refreshWindowMetadata()
        if wasDirty != activeDocument.isDirty { refreshTabs() }
        scheduleAnalysis()
        scheduleRecovery()
        if findVisible { scheduleSearch() }
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isLoading else { return }
        textView.needsDisplay = true
        refreshStatus()
        scheduleSelectionDecoration()
        if findVisible { refreshFindStatus() }
    }
    func controlTextDidBeginEditing(_ obj: Notification) { workspaceHost?.focus(self) }
    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSTextField, field === findField { scheduleSearch() }
    }
    func scheduleSelectionDecoration() {
        selectionJob?.cancel()
        let job = DispatchWorkItem { [weak self] in self?.highlightBrackets() }
        selectionJob = job
        DispatchQueue.main.async(execute: job)
    }

    func scheduleAnalysis(immediate: Bool = false) {
        analysisJob?.cancel()
        analysisVersion += 1
        let version = analysisVersion, id = activeID, text = textView.string, syntax = activeDocument.syntax
        let job = DispatchWorkItem { [weak self] in
            let index = TextIndex(text)
            let tokens = SyntaxHighlighter.tokens(text, syntax: syntax)
            let completions = TextTools.completionWords(in: text)
            DispatchQueue.main.async {
                guard let self = self, self.activeID == id, self.analysisVersion == version else { return }
                self.currentIndex = index
                self.refreshGutters()
                for (editor, _, _) in self.editorPanes {
                    editor.completionWords = completions
                    editor.newline = (self.activeDocument.preferredEnding ?? index.ending).sequence
                    if !editor.hasMarkedText() { SyntaxHighlighter.apply(tokens, to: editor) }
                }
                self.refreshStatus()
            }
        }
        analysisJob = job
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + (immediate ? 0 : 0.12), execute: job)
    }

    func refreshStatus() {
        guard !documents.isEmpty else { return }
        let selection = textView.selectedRange(), text = textView.string as NSString
        let location = min(selection.location, text.length)
        let line = currentIndex.line(at: location)
        let start = min(currentIndex.starts[line], location)
        let column = text.substring(with: NSRange(location: start, length: location - start)).count + 1
        positionLabel.stringValue = tr("editor.ln_col", line + 1, column)
        if selection.length > 0, NSMaxRange(selection) <= text.length {
            let count = text.substring(with: selection).count
            countLabel.stringValue = tr("editor.selected", count)
        } else { countLabel.stringValue = tr("editor.characters", currentIndex.characters) }
        countLabel.isHidden = groupWidth < 740
        recoveryLabel.isHidden = !recoveryFailed || groupWidth < 900
        recoveryLabel.stringValue = tr("editor.recovery_unavailable")
        recoveryLabel.toolTip = tr("editor.a_local_recovery_copy_could_not_be_written_please_save_your")
        if macroRecording { countLabel.stringValue = "● " + tr("editor.capturing") }
        encodingButton.title = activeDocument.plistFormat == .binary ? PlistFormat.binary.title : activeDocument.encoding.title
        if activeDocument.locked == true { positionLabel.stringValue += "  · " + tr("editor.read_only") }
        encodingButton.toolTip = tr("editor.file_encoding")
        endingButton.title = (activeDocument.preferredEnding ?? currentIndex.ending).title
        endingButton.toolTip = tr("editor.line_endings")
        syntaxButton.title = activeDocument.syntax.title
        syntaxButton.toolTip = tr("editor.syntax_highlighting")
        syntaxButton.isHidden = groupWidth < 480
        encodingButton.isHidden = groupWidth < 380
        compactSyntaxWidth?.isActive = syntaxButton.isHidden
        compactEncodingWidth?.isActive = encodingButton.isHidden
        refreshToolbar()
    }
    func windowDidResize(_ notification: Notification) { refreshStatus(); ruler?.needsDisplay = true; resizeWorkspace() }
    func windowDidChangeEffectiveAppearance(_ notification: Notification) { scheduleAnalysis(immediate: true) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }

    func scheduleRecovery() {
        refreshGutters()
        recoveryJob?.cancel()
        let job = DispatchWorkItem { [weak self] in self?.persistSession() }
        recoveryJob = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: job)
    }
    func persistSession() {
        stashPosition()
        if let manager = workspaceHost?.manager { manager.scheduleSave(); return }
        sessionStore.save(EditorSession(documents: documents, activeID: activeID, folderURL: folderURL)) { [weak self] error in
            self?.recoveryFailed = error != nil
            self?.refreshStatus()
        }
    }

    @objc func newDocument() {
        workspacePlaceholder = false
        let document = EditorDocument()
        documents.append(document)
        activateDocument(document.id)
    }
    @objc func openDocuments() {
        let panel = NSOpenPanel()
        panel.title = tr("editor.open_text_files")
        panel.prompt = tr("common.open")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { openURLs(panel.urls) }
    }
    func openURLs(_ urls: [URL]) {
        for url in urls {
            let url = url.standardizedFileURL
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { setFolder(url); continue }
            if let owner = workspaceHost?.manager?.editor(for: url), owner !== self, let document = owner.documents.first(where: { $0.url?.standardizedFileURL == url.standardizedFileURL }) {
                owner.window?.makeKeyAndOrderFront(nil); owner.activateDocument(document.id); continue
            }
            if let existing = documents.first(where: { $0.url == url }) { activateDocument(existing.id); continue }
            do {
                let document = try EditorDocument.open(url)
                if documents.count == 1 && documents[0].url == nil && documents[0].content.isEmpty && !documents[0].isDirty && documents[0].pinned != true { buffers.removeValue(forKey: documents[0].id); splitBuffers.removeAll(); panePositions.removeAll(); documents = [] }
                documents.append(document)
                rememberRecent(url)
                activateDocument(document.id)
            } catch { presentError(error, operation: tr("editor.could_not_open_file"), filename: url.lastPathComponent) }
        }
    }
    @objc func saveDocument() { _ = save(activeID) }
    @objc func saveAs() { _ = save(activeID, saveAs: true) }
    @discardableResult func save(_ id: UUID, saveAs: Bool = false, overwrite: Bool = false) -> Bool {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return false }
        var destination = documents[index].url
        if destination == nil || saveAs {
            let panel = NSSavePanel()
            panel.title = tr("editor.save_document")
            panel.prompt = tr("common.save")
            panel.nameFieldStringValue = destination?.lastPathComponent ?? "Untitled.txt"
            if let destination = destination { panel.directoryURL = destination.deletingLastPathComponent() }
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            destination = url
        }
        guard let url = destination else { return false }
        if documents.contains(where: { $0.id != id && $0.url == url.standardizedFileURL }) || (workspaceHost?.manager?.windows.flatMap(\.groups).contains { $0 !== self && $0.documents.contains { $0.url == url.standardizedFileURL } } ?? false) {
            presentError(nil, operation: tr("editor.this_file_is_open_in_another_tab"), detail: tr("editor.choose_another_name_to_avoid_overwriting_another_open_document"))
            return false
        }
        do {
            try documents[index].save(to: url, overwrite: overwrite)
            if id == activeID { textView.breakUndoCoalescing() }
            rememberRecent(url)
            refreshTabs(); refreshStatus(); refreshDocumentArea(); scheduleAnalysis(immediate: true)
            refreshWindowMetadata()
            persistSession()
            return true
        } catch FileError.changedOnDisk {
            let alert = NSAlert()
            alert.messageText = tr("editor.this_file_changed_outside_editdot")
            alert.informativeText = tr("editor.overwriting_will_replace_the_version_on_disk_you_can_also_save", url.lastPathComponent)
            alert.alertStyle = .warning
            alert.addButton(withTitle: tr("common.save_as"))
            alert.addButton(withTitle: tr("common.cancel"))
            alert.addButton(withTitle: tr("editor.overwrite"))
            let response = alert.runModal()
            if response == .alertFirstButtonReturn { return save(id, saveAs: true) }
            if response == .alertThirdButtonReturn { return save(id, overwrite: true) }
            return false
        } catch { presentError(error, operation: tr("editor.could_not_save_file"), filename: url.lastPathComponent); return false }
    }
    func confirmSave(_ id: UUID) -> Bool {
        guard let document = documents.first(where: { $0.id == id }), document.isDirty else { return true }
        activateDocument(id)
        let alert = NSAlert()
        alert.messageText = tr("editor.save_changes_to", document.title)
        alert.informativeText = tr("editor.choosing_don_t_save_will_discard_changes_to_this_document")
        alert.addButton(withTitle: tr("common.save"))
        alert.addButton(withTitle: tr("common.cancel"))
        alert.addButton(withTitle: tr("editor.don_t_save"))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn { return save(id) }
        return response == .alertThirdButtonReturn
    }
    @objc func closeActiveDocument() { closeDocument(activeID) }
    func closeDocument(_ id: UUID) {
        if documents.count == 1, documents[0].id == id, let manager = workspaceHost?.manager {
            manager.closeGroup(self)
            return
        }
        guard confirmSave(id), let index = documents.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = activeID == id
        var closed = documents[index]
        closed.discardChanges()
        if closed.url != nil { closedDocuments.append(closed); closedDocuments = Array(closedDocuments.suffix(20)) }
        documents.remove(at: index); buffers.removeValue(forKey: id); splitBuffers.removeValue(forKey: id); panePositions.removeValue(forKey: id)
        if documents.isEmpty { documents.append(EditorDocument()) }
        if wasActive { activateDocument(documents[min(index, documents.count - 1)].id) }
        else { refreshTabs() }
        persistSession()
    }
    func prepareToQuit() -> Bool {
        let dirtyIDs = documents.filter(\.isDirty).map(\.id)
        for id in dirtyIDs { if !confirmSave(id) { return false } }
        for index in documents.indices where documents[index].isDirty {
            documents[index].discardChanges()
        }
        recoveryJob?.cancel()
        persistSession()
        sessionStore.flush()
        return true
    }

    func presentError(_ error: Error?, operation: String, filename: String = "", detail: String = "") {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = operation
        let explanation: String
        if let fileError = error as? FileError { explanation = fileError.localizedDescription }
        else if let nsError = error as NSError? {
            if nsError.code == NSFileReadNoSuchFileError { explanation = tr("editor.the_file_does_not_exist_or_has_been_moved") }
            else if nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileWriteNoPermissionError { explanation = tr("editor.this_location_is_not_accessible_choose_another_location") }
            else if nsError.code == NSFileWriteOutOfSpaceError { explanation = tr("editor.the_disk_is_full_free_some_space_and_try_again") }
            else { explanation = tr("editor.the_operation_could_not_be_completed_check_file_permissions_and_disk") }
        } else { explanation = detail }
        alert.informativeText = [filename, explanation].filter { !$0.isEmpty }.joined(separator: "\n")
        alert.addButton(withTitle: tr("common.ok"))
        alert.runModal()
    }

    @objc func showFind() { presentFind(focus: true, prefillSelection: true) }
    @objc func showReplace() {
        presentFind(focus: true, prefillSelection: true)
        findPanel?.window?.makeFirstResponder(replacementField)
        replacementField.selectText(nil)
    }
    func presentFind(focus: Bool, prefillSelection: Bool) {
        if activeDocument.syntax == .markdown && markdownMode == .preview { setMarkdownMode(.source) }
        if focus { workspaceHost?.focus(self) }
        let selection = textView.selectedRange()
        if prefillSelection, !findVisible {
            searchScope = selection.length > 0 ? selection : nil
            if selection.length > 0, selection.length < 256 {
                findField.stringValue = (textView.string as NSString).substring(with: selection)
            }
        }
        if findPanel == nil { findPanel = FindPanelController(editor: self) }
        findVisible = true
        findPanel?.present(focus: focus)
        scheduleSearch()
    }
    @objc func hideFind() { dismissFind(restoreFocus: true) }
    func dismissFind(restoreFocus: Bool) {
        guard findVisible else { return }
        findVisible = false
        findPanel?.dismiss()
        searchJob?.cancel(); searchVersion += 1
        searchResult = SearchResult(); highlightMatches()
        if restoreFocus { window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(textView) }
    }
    @objc func searchOptionsChanged() {
        if regexButton.state == .on { extendedSearch = false }
        findPanel?.syncOptions(); scheduleSearch(); refreshMainMenu()
    }
    func rememberFindQuery() {
        let query = findField.stringValue
        guard !query.isEmpty, query.utf8.count <= 4096 else { return }
        findField.recentSearches = Array(([query] + findField.recentSearches.filter { $0 != query }).prefix(20))
    }
    func refreshFindStatus() {
        guard !isLoading, !documents.isEmpty else { return }
        let result = searchResult, query = effectiveQuery
        let selection = textView.selectedRange()
        let position = result.matches.firstIndex { $0.range == selection }
        if result.timedOut { matchLabel.stringValue = tr("editor.timed_out") }
        else if result.invalid { matchLabel.stringValue = tr("editor.invalid_regex") }
        else if query.isEmpty { matchLabel.stringValue = "" }
        else if let position = position { matchLabel.stringValue = "\(position + 1) / \(result.matches.count)\(result.limited ? "+" : "")" }
        else { matchLabel.stringValue = "\(result.matches.count)\(result.limited ? "+" : "") " + tr("editor.matches") }
        matchLabel.textColor = result.invalid || result.timedOut ? .systemRed : .secondaryLabelColor
        matchLabel.toolTip = result.timedOut ? tr("editor.search_took_too_long_simplify_the_expression_or_narrow_the_search") : result.limited ? tr("editor.showing_the_first_10_000_matches") : nil
        replaceOneButton.isEnabled = !result.matches.isEmpty && !result.invalid && activeDocument.locked != true
        replaceAllButton.isEnabled = !result.matches.isEmpty && !result.limited && !result.invalid && activeDocument.locked != true
        findPanel?.refreshDocument()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === findField || control === replacementField else { return false }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { hideFind(); return true }
        if control === findField, commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { findPrevious() } else { findNext() }
            return true
        }
        return false
    }
    func scheduleSearch() {
        searchJob?.cancel(); searchVersion += 1
        let version = searchVersion, id = activeID, text = textView.string, query = effectiveQuery
        let matchCase = caseButton.state == .on, regex = regexButton.state == .on
        let word = wholeWord, scope = effectiveScope
        let job = DispatchWorkItem { [weak self] in
            let result = SearchResult.find(query, in: text, matchCase: matchCase, regex: regex, wholeWord: word, range: scope)
            DispatchQueue.main.async {
                guard let self = self, self.searchVersion == version, self.activeID == id, self.findVisible else { return }
                self.searchResult = result
                self.refreshFindStatus()
                self.highlightMatches()
            }
        }
        searchJob = job
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.12, execute: job)
    }
    func highlightMatches() {
        guard primaryEditor.textStorage?.editedMask.contains(.editedCharacters) != true else { return }
        for (editor, _, _) in editorPanes {
            guard let manager = editor.layoutManager, let container = editor.textContainer else { continue }
            let length = (editor.string as NSString).length
            manager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
            guard findVisible else { continue }
            let glyphs = manager.glyphRange(forBoundingRect: editor.visibleRect.offsetBy(dx: -editor.textContainerOrigin.x, dy: -editor.textContainerOrigin.y), in: container)
            let visible = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            for match in searchResult.matches where NSMaxRange(match.range) <= length && NSIntersectionRange(match.range, visible).length > 0 {
                manager.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.22), forCharacterRange: match.range)
            }
        }
    }
    private func freshSearch() {
        searchJob?.cancel(); searchVersion += 1
        searchResult = SearchResult.find(effectiveQuery, in: textView.string, matchCase: caseButton.state == .on, regex: regexButton.state == .on, wholeWord: wholeWord, range: effectiveScope)
        refreshFindStatus()
    }
    @objc func findNext() { navigateMatch(forward: true) }
    @objc func findPrevious() { navigateMatch(forward: false) }
    private func navigateMatch(forward: Bool) {
        guard findVisible else { showFind(); return }
        rememberFindQuery(); freshSearch()
        guard !searchResult.matches.isEmpty else { NSSound.beep(); return }
        let selection = textView.selectedRange()
        let candidate: NSTextCheckingResult?
        if forward { candidate = searchResult.matches.first { $0.range.location >= NSMaxRange(selection) && $0.range != selection } }
        else { candidate = searchResult.matches.last { NSMaxRange($0.range) <= selection.location && $0.range != selection } }
        guard let next = candidate ?? (searchWraps ? (forward ? searchResult.matches.first : searchResult.matches.last) : nil) else {
            matchLabel.stringValue = forward ? tr("editor.end_of_matches") : tr("editor.start_of_matches")
            return
        }
        textView.setSelectedRange(next.range)
        textView.scrollRangeToVisible(next.range)
        refreshFindStatus(); highlightMatches()
    }
    @objc func replaceOne() {
        guard activeDocument.locked != true else { return }
        rememberFindQuery(); freshSearch()
        let selection = textView.selectedRange()
        guard let match = searchResult.matches.first(where: { $0.range == selection }) else { findNext(); return }
        let replacement = regexButton.state == .on ? searchResult.expression!.replacementString(for: match, in: textView.string, offset: 0, template: effectiveReplacement) : effectiveReplacement
        let scope = effectiveScope
        guard applyChange(TextChange(range: match.range, text: replacement), name: tr("common.replace")) else { findNext(); return }
        if let scope = scope { searchScope = NSRange(location: scope.location, length: scope.length + (replacement as NSString).length - match.range.length) }
        findNext()
    }
    @objc func replaceAll() {
        guard activeDocument.locked != true else { return }
        rememberFindQuery(); freshSearch()
        guard !searchResult.matches.isEmpty, !searchResult.limited, let expression = searchResult.expression else { return }
        let template = regexButton.state == .on ? effectiveReplacement : NSRegularExpression.escapedTemplate(for: effectiveReplacement)
        let scope = effectiveScope ?? NSRange(location: 0, length: (textView.string as NSString).length)
        let replacement = NSMutableString(string: (textView.string as NSString).substring(with: scope))
        for match in searchResult.matches.reversed() {
            let value = expression.replacementString(for: match, in: textView.string, offset: 0, template: template)
            replacement.replaceCharacters(in: NSRange(location: match.range.location - scope.location, length: match.range.length), with: value)
        }
        if applyChange(TextChange(range: scope, text: replacement as String), name: tr("common.replace_all")), selectionOnly { searchScope = NSRange(location: scope.location, length: replacement.length) }
    }

    @objc func showEncodingMenu() {
        if activeDocument.plistFormat == .binary {
            let menu = plistStorageMenu(); menu.popUp(positioning: nil, at: NSPoint(x: 0, y: encodingButton.bounds.height), in: encodingButton); return
        }
        let menu = NSMenu()
        for (index, encoding) in TextEncoding.allCases.enumerated() {
            let item = NSMenuItem(title: encoding.title, action: #selector(selectEncoding(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; item.state = encoding == activeDocument.encoding ? .on : .off; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: encodingButton.bounds.height), in: encodingButton)
    }
    @objc func selectEncoding(_ sender: NSMenuItem) {
        guard activeDocument.locked != true, activeDocument.plistFormat != .binary else { return }
        let encoding = TextEncoding.allCases[sender.tag]
        guard activeDocument.encoding != encoding else { return }
        textView.breakUndoCoalescing(); textView.undoManager?.beginUndoGrouping()
        setDocumentEncoding(encoding, for: activeID)
        if [.xml, .plist].contains(activeDocument.syntax) {
            if let range = DocumentFormats.xmlEncodingRange(in: textView.string) {
                let selection = textView.selectedRange(), charset = encoding.xmlCharset
                let delta = (charset as NSString).length - range.length
                if applyChange(TextChange(range: range, text: charset), name: tr("editor.update_xml_encoding_declaration")) {
                    let location = max(0, min((textView.string as NSString).length, selection.location >= NSMaxRange(range) ? selection.location + delta : selection.location))
                    textView.setSelectedRange(NSRange(location: location, length: min(selection.length, (textView.string as NSString).length - location)))
                }
            }
        }
        textView.undoManager?.endUndoGrouping(); textView.undoManager?.setActionName(tr("editor.change_text_encoding"))
        refreshTabs(); refreshStatus(); scheduleRecovery()
        refreshWindowMetadata()
    }
    func setDocumentEncoding(_ encoding: TextEncoding, for id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        let previous = documents[index].encoding
        buffers[id]?.undoManager?.registerUndo(withTarget: self) { $0.setDocumentEncoding(previous, for: id) }
        documents[index].encoding = encoding
        if id == activeID { refreshTabs(); refreshStatus(); scheduleRecovery(); refreshWindowMetadata() }
    }
    @objc func showEndingMenu() {
        let menu = NSMenu()
        for (index, ending) in [LineEnding.lf, .crlf, .cr].enumerated() {
            let item = NSMenuItem(title: ending.rawValue, action: #selector(selectEnding(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; item.state = ending == currentIndex.ending ? .on : .off; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: endingButton.bounds.height), in: endingButton)
    }
    @objc func selectEnding(_ sender: NSMenuItem) {
        guard activeDocument.locked != true else { return }
        let ending: LineEnding = [.lf, .crlf, .cr][sender.tag]
        let hasLineBreak = textView.string.contains("\n") || textView.string.contains("\r")
        documents[activeIndex].preferredEnding = hasLineBreak ? nil : ending
        let content = ending.convert(textView.string)
        guard content != textView.string else { textView.newline = ending.sequence; refreshStatus(); scheduleRecovery(); return }
        applyChange(TextChange(range: NSRange(location: 0, length: (textView.string as NSString).length), text: content), name: tr("editor.convert_line_endings"))
        textView.newline = ending.sequence
    }
    @objc func showSyntaxMenu() {
        let menu = NSMenu()
        for (index, syntax) in Syntax.allCases.enumerated() {
            let item = NSMenuItem(title: syntax.title, action: #selector(selectSyntax(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; item.state = syntax == activeDocument.syntax ? .on : .off; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: syntaxButton.bounds.height), in: syntaxButton)
    }
    @objc func selectSyntax(_ sender: NSMenuItem) {
        documents[activeIndex].syntax = Syntax.allCases[sender.tag]
        refreshDocumentArea()
        scheduleAnalysis(immediate: true); refreshStatus(); refreshTabs(); scheduleRecovery()
    }
    @objc func goToLine() {
        let alert = NSAlert()
        alert.messageText = tr("editor.go_to_line")
        alert.informativeText = tr("editor.enter_a_line_number_1", currentIndex.starts.count)
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = String(currentIndex.line(at: textView.selectedRange().location) + 1)
        alert.accessoryView = input
        alert.addButton(withTitle: tr("editor.go")); alert.addButton(withTitle: tr("common.cancel"))
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let number = Int(input.stringValue.trimmingCharacters(in: .whitespaces)), number >= 1, number <= currentIndex.starts.count else {
            presentError(nil, operation: tr("editor.invalid_line_number"), detail: tr("editor.enter_a_whole_number_from_1_to", currentIndex.starts.count)); return
        }
        let range = NSRange(location: currentIndex.starts[number - 1], length: 0)
        window?.makeFirstResponder(textView); textView.setSelectedRange(range); textView.scrollRangeToVisible(range)
    }
    @objc func nextTab() { activateDocument(documents[(activeIndex + 1) % documents.count].id) }
    @objc func previousTab() { activateDocument(documents[(activeIndex + documents.count - 1) % documents.count].id) }

    @objc func changeLanguage(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        let language: Language?
        if let identifier = item.representedObject as? String { language = Language(rawValue: identifier) }
        else { language = Language.available.indices.contains(item.tag) ? Language.available[item.tag] : nil }
        guard let language = language else { return }
        Language.current = language
        UserDefaults.standard.set(Language.current.rawValue, forKey: "language")
        if let manager = workspaceHost?.manager { manager.refreshPreferences() } else { refreshLocalization() }
    }
    func refreshLocalization(rebuildTabs: Bool = true) {
        refreshDocumentArea()
        refreshMainMenu()
        preferences?.refreshLocalization()
        about?.refreshLocalization()
        UpdateController.shared.refreshLocalization()
        documentInfo?.refreshLocalization()
        quickPicker?.close()
        if browserLoaded { browser.refreshLocalization() }
        if resultsLoaded { results.refreshLocalization(); refreshSearchSummary() }
        findField.placeholderString = tr("common.find")
        findField.setAccessibilityLabel(tr("editor.find_text"))
        replacementField.placeholderString = tr("common.replace_with")
        replacementField.setAccessibilityLabel(tr("editor.replacement_text"))
        replaceOneButton.title = tr("common.replace")
        replaceAllButton.title = tr("common.replace_all")
        caseButton.title = tr("common.match_case")
        regexButton.title = tr("common.regular_expression")
        caseButton.toolTip = caseButton.title
        regexButton.toolTip = tr("common.regular_expression")
        caseButton.setAccessibilityLabel(caseButton.toolTip)
        regexButton.setAccessibilityLabel(regexButton.toolTip)
        refreshToolbar()
        findPanel?.refreshLocalization()
        tabsBar.subviews.first(where: { $0.identifier?.rawValue == "newTab" })?.toolTip = tr("common.new_document_n")
        if rebuildTabs { refreshTabs() }
        refreshStatus()
        refreshWindowMetadata()
        if findVisible { scheduleSearch() }
    }

    func applyAppearance() {
        scheduleMarkdownPreview(immediate: true)
        switch UserDefaults.standard.string(forKey: "theme") ?? "system" {
        case "light": window?.appearance = NSAppearance(named: .aqua)
        case "dark": window?.appearance = NSAppearance(named: .darkAqua)
        default: window?.appearance = nil
        }
        root.needsDisplay = true; tabsBar.needsDisplay = true; footer.needsDisplay = true
        findPanel?.window?.appearance = window?.appearance
        about?.window?.appearance = window?.appearance
        refreshTabs(); scheduleAnalysis(immediate: true)
    }
    @objc func toggleWrap() { UserDefaults.standard.set(!wraps, forKey: "wrap"); sharedPreferencesChanged() }
    @objc func toggleLineNumbers() { UserDefaults.standard.set(!showsLines, forKey: "lineNumbers"); sharedPreferencesChanged() }
    @objc func increaseFont() { setFontSize(fontSize + 1) }
    @objc func decreaseFont() { setFontSize(fontSize - 1) }
    @objc func resetFont() { setFontSize(14) }
    private func setFontSize(_ size: CGFloat) { UserDefaults.standard.set(Double(min(28, max(10, size))), forKey: "fontSize"); sharedPreferencesChanged() }
    @objc func selectTheme(_ sender: NSMenuItem) {
        UserDefaults.standard.set(["system", "light", "dark"][sender.tag], forKey: "theme")
        if let manager = workspaceHost?.manager { manager.refreshPreferences() } else { applyAppearance(); refreshMainMenu() }
    }
    @objc func showPreferences() {
        if preferences == nil {
            preferences = PreferencesController()
            preferences?.onChange = { [weak self] key, value in
                UserDefaults.standard.set(value, forKey: key)
                if let manager = self?.workspaceHost?.manager { manager.refreshPreferences() }
                else { self?.applyEditorPreferences(); self?.applyAppearance() }
                self?.preferences?.window?.appearance = self?.window?.appearance
            }
        }
        preferences?.syncValues(); preferences?.window?.appearance = window?.appearance
        preferences?.showWindow(nil); preferences?.window?.center(); preferences?.window?.makeKeyAndOrderFront(nil)
    }
    @objc func showAbout() {
        if about == nil { about = AboutController() }
        about?.refreshLocalization(); about?.present(relativeTo: window)
    }

    func item(_ title: String, _ action: Selector?, key: String = "", modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target ?? (action == nil ? nil : self)
        item.tag = tag
        return item
    }
    func viewMenu() -> NSMenu {
        let menu = NSMenu(title: tr("editor.view"))
        extendViewMenu(menu)
        let syntax = syntaxMenu()
        let entry = item(tr("editor.code_language"), nil); entry.submenu = syntax; menu.addItem(entry)
        return menu
    }
    func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func add(_ title: String, _ menu: NSMenu) { let entry = NSMenuItem(title: title, action: nil, keyEquivalent: ""); entry.submenu = menu; main.addItem(entry) }
        let app = NSMenu()
        app.addItem(item(tr("common.about_editdot"), #selector(showAbout)))
        app.addItem(item(tr("updates.check"), #selector(UpdateController.checkForUpdates(_:)), target: UpdateController.shared))
        app.addItem(.separator())
        app.addItem(item(tr("editor.settings"), #selector(showPreferences), key: ","))
        app.addItem(item(tr("editor.quick_actions"), #selector(showQuickActions), key: "p", modifiers: [.command, .shift]))
        let languages = NSMenu(title: tr("editor.interface_language"))
        for (index, language) in Language.available.enumerated() {
            let entry = item(language.title, #selector(changeLanguage(_:)), tag: index)
            entry.representedObject = language.rawValue
            entry.state = Language.current == language ? .on : .off; languages.addItem(entry)
        }
        let language = item(languages.title, nil); language.submenu = languages; app.addItem(language)
        let textSize = NSMenu(title: tr("editor.text_size"))
        textSize.addItem(item(tr("editor.one_step_larger"), #selector(increaseFont), key: "+"))
        textSize.addItem(item(tr("editor.one_step_smaller"), #selector(decreaseFont), key: "-"))
        textSize.addItem(item(tr("editor.default_size"), #selector(resetFont), key: "0"))
        let sizeItem = item(textSize.title, nil); sizeItem.submenu = textSize; app.addItem(sizeItem)
        app.addItem(.separator())
        let hide = NSMenuItem(title: tr("editor.hide_editdot"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"); app.addItem(hide)
        let hideOthers = NSMenuItem(title: tr("editor.hide_others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"); hideOthers.keyEquivalentModifierMask = [.command, .option]; app.addItem(hideOthers)
        app.addItem(.separator()); app.addItem(NSMenuItem(title: tr("editor.quit_editdot"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        add("EditDot", app)
        let file = NSMenu(title: tr("common.documents"))
        if let manager = workspaceHost?.manager {
            file.addItem(item(tr("common.new"), #selector(WorkspaceManager.createDocument(_:)), key: "n", target: manager))
            file.addItem(item(tr("common.new_window"), #selector(WorkspaceManager.createWindow(_:)), key: "n", modifiers: [.command, .shift], target: manager))
            file.addItem(item(tr("common.open_2"), #selector(WorkspaceManager.openDocuments(_:)), key: "o", target: manager))
        } else {
            file.addItem(item(tr("common.new"), #selector(newDocument), key: "n"))
            file.addItem(item(tr("common.open_2"), #selector(openDocuments), key: "o"))
        }
        file.addItem(.separator())
        file.addItem(item(tr("common.save"), #selector(saveDocument), key: "s"))
        file.addItem(item(tr("common.save_as"), #selector(saveAs), key: "s", modifiers: [.command, .shift]))
        file.addItem(.separator()); file.addItem(item(tr("common.close_tab"), #selector(closeActiveDocument), key: "w"))
        extendFileMenu(file)
        add(file.title, file)
        let edit = NSMenu(title: tr("editor.edit"))
        for (title, action, key, modifiers) in [
            (tr("common.undo"), #selector(EditorTextView.undo(_:)), "z", NSEvent.ModifierFlags.command),
            (tr("common.redo"), #selector(EditorTextView.redo(_:)), "z", [.command, .shift]),
            (tr("editor.cut"), #selector(NSText.cut(_:)), "x", .command),
            (tr("editor.copy"), #selector(NSText.copy(_:)), "c", .command),
            (tr("editor.paste"), #selector(NSText.paste(_:)), "v", .command),
            (tr("common.select_all"), #selector(NSText.selectAll(_:)), "a", .command)
        ] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key); entry.keyEquivalentModifierMask = modifiers; edit.addItem(entry)
        }
        extendEditMenu(edit)
        add(edit.title, edit)
        let search = searchMenu(); add(search.title, search)
        let view = viewMenu(); add(view.title, view)
        let macro = macroMenu(); add(macro.title, macro)
        let windowMenu = NSMenu(title: tr("editor.window"))
        let minimize = NSMenuItem(title: tr("editor.minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"); windowMenu.addItem(minimize)
        windowMenu.addItem(item(tr("editor.next_tab"), #selector(nextTab), key: "]", modifiers: [.command, .shift]))
        windowMenu.addItem(item(tr("editor.previous_tab"), #selector(previousTab), key: "[", modifiers: [.command, .shift]))
        if let host = workspaceHost {
            windowMenu.addItem(item(tr("editor.next_editor_group"), #selector(focusNextGroup), key: "]", modifiers: [.command, .option]))
            windowMenu.addItem(item(tr("editor.previous_editor_group"), #selector(focusPreviousGroup), key: "[", modifiers: [.command, .option]))
            windowMenu.addItem(item(tr("editor.merge_into_this_group"), #selector(mergeEditorGroups)))
            windowMenu.addItem(item(tr("editor.close_editor_group"), #selector(closeEditorGroup)))
            windowMenu.addItem(item(tr("editor.close_this_window"), #selector(NSWindow.performClose(_:)), key: "w", modifiers: [.command, .shift], target: window))
            windowMenu.addItem(.separator())
            for workspace in host.manager?.windows ?? [] {
                let title = workspace.focused?.documents.first(where: { $0.id == workspace.focused?.activeID })?.title ?? "EditDot"
                let entry = item(title, #selector(showWorkspaceWindow(_:)))
                entry.representedObject = workspace.id; entry.state = workspace === host ? .on : .off; windowMenu.addItem(entry)
            }
        }
        windowMenu.addItem(.separator())
        for (index, document) in documents.enumerated() {
            let entry = item(document.title + (document.isDirty ? " •" : ""), #selector(selectDocument(_:)), key: index < 9 ? String(index + 1) : "")
            entry.representedObject = document.id.uuidString; entry.state = document.id == activeID ? .on : .off
            windowMenu.addItem(entry)
        }
        add(windowMenu.title, windowMenu)
        return main
    }
}
