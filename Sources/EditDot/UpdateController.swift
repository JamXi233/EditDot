// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import AppKit

extension Notification.Name { static let editDotUpdateChanged = Notification.Name("EditDotUpdateChanged") }

enum UpdateStatus {
    case idle, checking, available, current, downloading, verifying, ready, failed, cancelled
    var title: String {
        switch self {
        case .idle: return tr("updates.idle")
        case .checking: return tr("updates.checking")
        case .available: return tr("updates.available")
        case .current: return tr("updates.current")
        case .downloading: return tr("updates.downloading")
        case .verifying: return tr("updates.verifying")
        case .ready: return tr("updates.ready")
        case .failed: return tr("updates.failed")
        case .cancelled: return tr("updates.cancelled")
        }
    }
}

final class UpdateController: NSObject {
    static let shared = UpdateController()
    let defaults: UserDefaults
    let network: UpdateNetwork
    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    var selectedChannel: UpdateChannel { UpdateChannel(rawValue: defaults.string(forKey: "updateChannel") ?? "") ?? .automatic }
    var automaticallyChecks: Bool { defaults.object(forKey: "automaticallyChecksUpdates") as? Bool ?? true }
    var automaticallyDownloads: Bool { defaults.bool(forKey: "automaticallyDownloadsUpdates") }
    private(set) var release: UpdateRelease?
    private(set) var prepared: PreparedUpdate?
    private(set) var forcedUpdate = false
    static func requestsForce(_ flags: NSEvent.ModifierFlags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags) -> Bool { flags.contains(.shift) }
    private(set) var status = UpdateStatus.idle
    private var lastError: UpdateError?
    var errorText: String { lastError?.localizedDescription ?? "" }
    private(set) var progress: Double?
    private(set) var busy = false
    private var interactive = false
    private var check: UpdateCheck?
    private var download: UpdateDownload?
    private var directory: URL?
    private var operation = UUID()
    private var timer: Timer?
    private var pendingInstallation = false
    private var preparationIsRunning = false
    private var terminationContinuation: (() -> Void)?
    private var loadedPanel: UpdatePanel?
    var panel: UpdatePanel {
        if let panel = loadedPanel { return panel }
        let panel = UpdatePanel(controller: self); loadedPanel = panel; return panel
    }
    init(defaults: UserDefaults = .standard, network: UpdateNetwork = UpdateNetwork()) { self.defaults = defaults; self.network = network; super.init() }
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self else { return }
            if self.defaults.bool(forKey: "updateInstallFailed") {
                self.defaults.removeObject(forKey: "updateInstallFailed"); self.fail(UpdateError.helper, present: true)
            } else { self.checkAutomaticallyIfDue() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkAutomaticallyIfDue() }
    }
    func checkAutomaticallyIfDue(now: Date = Date()) {
        guard automaticallyChecks, !busy, prepared == nil else { return }
        let last = defaults.object(forKey: "lastUpdateAttempt") as? Date ?? .distantPast
        guard now.timeIntervalSince(last) >= 86400 || now < last else { return }
        beginCheck(manual: false)
    }
    @objc func checkForUpdates(_ sender: Any?) {
        if busy || prepared != nil { present(); return }
        beginCheck(manual: true, force: Self.requestsForce())
    }
    func beginCheck(manual: Bool, force: Bool = false) {
        guard !busy else { return }
        interactive = manual; forcedUpdate = manual && force; release = nil; lastError = nil; status = .checking; busy = true; progress = nil
        defaults.set(Date(), forKey: "lastUpdateAttempt")
        changed(); if manual { present() }
        let token = UUID(); operation = token
        let mode: UpdateMode = forcedUpdate ? .forced : .normal
        check = UpdateCheck(channel: selectedChannel, currentVersion: currentVersion, mode: mode, fetch: { [network] channel, completion in network.fetch(channel, mode: mode, completion: completion) }) { [weak self] result in
            guard let self = self, self.operation == token else { return }
            self.check = nil; self.busy = false
            switch result {
            case .success(let release):
                self.release = release; self.defaults.set(Date(), forKey: "lastUpdateCheck")
                self.defaults.set(release.channel.rawValue, forKey: "lastUpdateChannel")
                if release.isNewer(than: self.currentVersion) || self.forcedUpdate {
                    self.status = .available
                    if (self.forcedUpdate || (!manual && self.automaticallyDownloads)), release.downloadURL != nil { self.beginDownload(); return }
                    self.changed(); self.present()
                } else { self.status = .current; self.changed() }
            case .failure(let error): self.fail(error, present: manual)
            }
        }
    }
    func waitForPreparationToFinish(_ completion: @escaping () -> Void) -> Bool {
        guard preparationIsRunning else { return false }
        terminationContinuation = completion; cancel()
        return true
    }
    func willTerminate() {
        timer?.invalidate(); check?.cancel(); download?.cancel()
        if !pendingInstallation, let directory = directory { try? FileManager.default.removeItem(at: directory) }
    }
    func settingsChanged() {
        if check != nil { cancel() }
        changed()
    }
    func present() {
        panel.refreshLocalization(); panel.showWindow(nil); panel.window?.center(); panel.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func refreshLocalization() {
        loadedPanel?.refreshLocalization()
        NotificationCenter.default.post(name: .editDotUpdateChanged, object: self)
    }
    func changed() {
        loadedPanel?.refreshLocalization()
        NotificationCenter.default.post(name: .editDotUpdateChanged, object: self)
    }
    func fail(_ error: Error, present: Bool) {
        busy = false; status = .failed; lastError = error as? UpdateError ?? .operationFailed; changed()
        if present { self.present() }
    }
    func beginDownload(force: Bool = false) {
        guard !busy, let release = release, release.isNewer(than: currentVersion) || force || forcedUpdate else { return }
        forcedUpdate = force || forcedUpdate
        let mode: UpdateMode = forcedUpdate ? .forced : .normal
        guard let url = release.downloadURL else { fail(UpdateError.noDownload, present: true); return }
        do { try UpdateInstaller.validateTarget(Bundle.main.bundleURL, version: release.version, mode: mode) }
        catch { fail(error, present: true); return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EditDot-update-" + UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { fail(error, present: true); return }
        directory = folder; busy = true; status = .downloading; lastError = nil; progress = nil
        let token = UUID(); operation = token; changed()
        download = UpdateDownload(url: url, destination: folder.appendingPathComponent("Update.dmg"), progress: { [weak self] value in
            guard let self = self, self.operation == token else { return }; self.progress = value; self.changed()
        }) { [weak self] result in
            guard let self = self, self.operation == token else { return }
            self.download = nil
            switch result {
            case .success(let archive):
                self.status = .verifying; self.progress = nil; self.changed()
                self.preparationIsRunning = true
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Result { try UpdateInstaller.prepare(archive: archive, directory: folder, release: release, mode: mode) }
                    DispatchQueue.main.async {
                        self.preparationIsRunning = false
                        guard self.operation == token else {
                            try? FileManager.default.removeItem(at: folder)
                            if self.directory == folder { self.directory = nil }
                            self.busy = false
                            if let completion = self.terminationContinuation { self.terminationContinuation = nil; completion() }
                            else { self.changed() }
                            return
                        }
                        self.busy = false
                        switch result {
                        case .success(let prepared): self.prepared = prepared; self.status = .ready; self.changed(); self.present()
                        case .failure(let error): try? FileManager.default.removeItem(at: folder); self.directory = nil; self.fail(error, present: true)
                        }
                    }
                }
            case .failure(let error):
                try? FileManager.default.removeItem(at: folder); self.directory = nil; self.fail(error, present: self.interactive)
            }
        }
    }
    func cancel() {
        let wasPreparing = preparationIsRunning
        operation = UUID(); check?.cancel(); check = nil; download?.cancel(); download = nil
        busy = wasPreparing; forcedUpdate = false; progress = nil; status = .cancelled; lastError = nil
        if !wasPreparing, let directory = directory { try? FileManager.default.removeItem(at: directory); self.directory = nil }
        changed()
    }
    func installAndRestart(force: Bool = false) {
        guard prepared != nil, !busy else { return }
        if force { prepared?.mode = .forced; forcedUpdate = true }
        pendingInstallation = true; NSApp.terminate(nil)
    }
    func cancelPendingInstall() { pendingInstallation = false }
    func launchInstallerIfNeeded() -> Bool {
        guard pendingInstallation, let prepared = prepared else { return true }
        do { try UpdateInstaller.launch(prepared); return true }
        catch { pendingInstallation = false; fail(error, present: true); return false }
    }
    func openReleasePage() {
        guard let url = release?.pageURL else { return }; NSWorkspace.shared.open(url)
    }
}

struct UpdatePresentation {
    var currentVersion: String
    var status = UpdateStatus.idle
    var release: UpdateRelease?
    var preparedVersion: String?
    var errorText = ""
    var forced = false
    var progress: Double?
    var busy = false
}

final class UpdatePanel: NSWindowController {
    weak var controller: UpdateController?
    let heading = NSTextField(labelWithString: "")
    let status = NSTextField(wrappingLabelWithString: "")
    let source = NSTextField(labelWithString: "")
    let forceNote = NSTextField(wrappingLabelWithString: "")
    let notes = NSTextView()
    let progress = NSProgressIndicator()
    let primary = NSButton()
    let secondary = NSButton()
    let page = NSButton()
    let icon = NSImageView()
    let badge = NSTextField(labelWithString: "")
    let badgeBox = NSBox()
    let statusIcon = NSImageView()
    let statusBox = NSBox()
    let progressLabel = NSTextField(labelWithString: "")
    let progressRow = NSStackView()
    let notesSection = NSStackView()
    let notesHeading = NSTextField(labelWithString: "")
    private var statusHeight: NSLayoutConstraint!
    private var forceHeight: NSLayoutConstraint!
    private var notesHeight: NSLayoutConstraint!
    private var forceHost: NSView!
    private var progressHost: NSView!
    private var notesHost: NSView!
    private let textInset: CGFloat = 54
    private let contentWidth: CGFloat = 460

    init(controller: UpdateController) {
        self.controller = controller
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 260), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        heading.setContentCompressionResistancePriority(.required, for: .horizontal)
        status.font = .systemFont(ofSize: 12); source.font = .systemFont(ofSize: 11); source.textColor = .secondaryLabelColor
        status.preferredMaxLayoutWidth = contentWidth - textInset
        forceNote.font = .systemFont(ofSize: 11); forceNote.textColor = .systemOrange; forceNote.preferredMaxLayoutWidth = contentWidth - textInset
        badge.font = .systemFont(ofSize: 11, weight: .medium)
        badgeBox.boxType = .custom; badgeBox.titlePosition = .noTitle; badgeBox.borderWidth = 0; badgeBox.borderColor = .clear; badgeBox.cornerRadius = 0; badgeBox.contentViewMargins = .zero
        let badgeContent = NSView(); badgeBox.contentView = badgeContent
        badge.translatesAutoresizingMaskIntoConstraints = false; badgeContent.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: badgeContent.leadingAnchor, constant: 0), badge.trailingAnchor.constraint(equalTo: badgeContent.trailingAnchor, constant: 0),
            badge.centerYAnchor.constraint(equalTo: badgeContent.centerYAnchor), badgeBox.heightAnchor.constraint(equalToConstant: 16)
        ])
        let details = NSStackView(views: [badgeBox, heading, source]); details.orientation = .vertical; details.alignment = .leading; details.spacing = 4
        icon.image = NSImage(named: NSImage.applicationIconName); icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 40).isActive = true; icon.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let header = NSStackView(views: [icon, details]); header.spacing = 14; header.alignment = .centerY
        header.heightAnchor.constraint(equalToConstant: 64).isActive = true

        statusBox.boxType = .custom; statusBox.titlePosition = .noTitle; statusBox.borderWidth = 0; statusBox.borderColor = .clear; statusBox.cornerRadius = 9; statusBox.contentViewMargins = .zero
        statusBox.fillColor = .clear
        let statusContent = NSView(); statusBox.contentView = statusContent
        statusIcon.imageScaling = .scaleProportionallyUpOrDown
        let statusRow = NSStackView(views: [statusIcon, status]); statusRow.spacing = 14; statusRow.alignment = .top
        statusRow.translatesAutoresizingMaskIntoConstraints = false; statusContent.addSubview(statusRow)
        statusHeight = statusBox.heightAnchor.constraint(equalToConstant: 48)
        NSLayoutConstraint.activate([
            statusRow.leadingAnchor.constraint(equalTo: statusContent.leadingAnchor, constant: 0), statusRow.trailingAnchor.constraint(equalTo: statusContent.trailingAnchor, constant: 0),
            statusRow.centerYAnchor.constraint(equalTo: statusContent.centerYAnchor), statusIcon.widthAnchor.constraint(equalToConstant: 40), statusIcon.heightAnchor.constraint(equalToConstant: 20), statusHeight
        ])
        forceHeight = forceNote.heightAnchor.constraint(equalToConstant: 28); forceHeight.isActive = true
        progress.style = .bar; progress.minValue = 0; progress.maxValue = 1
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold); progressLabel.textColor = .secondaryLabelColor; progressLabel.alignment = .right
        progressLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true
        progressRow.addArrangedSubview(progress); progressRow.addArrangedSubview(progressLabel); progressRow.spacing = 10; progressRow.alignment = .centerY
        progressRow.heightAnchor.constraint(equalToConstant: 20).isActive = true
        notes.isEditable = false; notes.isSelectable = true; notes.font = .systemFont(ofSize: 12); notes.drawsBackground = false; notes.textContainerInset = .zero; notes.textContainer?.lineFragmentPadding = 0
        notes.isVerticallyResizable = true; notes.autoresizingMask = [.width]; notes.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(); scroll.documentView = notes; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.drawsBackground = false
        notesHeading.font = .systemFont(ofSize: 11, weight: .medium); notesHeading.textColor = .secondaryLabelColor
        notesSection.addArrangedSubview(notesHeading); notesSection.addArrangedSubview(scroll); notesSection.orientation = .vertical; notesSection.alignment = .leading; notesSection.spacing = 8
        notesHeight = notesSection.heightAnchor.constraint(equalToConstant: 100)
        NSLayoutConstraint.activate([scroll.widthAnchor.constraint(equalTo: notesSection.widthAnchor), notesHeight])
        for button in [primary, secondary, page] { button.bezelStyle = .rounded; button.target = self; button.font = .systemFont(ofSize: 12) }
        for button in [primary, secondary] {
            button.controlSize = .large; button.font = .systemFont(ofSize: 12, weight: .medium)
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        }
        primary.bezelColor = Palette.accent; primary.contentTintColor = .white
        primary.keyEquivalent = "\r"; primary.widthAnchor.constraint(greaterThanOrEqualToConstant: 132).isActive = true
        secondary.keyEquivalent = "\u{1b}"
        page.bezelStyle = .inline; page.isBordered = false; page.contentTintColor = .linkColor; page.font = .systemFont(ofSize: 11)
        primary.action = #selector(performPrimary); secondary.action = #selector(performSecondary); page.action = #selector(openPage)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [page, spacer, secondary, primary]); buttons.spacing = 10; buttons.alignment = .centerY
        secondary.widthAnchor.constraint(equalTo: primary.widthAnchor).isActive = true
        buttons.heightAnchor.constraint(equalToConstant: 34).isActive = true
        func textColumn(_ view: NSView) -> NSView {
            let host = NSView(); host.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: textInset), view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                view.topAnchor.constraint(equalTo: host.topAnchor), view.bottomAnchor.constraint(equalTo: host.bottomAnchor)
            ])
            return host
        }
        forceHost = textColumn(forceNote); progressHost = textColumn(progressRow); notesHost = textColumn(notesSection)
        let stack = NSStackView(views: [header, statusBox, forceHost!, progressHost!, notesHost!, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.detachesHiddenViews = true
        let host = NSView(); window.contentView = host; host.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: host.topAnchor, constant: 20), stack.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -18)
        ] + [header, statusBox, forceHost!, progressHost!, notesHost!, buttons].map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
        refreshLocalization()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func refreshLocalization() {
        guard let controller = controller else { return }
        render(UpdatePresentation(currentVersion: controller.currentVersion, status: controller.status, release: controller.release, preparedVersion: controller.prepared?.version,
                                  errorText: controller.errorText, forced: controller.forcedUpdate, progress: controller.progress, busy: controller.busy))
    }
    private func textHeight(_ string: String, width: CGFloat, size: CGFloat, lineSpacing: CGFloat = 0) -> CGFloat {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = lineSpacing
        return ceil(NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size), .paragraphStyle: paragraph]).boundingRect(with: NSSize(width: width, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }
    func render(_ state: UpdatePresentation) {
        window?.title = tr("updates.title")
        let available = state.release != nil && (state.release!.isNewer(than: state.currentVersion) || state.forced)
        if state.forced, let release = state.release { heading.stringValue = tr("updates.force_version", state.preparedVersion ?? release.version) }
        else { heading.stringValue = available ? tr("updates.new_version", state.release!.version) : tr("updates.title") }
        let missingDownload = available && state.release?.downloadURL == nil
        status.stringValue = !state.errorText.isEmpty ? state.errorText : missingDownload ? UpdateError.noDownload.localizedDescription : state.status == .available ? tr("updates.download_hint") : state.status.title
        source.stringValue = state.release.map { tr("updates.source_version", $0.channel.title, state.currentVersion) } ?? tr("updates.version", state.currentVersion)
        let color: NSColor
        let symbol: String
        if state.status == .failed || missingDownload { color = .systemOrange; symbol = "exclamationmark.circle.fill"; badge.stringValue = tr("updates.badge_attention") }
        else if state.forced { color = .systemOrange; symbol = "arrow.triangle.2.circlepath"; badge.stringValue = tr("updates.badge_forced") }
        else {
            color = window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(calibratedRed: 0.42, green: 0.77, blue: 0.62, alpha: 1) : Palette.accent
            switch state.status {
            case .checking: symbol = "arrow.triangle.2.circlepath"; badge.stringValue = tr("updates.badge_checking")
            case .downloading: symbol = "arrow.down.circle.fill"; badge.stringValue = tr("updates.badge_downloading")
            case .verifying: symbol = "checkmark.shield.fill"; badge.stringValue = tr("updates.badge_verifying")
            case .ready: symbol = "checkmark.circle.fill"; badge.stringValue = tr("updates.badge_ready")
            case .current: symbol = "checkmark.circle.fill"; badge.stringValue = tr("updates.badge_current")
            case .available: symbol = "arrow.down.circle.fill"; badge.stringValue = tr("updates.badge_available")
            case .cancelled: symbol = "pause.circle"; badge.stringValue = tr("updates.badge_cancelled")
            case .idle, .failed: symbol = "arrow.down.circle"; badge.stringValue = tr("updates.title")
            }
        }
        badge.textColor = state.forced || state.status == .failed || missingDownload ? .systemOrange : .secondaryLabelColor
        badgeBox.fillColor = .clear
        statusIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); statusIcon.contentTintColor = color
        statusHeight.constant = max(28, textHeight(status.stringValue, width: contentWidth - textInset, size: 12) + 8)
        forceNote.stringValue = tr("updates.force_note"); forceNote.isHidden = !state.forced; forceHost.isHidden = !state.forced
        forceHeight.constant = max(14, textHeight(forceNote.stringValue, width: contentWidth - textInset, size: 11))
        primary.toolTip = tr("updates.force_tooltip")
        let content = state.release?.notes.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if notes.string != content {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 3
            notes.textStorage?.setAttributedString(NSAttributedString(string: content, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]))
            notes.scroll(NSPoint.zero)
        }
        notesHeading.stringValue = tr("updates.changes"); notesSection.isHidden = content.isEmpty; notesHost.isHidden = content.isEmpty
        notesHeight.constant = min(160, max(52, textHeight(content, width: contentWidth - textInset, size: 12, lineSpacing: 3) + 28))
        progressRow.isHidden = !state.busy; progressHost.isHidden = !state.busy; progress.isIndeterminate = state.progress == nil
        if let value = state.progress { progress.stopAnimation(nil); progress.doubleValue = min(1, max(0, value)); progressLabel.stringValue = "\(Int(min(1, max(0, value)) * 100))%" }
        else { progressLabel.stringValue = ""; if state.busy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) } }
        primary.title = state.preparedVersion != nil ? (state.forced ? tr("updates.force_install_restart") : tr("updates.install_restart")) : available && state.release?.downloadURL != nil ? (state.forced ? tr("updates.force_download") : tr("updates.download")) : tr("updates.check")
        primary.isEnabled = !state.busy
        secondary.title = state.busy ? tr("updates.cancel") : tr("updates.later")
        page.title = tr("updates.release_page"); page.isHidden = state.release?.pageURL == nil
        var heights: [CGFloat] = [64, statusHeight.constant, 34]
        if state.forced { heights.append(forceHeight.constant) }
        if state.busy { heights.append(20) }
        if !content.isEmpty { heights.append(notesHeight.constant) }
        let height = heights.reduce(38, +) + CGFloat(heights.count - 1) * 12
        if let window = window, abs((window.contentView?.frame.height ?? 0) - height) > 0.5 {
            let top = window.frame.maxY
            window.setContentSize(NSSize(width: contentWidth + 40, height: height))
            window.setFrameOrigin(NSPoint(x: window.frame.minX, y: top - window.frame.height))
        }
        window?.contentView?.layoutSubtreeIfNeeded()
    }
    @objc func performPrimary() {
        guard let controller = controller else { return }
        let force = UpdateController.requestsForce()
        if controller.prepared != nil { controller.installAndRestart(force: force) }
        else if let release = controller.release, release.downloadURL != nil, release.isNewer(than: controller.currentVersion) || force || controller.forcedUpdate { controller.beginDownload(force: force) }
        else { controller.beginCheck(manual: true, force: force) }
    }
    @objc func performSecondary() { if controller?.busy == true { controller?.cancel() } else { close() } }
    @objc func openPage() { controller?.openReleasePage() }
}
