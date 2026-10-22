// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import AppKit

indirect enum WorkspaceLayout: Codable {
    case group(UUID)
    case split(vertical: Bool, fraction: Double, first: WorkspaceLayout, second: WorkspaceLayout)
    var groupIDs: [UUID] {
        switch self {
        case .group(let id): return [id]
        case .split(_, _, let first, let second): return first.groupIDs + second.groupIDs
        }
    }
}
struct SavedEditorGroup: Codable {
    var id: UUID
    var session: EditorSession
    var twinEnabled: Bool?
}
struct SavedEditorWindow: Codable {
    var id: UUID
    var frame: NSRect
    var focusedGroup: UUID
    var groups: [SavedEditorGroup]
    var layout: WorkspaceLayout
}
struct WorkspaceSession: Codable {
    var windows: [SavedEditorWindow]
    var focusedWindow: UUID?
    var isValid: Bool {
        guard windows.count <= 32 else { return false }
        var groupIDs = Set<UUID>(), documentIDs = Set<UUID>(), windowIDs = Set<UUID>()
        for window in windows {
            guard windowIDs.insert(window.id).inserted, !window.groups.isEmpty, window.groups.count <= 64,
                  [window.frame.minX, window.frame.minY, window.frame.width, window.frame.height].allSatisfy(\.isFinite),
                  window.frame.width > 0, window.frame.height > 0,
                  Set(window.layout.groupIDs) == Set(window.groups.map(\.id)), window.layout.groupIDs.count == window.groups.count else { return false }
            for group in window.groups {
                guard groupIDs.insert(group.id).inserted, !group.session.documents.isEmpty else { return false }
                for doc in group.session.documents {
                    guard documentIDs.insert(doc.id).inserted, doc.content.utf8.count <= 32 * 1024 * 1024,
                          doc.selectionLocation >= 0, doc.selectionLength >= 0, doc.scrollY.isFinite, doc.url?.isFileURL != false else { return false }
                }
            }
        }
        return true
    }
}

extension SessionStore {
    var workspaceURL: URL { url.deletingLastPathComponent().appendingPathComponent("workspace.json") }
    func loadWorkspace() -> WorkspaceSession? {
        guard let data = try? Data(contentsOf: workspaceURL), let session = try? JSONDecoder().decode(WorkspaceSession.self, from: data), session.isValid else { return nil }
        return session
    }
    func saveWorkspace(_ session: WorkspaceSession, completion: ((Error?) -> Void)? = nil) {
        queue.async {
            do {
                try FileManager.default.createDirectory(at: self.workspaceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(session).write(to: self.workspaceURL, options: .atomic)
                DispatchQueue.main.async { completion?(nil) }
            } catch { DispatchQueue.main.async { completion?(error) } }
        }
    }
}
