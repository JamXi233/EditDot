// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import AppKit

final class UpdateSettingsView: NSView {
    let controller: UpdateController
    let heading = NSTextField(labelWithString: "")
    let version = NSTextField(labelWithString: "")
    let channelLabel = NSTextField(labelWithString: "")
    let channel = NSPopUpButton()
    let automatic = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let downloads = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let check = NSButton()
    let status = NSTextField(wrappingLabelWithString: "")
    private var observer: NSObjectProtocol?
    init(controller: UpdateController = .shared) {
        self.controller = controller
        super.init(frame: .zero)
        heading.font = .systemFont(ofSize: 13, weight: .semibold); version.font = .systemFont(ofSize: 12)
        channelLabel.font = .systemFont(ofSize: 12); status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        for control in [automatic, downloads, check] { control.font = .systemFont(ofSize: 12); control.target = self }
        automatic.action = #selector(changeAutomatic); downloads.action = #selector(changeDownloads)
        channel.target = self; channel.action = #selector(changeChannel); channel.font = .systemFont(ofSize: 12)
        check.bezelStyle = .rounded; check.action = #selector(checkNow)
        let row = NSStackView(views: [channelLabel, channel]); row.spacing = 16
        channel.widthAnchor.constraint(equalToConstant: 230).isActive = true
        let separator = NSBox(); separator.boxType = .separator
        let stack = NSStackView(views: [heading, version, separator, row, automatic, downloads, check, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: topAnchor, constant: 23),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor), status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        observer = NotificationCenter.default.addObserver(forName: .editDotUpdateChanged, object: controller, queue: .main) { [weak self] _ in self?.syncValues() }
        refreshLocalization()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    deinit { if let observer = observer { NotificationCenter.default.removeObserver(observer) } }
    func refreshLocalization() {
        heading.stringValue = tr("updates.title"); channelLabel.stringValue = tr("updates.channel")
        check.toolTip = tr("updates.force_tooltip")
        automatic.title = tr("updates.auto_check"); downloads.title = tr("updates.auto_download")
        channel.removeAllItems(); channel.addItems(withTitles: UpdateChannel.allCases.map(\.title))
        syncValues()
    }
    func syncValues() {
        channel.selectItem(at: UpdateChannel.allCases.firstIndex(of: controller.selectedChannel) ?? 0)
        automatic.state = controller.automaticallyChecks ? .on : .off
        downloads.state = controller.automaticallyDownloads ? .on : .off; downloads.isEnabled = controller.automaticallyChecks
        version.stringValue = tr("updates.version", controller.currentVersion)
        check.title = controller.busy ? tr("updates.show_progress") : tr("updates.check")
        var lines: [String] = []
        if controller.busy || !controller.errorText.isEmpty { lines.append(controller.errorText.isEmpty ? controller.status.title : controller.errorText) }
        if let date = controller.defaults.object(forKey: "lastUpdateCheck") as? Date {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: Language.current.rawValue); formatter.dateStyle = .medium; formatter.timeStyle = .short
            let source = UpdateChannel(rawValue: controller.defaults.string(forKey: "lastUpdateChannel") ?? "")?.title ?? ""
            lines.append(tr("updates.last_check", formatter.string(from: date), source))
        }
        status.stringValue = lines.joined(separator: "\n")
    }
    @objc func changeChannel() {
        let index = channel.indexOfSelectedItem
        guard UpdateChannel.allCases.indices.contains(index) else { return }
        controller.defaults.set(UpdateChannel.allCases[index].rawValue, forKey: "updateChannel"); controller.settingsChanged()
    }
    @objc func changeAutomatic() {
        controller.defaults.set(automatic.state == .on, forKey: "automaticallyChecksUpdates"); controller.settingsChanged()
    }
    @objc func changeDownloads() {
        controller.defaults.set(downloads.state == .on, forKey: "automaticallyDownloadsUpdates"); controller.settingsChanged()
    }
    @objc func checkNow() { controller.checkForUpdates(nil) }
}
