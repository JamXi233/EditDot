// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import AppKit

struct AppInformation {
    static let copyright = "Copyright © 2017–2026 JamXi, JSG-LLC."
    let version: String
    let build: String
    init(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        version = info["CFBundleShortVersionString"] as? String ?? "—"
        build = info["CFBundleVersion"] as? String ?? "—"
    }
    var versionLabel: String { tr("about.version_build", version, build) }
    var copyText: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        return "EditDot \(version) (\(build))\nmacOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(architecture)\n\(Self.copyright)\nGPL-3.0-only"
    }
}

final class AboutController: NSWindowController, NSWindowDelegate {
    let information: AppInformation
    let titleLabel = label("EditDot", size: 22, color: .labelColor)
    let subtitle = label("", size: 12)
    let versionLabel = label("", size: 11)
    let copyrightLabel = label(AppInformation.copyright, size: 11)
    let licenseLabel = label("GPL-3.0-only", size: 11)
    let licenseButton = NSButton()
    let copyButton = NSButton()
    let doneButton = NSButton()
    let licenseScroll = NSScrollView()
    let licenseView = NSTextView()
    let icon = NSImageView()
    let stack = NSStackView()
    private(set) var licenseVisible = false
    private let hasLicense: Bool
    private var positioned = false

    init(information: AppInformation = AppInformation(), license: String? = Bundle.main.url(forResource: "LICENSE", withExtension: nil).flatMap { try? String(contentsOf: $0, encoding: .utf8) }) {
        self.information = information
        hasLicense = license?.isEmpty == false
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 220), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        super.init(window: panel)
        panel.delegate = self
        let content = NSView(); panel.contentView = content
        icon.image = NSApp.applicationIconImage; icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 64), icon.heightAnchor.constraint(equalToConstant: 64)])
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        let heading = NSStackView(views: [titleLabel, subtitle, versionLabel])
        heading.orientation = .vertical; heading.alignment = .leading; heading.spacing = 4
        let header = NSStackView(views: [icon, heading]); header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 16
        let separator = NSBox(); separator.boxType = .separator
        for field in [versionLabel, copyrightLabel, licenseLabel] { field.isSelectable = true }
        licenseScroll.borderType = .bezelBorder; licenseScroll.hasVerticalScroller = true; licenseScroll.autohidesScrollers = true
        licenseScroll.translatesAutoresizingMaskIntoConstraints = false
        licenseScroll.heightAnchor.constraint(equalToConstant: 190).isActive = true
        licenseScroll.isHidden = true
        licenseView.isEditable = false; licenseView.isRichText = false
        licenseView.font = .systemFont(ofSize: 11); licenseView.textColor = .labelColor
        licenseView.backgroundColor = .textBackgroundColor
        licenseView.textContainerInset = NSSize(width: 9, height: 9)
        licenseView.minSize = .zero; licenseView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        licenseView.isVerticallyResizable = true; licenseView.isHorizontallyResizable = false
        licenseView.autoresizingMask = [.width]
        licenseView.textContainer?.widthTracksTextView = true
        licenseView.textContainer?.containerSize = NSSize(width: 398, height: CGFloat.greatestFiniteMagnitude)
        let thirdParty = Bundle.main.url(forResource: "marked-LICENSE", withExtension: "md", subdirectory: "Vendor").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let notice = Bundle.main.url(forResource: "NOTICE", withExtension: nil).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        licenseView.string = (notice.isEmpty ? "" : notice + "\n\n") + (license ?? "") + (thirdParty.isEmpty ? "" : "\n\nMarked 12.0.2\n\n" + thirdParty)
        licenseLabel.stringValue = "GPL-3.0-only · Marked 12.0.2 (MIT)"
        licenseScroll.documentView = licenseView
        for button in [licenseButton, copyButton, doneButton] {
            button.bezelStyle = .rounded; button.controlSize = .regular; button.font = .systemFont(ofSize: 12)
            button.target = self
        }
        licenseButton.action = #selector(toggleLicense); licenseButton.isEnabled = hasLicense
        copyButton.action = #selector(copyInformation)
        doneButton.action = #selector(closeAbout); doneButton.keyEquivalent = "\r"
        doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [licenseButton, spacer, copyButton, doneButton]); actions.orientation = .horizontal; actions.spacing = 8
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.detachesHiddenViews = true
        for view in [header, separator, copyrightLabel, licenseLabel, licenseScroll, actions] { stack.addArrangedSubview(view) }
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
        for view in [header, separator, licenseScroll, actions] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        refreshLocalization()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func refreshLocalization() {
        window?.title = tr("common.about_editdot")
        subtitle.stringValue = tr("about.text_code_editor")
        versionLabel.stringValue = information.versionLabel
        licenseButton.title = licenseVisible ? tr("about.hide_license") : tr("about.license")
        licenseButton.toolTip = hasLicense ? nil : tr("about.license_text_is_unavailable")
        copyButton.title = tr("about.copy_version_info")
        doneButton.title = tr("about.close")
        icon.setAccessibilityLabel("EditDot")
        licenseView.setAccessibilityLabel(tr("about.full_gplv3_and_third_party_licenses"))
        for button in [licenseButton, copyButton, doneButton] { button.setAccessibilityLabel(button.title) }
        resizeToFit()
    }
    private func resizeToFit() {
        guard let panel = window else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        let top = panel.frame.maxY
        let height = max(220, stack.fittingSize.height + 40)
        panel.setContentSize(NSSize(width: 440, height: height))
        panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top))
        panel.contentView?.layoutSubtreeIfNeeded()
    }
    func present(relativeTo parent: NSWindow?) {
        guard let panel = window else { return }
        panel.appearance = parent?.appearance
        if !positioned {
            positioned = true
            if let parent = parent {
                panel.setFrameOrigin(NSPoint(x: parent.frame.midX - panel.frame.width / 2, y: parent.frame.midY - panel.frame.height / 2))
            } else { panel.center() }
        }
        panel.makeKeyAndOrderFront(nil)
    }
    @objc func toggleLicense() {
        guard hasLicense else { return }
        licenseVisible.toggle(); licenseScroll.isHidden = !licenseVisible
        refreshLocalization()
        if licenseVisible {
            licenseView.frame.size.width = licenseScroll.contentSize.width
            licenseView.layoutManager?.ensureLayout(for: licenseView.textContainer!)
            licenseView.sizeToFit(); licenseView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
    }
    @objc func copyInformation() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(information.copyText, forType: .string)
    }
    @objc func closeAbout() { window?.orderOut(nil) }
    override func cancelOperation(_ sender: Any?) { closeAbout() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { closeAbout(); return false }
}
