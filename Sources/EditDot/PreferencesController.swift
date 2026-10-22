// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import AppKit

final class PreferencesController: NSWindowController, NSTabViewDelegate {
    var controls: [String: NSControl] = [:]
    var onChange: ((String, Any) -> Void)?
    let tabs = NSTabView()
    let generalButton = NSButton()
    let associationsButton = NSButton()
    lazy var associationSettings = AssociationSettingsView()
    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 540), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        tabs.tabViewType = .noTabsNoBorder; tabs.delegate = self
        for button in [generalButton, associationsButton] {
            button.bezelStyle = .rounded; button.setButtonType(.pushOnPushOff); button.font = .systemFont(ofSize: 12)
            button.target = self; button.action = #selector(selectSection(_:))
            button.imagePosition = .imageLeft
            button.widthAnchor.constraint(equalToConstant: 124).isActive = true
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        }
        generalButton.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        associationsButton.image = NSImage(systemSymbolName: "doc.badge.gearshape", accessibilityDescription: nil)
        refreshLocalization()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func refreshLocalization() {
        window?.title = tr("preferences.editdot_settings")
        let selected = tabs.selectedTabViewItem?.identifier as? String ?? "general"
        for tab in tabs.tabViewItems { tabs.removeTabViewItem(tab) }
        let content = NSView()
        controls = [:]
        let theme = popup("theme", choices: [tr("preferences.follow_system"), tr("preferences.light"), tr("preferences.dark")])
        let font = popup("fontSize", choices: (10...28).map { "\($0) pt" }, tags: Array(10...28))
        let indent = popup("indentWidth", choices: ["2", "4", "8"], tags: [2, 4, 8])
        let display = grid([
            [caption(tr("preferences.appearance")), theme],
            [caption(tr("preferences.editor_font_size")), font],
            [NSView(), checkbox("wrap", title: tr("preferences.wrap_long_lines"))],
            [NSView(), checkbox("lineNumbers", title: tr("preferences.show_line_gutter"))],
            [NSView(), checkbox("whitespace", title: tr("preferences.reveal_spaces_and_tabs"))]
        ])
        let editing = grid([
            [caption(tr("preferences.indent_size")), indent],
            [NSView(), checkbox("usesTabs", title: tr("preferences.use_tab_characters"))],
            [NSView(), checkbox("closeBrackets", title: tr("preferences.pair_brackets_and_quotes"))]
        ])
        let separator = NSBox(); separator.boxType = .separator
        let documents = grid([[caption(tr("common.markdown_view")), popup("markdownDefaultView", choices: MarkdownViewMode.allCases.map(\.title))]])
        let documentSeparator = NSBox(); documentSeparator.boxType = .separator
        let stack = NSStackView(views: [caption(tr("preferences.display"), heading: true), display, separator, caption(tr("preferences.typing"), heading: true), editing, documentSeparator, caption(tr("common.documents"), heading: true), documents])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 23),
            display.widthAnchor.constraint(equalTo: stack.widthAnchor), editing.widthAnchor.constraint(equalTo: stack.widthAnchor), separator.widthAnchor.constraint(equalTo: stack.widthAnchor), documents.widthAnchor.constraint(equalTo: stack.widthAnchor), documentSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        let general = NSTabViewItem(identifier: "general"); general.label = tr("preferences.general"); general.view = content
        let associations = NSTabViewItem(identifier: "associations"); associations.label = tr("preferences.file_associations"); associations.view = associationSettings
        generalButton.title = general.label; associationsButton.title = associations.label
        associationSettings.refreshLocalization()
        tabs.addTabViewItem(general); tabs.addTabViewItem(associations); tabs.selectTabViewItem(withIdentifier: selected)
        let host = NSView(); window?.contentView = host
        let sections = NSStackView(views: [generalButton, associationsButton]); sections.spacing = 6; sections.orientation = .vertical
        sections.widthAnchor.constraint(equalToConstant: 124).isActive = true
        sections.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(sections)
        let divider = NSBox(); divider.boxType = .separator; divider.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(divider)
        tabs.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(tabs)
        NSLayoutConstraint.activate([
            sections.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12), sections.topAnchor.constraint(equalTo: host.topAnchor, constant: 18),
            divider.leadingAnchor.constraint(equalTo: sections.trailingAnchor, constant: 12), divider.widthAnchor.constraint(equalToConstant: 1), divider.topAnchor.constraint(equalTo: host.topAnchor), divider.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            tabs.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 4), tabs.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8),
            tabs.topAnchor.constraint(equalTo: host.topAnchor, constant: 8), tabs.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -8)
        ])
        syncValues()
    }
    @objc func selectSection(_ sender: NSButton) { tabs.selectTabViewItem(withIdentifier: sender === generalButton ? "general" : "associations") }
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        let general = tabViewItem?.identifier as? String == "general"
        generalButton.state = general ? .on : .off; associationsButton.state = general ? .off : .on
    }
    private func caption(_ title: String, heading: Bool = false) -> NSTextField {
        let field = label(title, size: heading ? 11 : 12, color: heading ? .secondaryLabelColor : .labelColor)
        if heading { field.font = .systemFont(ofSize: 11, weight: .medium) }
        return field
    }
    private func grid(_ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows); grid.rowSpacing = 8; grid.columnSpacing = 16
        grid.column(at: 0).width = 142; grid.column(at: 1).width = 240
        grid.yPlacement = .center; grid.xPlacement = .leading
        return grid
    }
    private func popup(_ key: String, choices: [String], tags: [Int]? = nil) -> NSPopUpButton {
        let button = NSPopUpButton()
        button.controlSize = .small; button.font = .systemFont(ofSize: 12)
        button.addItems(withTitles: choices)
        for (index, item) in button.itemArray.enumerated() { item.tag = tags?[index] ?? index }
        button.identifier = NSUserInterfaceItemIdentifier(key); button.target = self; button.action = #selector(changed(_:))
        button.translatesAutoresizingMaskIntoConstraints = false; button.widthAnchor.constraint(equalToConstant: 184).isActive = true
        controls[key] = button
        return button
    }
    private func checkbox(_ key: String, title: String) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(changed(_:)))
        button.controlSize = .small; button.font = .systemFont(ofSize: 12)
        button.identifier = NSUserInterfaceItemIdentifier(key); controls[key] = button
        return button
    }
    func syncValues() {
        for (key, control) in controls {
            if let popup = control as? NSPopUpButton {
                let value: Int
                switch key {
                case "theme": value = ["system", "light", "dark"].firstIndex(of: UserDefaults.standard.string(forKey: key) ?? "system") ?? 0
                case "fontSize": value = Int(UserDefaults.standard.object(forKey: key) as? Double ?? 14)
                case "markdownDefaultView": value = min(2, max(0, UserDefaults.standard.integer(forKey: key)))
                default: let saved = UserDefaults.standard.integer(forKey: key); value = [2, 4, 8].contains(saved) ? saved : 4
                }
                popup.selectItem(withTag: value)
            } else if let button = control as? NSButton {
                let fallback = ["wrap", "lineNumbers", "closeBrackets"].contains(key)
                button.state = (UserDefaults.standard.object(forKey: key) as? Bool ?? fallback) ? .on : .off
            }
        }
    }
    @objc func changed(_ sender: NSControl) {
        guard let key = sender.identifier?.rawValue else { return }
        let value: Any
        if let popup = sender as? NSPopUpButton {
            let tag = popup.selectedTag()
            value = key == "theme" ? ["system", "light", "dark"][tag] as Any : key == "fontSize" ? Double(tag) as Any : tag as Any
        } else if let button = sender as? NSButton { value = button.state == .on }
        else { return }
        onChange?(key, value)
    }
}
