// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import AppKit

final class AssociationSettingsView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let service: FileAssociations
    let table = NSTableView()
    let field = NSTextField()
    let addButton = NSButton()
    let removeButton = NSButton()
    let applyButton = NSButton()
    let restoreButton = NSButton()
    let refreshButton = NSButton()
    let status = label("", size: 11)
    let note = label("", size: 11)
    let extensionHeading = label("", size: 11)
    let applicationHeading = label("", size: 11)
    let selectAllButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let categoryButton = NSPopUpButton()
    let searchField = NSSearchField()
    private(set) var selected = Set<String>()
    private var rows: [String] = []
    private var applications: [String: URL] = [:]
    private var message: AssociationResult?
    private var invalidInput = false
    private var restoring = false
    private var observer: NSObjectProtocol?

    init(service: FileAssociations = FileAssociations()) {
        self.service = service
        super.init(frame: .zero)
        for button in [addButton, removeButton, applyButton, restoreButton, refreshButton] {
            button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 12); button.target = self
        }
        addButton.action = #selector(addExtension); removeButton.action = #selector(removeExtension)
        applyButton.action = #selector(applySelection); restoreButton.action = #selector(restoreSelection); refreshButton.action = #selector(refresh)
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refreshButton.imagePosition = .imageOnly
        field.font = .systemFont(ofSize: 12); field.target = self; field.action = #selector(addExtension)
        let entry = NSStackView(views: [field, addButton, removeButton, refreshButton]); entry.spacing = 6
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        selectAllButton.target = self; selectAllButton.action = #selector(selectAllExtensions); selectAllButton.allowsMixedState = true; selectAllButton.font = .systemFont(ofSize: 12)
        categoryButton.target = self; categoryButton.action = #selector(filterChanged); categoryButton.font = .systemFont(ofSize: 12)
        searchField.font = .systemFont(ofSize: 12); searchField.delegate = self
        let filters = NSStackView(views: [selectAllButton, categoryButton, searchField]); filters.spacing = 10
        categoryButton.widthAnchor.constraint(equalToConstant: 150).isActive = true
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        table.headerView = nil; table.rowHeight = 27; table.intercellSpacing = NSSize(width: 8, height: 0)
        table.usesAlternatingRowBackgroundColors = true; table.allowsMultipleSelection = false
        let choice = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("choice")); choice.width = 28; choice.minWidth = 28; choice.maxWidth = 28
        let ext = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("extension")); ext.width = 135; ext.minWidth = 100
        let app = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("application")); app.width = 280; app.minWidth = 140
        for column in [choice, ext, app] { table.addTableColumn(column) }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.delegate = self; table.dataSource = self
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder
        scroll.automaticallyAdjustsContentInsets = false; scroll.contentInsets = NSEdgeInsetsZero
        let checkHeading = NSView(); checkHeading.widthAnchor.constraint(equalToConstant: 28).isActive = true
        extensionHeading.widthAnchor.constraint(equalToConstant: 135).isActive = true
        let header = NSStackView(views: [checkHeading, extensionHeading, applicationHeading]); header.spacing = 8
        header.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let listing = NSStackView(views: [header, scroll]); listing.orientation = .vertical; listing.alignment = .leading; listing.spacing = 4
        header.widthAnchor.constraint(equalTo: listing.widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalTo: listing.widthAnchor).isActive = true
        note.maximumNumberOfLines = 2; note.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 2; status.lineBreakMode = .byWordWrapping
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [restoreButton, spacer, applyButton]); actions.spacing = 8
        let stack = NSStackView(views: [filters, listing, entry, note, status, actions]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150), status.heightAnchor.constraint(greaterThanOrEqualToConstant: 28)
        ])
        for view in [filters, entry, listing, note, status, actions] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] event in
            guard let self = self, event.object as? NSWindow === self.window, !self.service.isApplying else { return }; self.refresh()
        }
        refreshLocalization(); refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    deinit { if let observer = observer { NotificationCenter.default.removeObserver(observer) } }
    override func layout() {
        super.layout()
        guard let scroll = table.enclosingScrollView, abs(table.frame.width - scroll.contentSize.width) > 0.5 else { return }
        table.setFrameSize(NSSize(width: scroll.contentSize.width, height: table.frame.height))
        table.sizeLastColumnToFit()
    }
    func refreshLocalization() {
        let category = categoryButton.indexOfSelectedItem
        categoryButton.removeAllItems(); categoryButton.addItems(withTitles: ExtensionCategory.allCases.map(\.title)); categoryButton.selectItem(at: max(0, category))
        categoryButton.setAccessibilityLabel(tr("associations.extension_category"))
        searchField.placeholderString = tr("common.filter_extensions")
        searchField.setAccessibilityLabel(tr("common.filter_extensions"))
        field.placeholderString = tr("associations.extension_e_g_txt_or_md")
        field.setAccessibilityLabel(tr("associations.custom_extension"))
        addButton.title = tr("associations.add"); removeButton.title = tr("associations.remove")
        removeButton.toolTip = tr("associations.remove_from_the_custom_list_without_changing_the_default_app")
        applyButton.title = tr("associations.open_with_editdot")
        restoreButton.title = tr("associations.restore_previous_app")
        refreshButton.toolTip = tr("associations.refresh_default_apps")
        table.tableColumns[0].title = ""
        table.tableColumns[1].title = tr("associations.extension")
        table.tableColumns[2].title = tr("associations.current_default_app")
        extensionHeading.stringValue = table.tableColumns[1].title; applicationHeading.stringValue = table.tableColumns[2].title
        table.setAccessibilityLabel(tr("associations.file_associations"))
        note.stringValue = tr("associations.select_extensions_then_apply_extensions_sharing_a_file_type_change_together")
        for button in [addButton, removeButton, applyButton, restoreButton] { button.setAccessibilityLabel(button.title) }
        reloadTable(); updateControls()
    }
    @objc func refresh() {
        guard !service.isApplying else { return }
        let focused = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil
        let category = ExtensionCategory.allCases[max(0, categoryButton.indexOfSelectedItem)]
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        rows = service.extensions.filter { (category == .all || FileAssociations.category(for: $0) == category) && (query.isEmpty || $0.contains(query)) }
        selected.formIntersection(service.extensions)
        applications = [:]
        for ext in rows { if let app = service.currentApplication(for: ext) { applications[ext] = app } }
        table.reloadData()
        if let focused = focused, let row = rows.firstIndex(of: focused) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        updateControls()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    private func reloadTable() {
        let row = table.selectedRow
        table.reloadData()
        if rows.indices.contains(row) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let ext = rows[row]
        if tableColumn?.identifier.rawValue == "choice" {
            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(selectExtension(_:)))
            button.tag = row; button.state = selected.contains(ext) ? .on : .off; button.isEnabled = !service.isApplying
            button.setAccessibilityLabel(".\(ext)"); return button
        }
        let value: String
        if tableColumn?.identifier.rawValue == "extension" { value = "." + ext }
        else if let url = applications[ext] { value = (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? url.deletingPathExtension().lastPathComponent }
        else { value = tr("associations.not_set") }
        let cell = NSTextField(labelWithString: value); cell.font = .systemFont(ofSize: 12); cell.lineBreakMode = .byTruncatingMiddle
        cell.toolTip = tableColumn?.identifier.rawValue == "application" ? applications[ext]?.path : nil
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateControls() }
    @objc func selectAllExtensions() {
        guard !service.isApplying else { return }
        if !rows.isEmpty && rows.allSatisfy(selected.contains) { selected.subtract(rows) } else { selected.formUnion(rows) }
        invalidInput = false; message = nil; reloadTable(); updateControls()
    }
    @objc func filterChanged() { refresh() }
    func controlTextDidChange(_ obj: Notification) { if obj.object as? NSSearchField === searchField { refresh() } }
    @objc func selectExtension(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag), !service.isApplying else { return }
        let ext = rows[sender.tag]
        if sender.state == .on { selected.insert(ext) } else { selected.remove(ext) }
        message = nil; invalidInput = false; updateControls()
    }
    @objc func addExtension() {
        guard !service.isApplying else { return }
        guard service.add(field.stringValue), let ext = FileAssociations.normalizedExtension(field.stringValue) else { invalidInput = true; message = nil; updateControls(); return }
        field.stringValue = ""; selected.insert(ext); invalidInput = false; message = nil
        categoryButton.selectItem(at: 0); searchField.stringValue = ""; refresh()
        if let row = rows.firstIndex(of: ext) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row) }
    }
    @objc func removeExtension() {
        guard !service.isApplying, rows.indices.contains(table.selectedRow) else { return }
        let ext = rows[table.selectedRow]
        guard service.customExtensions.contains(ext) else { return }
        service.remove(ext); selected.remove(ext); message = nil; refresh()
    }
    @objc func applySelection() { apply(restoring: false) }
    @objc func restoreSelection() { apply(restoring: true) }
    private func apply(restoring: Bool) {
        guard !selected.isEmpty, !service.isApplying else { return }
        self.restoring = restoring; invalidInput = false; message = nil
        service.apply(Array(selected), restoring: restoring) { [weak self] result in self?.message = result; self?.refresh() }
        reloadTable(); updateControls()
    }
    private func updateControls() {
        let busy = service.isApplying
        let filtered = categoryButton.indexOfSelectedItem > 0 || !searchField.stringValue.isEmpty
        selectAllButton.title = filtered ? tr("associations.select_results") : tr("common.select_all")
        selectAllButton.state = rows.isEmpty || !rows.contains(where: selected.contains) ? .off : rows.allSatisfy(selected.contains) ? .on : .mixed
        selectAllButton.isEnabled = !busy && !rows.isEmpty; categoryButton.isEnabled = !busy; searchField.isEnabled = !busy
        field.isEnabled = !busy; addButton.isEnabled = !busy; refreshButton.isEnabled = !busy
        applyButton.isEnabled = !busy && !selected.isEmpty
        restoreButton.isEnabled = !busy && selected.contains(where: service.canRestore)
        removeButton.isEnabled = !busy && rows.indices.contains(table.selectedRow) && service.customExtensions.contains(rows[table.selectedRow])
        status.textColor = .secondaryLabelColor; status.toolTip = nil
        if busy { status.stringValue = tr("associations.updating_default_apps") }
        else if invalidInput { status.stringValue = tr("associations.enter_an_extension_such_as_txt_without_a_filename_path_or"); status.textColor = .systemRed }
        else if let result = message {
            let success = result.changed.count, failed = result.failures.count
            if failed == 0 { status.stringValue = restoring ? tr("associations.restored_default_apps_for_extensions", success) : tr("associations.editdot_is_now_the_default_for_extensions", success) }
            else {
                status.stringValue = tr("associations.updated_failed", success, failed) + result.failures.keys.sorted().map { "." + $0 }.joined(separator: ", ")
                if let first = result.failures.keys.sorted().first { status.stringValue += "\n" + result.failures[first]!.localizedDescription }
                status.textColor = .systemRed
                status.toolTip = result.failures.keys.sorted().map { ".\($0): \(result.failures[$0]!.localizedDescription)" }.joined(separator: "\n")
            }
        } else { status.stringValue = tr("associations.selected", selected.count) }
    }
}
