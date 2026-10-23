// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let workspace = WorkspaceManager()
    var pendingFiles: [String] = []
    var launched = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        workspace.start()
        UpdateController.shared.start()
        launched = true
        NSApp.activate(ignoringOtherApps: true)
        if !pendingFiles.isEmpty { openFiles(pendingFiles); pendingFiles = [] }
    }
    private func openFiles(_ filenames: [String]) {
        if workspace.windows.isEmpty { workspace.newWindow() }
        for filename in filenames {
            let url = URL(fileURLWithPath: filename)
            if let owner = workspace.editor(for: url), let document = owner.documents.first(where: { $0.url?.standardizedFileURL == url.standardizedFileURL }) {
                owner.window?.makeKeyAndOrderFront(nil); owner.activateDocument(document.id)
            } else { workspace.activeEditor?.openURLs([url]) }
        }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if !launched { pendingFiles += filenames }
        else { openFiles(filenames) }
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard workspace.prepareToQuit() else { UpdateController.shared.cancelPendingInstall(); return .terminateCancel }
        guard UpdateController.shared.launchInstallerIfNeeded() else { return .terminateCancel }
        if UpdateController.shared.waitForPreparationToFinish({ NSApp.reply(toApplicationShouldTerminate: true) }) { return .terminateLater }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { UpdateController.shared.willTerminate() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if workspace.windows.isEmpty { workspace.newWindow() }
        else { (workspace.focusedWindow ?? workspace.windows.first)?.window.makeKeyAndOrderFront(nil) }
        return true
    }
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--apply-update" {
    exit(UpdateInstaller.runHelper(manifest: URL(fileURLWithPath: CommandLine.arguments[2])))
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
