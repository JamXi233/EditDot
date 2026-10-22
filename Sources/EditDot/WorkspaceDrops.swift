// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import AppKit

enum EditorDropZone: Int, CaseIterable {
    case center, left, right, top, bottom
    var title: String {
        switch self {
        case .center: return tr("workspace.move_to_this_group")
        case .left: return tr("workspace.split_to_the_left")
        case .right: return tr("workspace.split_to_the_right")
        case .top: return tr("workspace.split_above")
        case .bottom: return tr("workspace.split_below")
        }
    }
    var vertical: Bool { self == .left || self == .right }
    static func at(_ point: NSPoint, in rect: NSRect) -> EditorDropZone? {
        guard rect.contains(point), rect.width > 0, rect.height > 0 else { return nil }
        let x = (point.x - rect.minX) / rect.width, y = (point.y - rect.minY) / rect.height
        let distances: [(CGFloat, EditorDropZone)] = [(x, .left), (1 - x, .right), (y, .bottom), (1 - y, .top)]
        if let closest = distances.min(by: { $0.0 < $1.0 }), closest.0 < 0.24 { return closest.1 }
        return .center
    }
    func preview(in rect: NSRect) -> NSRect {
        switch self {
        case .center: return rect.insetBy(dx: 4, dy: 4)
        case .left: return NSRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .right: return NSRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .top: return NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        case .bottom: return NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
        }
    }
}

final class DropPreviewView: NSView {
    var title = ""
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        Palette.accent.withAlphaComponent(0.15).setFill(); bounds.fill()
        Palette.accent.withAlphaComponent(0.65).setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1)).stroke()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor]
        let text = title as NSString, size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}

final class TabBarDropView: ChromeView {
    var acceptsTab: ((UUID) -> Bool)?
    var receivesTab: ((UUID) -> Bool)?
    var newDocument: (() -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([TabItemView.dragType]) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func mouseDown(with event: NSEvent) { if event.clickCount == 2 { newDocument?() } }
    private func id(_ sender: NSDraggingInfo) -> UUID? {
        guard let value = sender.draggingPasteboard.string(forType: TabItemView.dragType), let id = UUID(uuidString: value), acceptsTab?(id) == true else { return nil }; return id
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { id(sender) == nil ? [] : .move }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { guard let id = id(sender) else { return false }; return receivesTab?(id) ?? false }
}
