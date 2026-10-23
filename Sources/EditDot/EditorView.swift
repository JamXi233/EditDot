// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import AppKit

enum Palette {
    static let accent = NSColor(calibratedRed: 0.20, green: 0.49, blue: 0.36, alpha: 1)
    static let canvas = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(calibratedWhite: 0.105, alpha: 1) : NSColor(calibratedWhite: 1, alpha: 1)
    }
    static let chrome = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(calibratedWhite: 0.135, alpha: 1) : NSColor(calibratedWhite: 0.965, alpha: 1)
    }
    static let currentLine = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(calibratedWhite: 1, alpha: 0.028) : NSColor(calibratedWhite: 0, alpha: 0.018)
    }
}

func editorLineRect(_ rect: NSRect, in editor: NSTextView) -> NSRect {
    guard let manager = editor.layoutManager, let font = editor.font else { return rect }
    var line = rect
    // The final layout fragment omits paragraph line spacing.
    let spacing = max(0, editor.defaultParagraphStyle?.lineSpacing ?? 0)
    line.size.height = max(line.height, manager.defaultLineHeight(for: font) + spacing)
    return line
}

final class EditorClipView: NSClipView {
    var wraps = true
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var result = super.constrainBoundsRect(proposedBounds)
        if wraps { result.origin.x = -contentInsets.left }
        return result
    }
    override func viewFrameChanged(_ notification: Notification) {
        let origin = bounds.origin
        super.viewFrameChanged(notification)
        var restored = bounds
        restored.origin = origin
        scroll(to: constrainBoundsRect(restored).origin)
    }
    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(NSPoint(x: wraps ? -contentInsets.left : newOrigin.x, y: newOrigin.y))
    }
    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: NSPoint(x: wraps ? -contentInsets.left : newOrigin.x, y: newOrigin.y))
    }
}

final class EditorBrandMark: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Palette.accent.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.4; path.lineCapStyle = .round; path.lineJoinStyle = .round
        path.move(to: NSPoint(x: 5, y: 12)); path.line(to: NSPoint(x: 1.5, y: 8.5)); path.line(to: NSPoint(x: 5, y: 5))
        path.move(to: NSPoint(x: 7, y: 3.5)); path.line(to: NSPoint(x: 10, y: 13.5))
        path.move(to: NSPoint(x: 12, y: 12)); path.line(to: NSPoint(x: 15.5, y: 8.5)); path.line(to: NSPoint(x: 12, y: 5))
        path.stroke()
    }
}

final class EditorTextView: NSTextView {
    var history = UndoManager()
    override var undoManager: UndoManager? { history }
    @objc func undo(_ sender: Any?) { history.undo() }
    @objc func redo(_ sender: Any?) { history.redo() }
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undo(_:)) { return isEditable && history.canUndo }
        if menuItem.action == #selector(redo(_:)) { return isEditable && history.canRedo }
        return super.validateMenuItem(menuItem)
    }
    var newline: String = "\n"
    var changedSelection: (() -> Void)?
    var receivedFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { receivedFocus?() }
        return accepted
    }
    var pressedEscape: (() -> Void)?
    var performTool: ((TextTool) -> Void)?
    var indentWidth = 4
    var usesTabs = false
    var closesBrackets = true
    var literalInsertion = false
    var completionWords: [String] = []
    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        guard isEditable, NSMaxRange(charRange) <= (string as NSString).length else { return nil }
        let prefix = (string as NSString).substring(with: charRange)
        guard !prefix.isEmpty else { return nil }
        index.pointee = 0
        return Array(completionWords.filter { $0 != prefix && $0.hasPrefix(prefix) }.prefix(100))
    }
    override func insertTab(_ sender: Any?) {
        guard isEditable else { return }
        if selectedRange().length > 0 { performTool?(.indent) }
        else { insertText(usesTabs ? "\t" : String(repeating: " ", count: indentWidth), replacementRange: selectedRange()) }
    }
    override func insertBacktab(_ sender: Any?) { if isEditable { performTool?(.outdent) } }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard isEditable else { return }
        let text = (insertString as? String) ?? (insertString as? NSAttributedString)?.string ?? ""
        let range = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        let pairs = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`"]
        if closesBrackets, !literalInsertion, !hasMarkedText(), text.count == 1, let close = pairs[text], range.length > 0, NSMaxRange(range) <= (string as NSString).length {
            let selected = (string as NSString).substring(with: range)
            super.insertText(text + selected + close, replacementRange: range)
            setSelectedRange(NSRange(location: range.location + 1, length: range.length)); return
        }
        if closesBrackets, !literalInsertion, !hasMarkedText(), text.count == 1, range.length == 0 {
            let source = string as NSString
            let next = range.location < source.length ? source.substring(with: NSRange(location: range.location, length: 1)) : ""
            if pairs.values.contains(text), next == text {
                setSelectedRange(NSRange(location: range.location + 1, length: 0)); return
            }
            let previous = range.location > 0 ? source.substring(with: NSRange(location: range.location - 1, length: 1)) : ""
            if let close = pairs[text], (next.isEmpty || next.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || ")]},;".contains(next)), (text != "'" && text != "\"" || previous.isEmpty || previous.rangeOfCharacter(from: .alphanumerics) == nil) {
                super.insertText(text + close, replacementRange: range)
                setSelectedRange(NSRange(location: range.location + 1, length: 0)); return
            }
        }
        super.insertText(insertString, replacementRange: replacementRange)
    }
    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let range = selectedRange()
        let lineRange = text.lineRange(for: NSRange(location: min(range.location, text.length), length: 0))
        let before = text.substring(with: NSRange(location: lineRange.location, length: max(0, range.location - lineRange.location)))
        let indent = String(before.prefix(while: { $0 == " " || $0 == "\t" }))
        let extra = before.trimmingCharacters(in: .whitespaces).last.map { "{[:(".contains($0) } ?? false
        let unit = usesTabs ? "\t" : String(repeating: " ", count: indentWidth)
        let content = newline + indent + (extra ? unit : "")
        let next = NSMaxRange(range) < text.length ? text.substring(with: NSRange(location: NSMaxRange(range), length: 1)) : ""
        if extra, ")]}".contains(next), !next.isEmpty {
            insertText(content + newline + indent, replacementRange: range)
            setSelectedRange(NSRange(location: range.location + (content as NSString).length, length: 0))
        } else { insertText(content, replacementRange: range) }
    }
    override func deleteBackward(_ sender: Any?) {
        guard isEditable else { return }
        let source = string as NSString, range = selectedRange()
        if closesBrackets, range.length == 0, range.location > 0, range.location < source.length {
            let pair = source.substring(with: NSRange(location: range.location - 1, length: 2))
            if ["()", "[]", "{}", "\"\"", "''", "``"].contains(pair) { super.insertText("", replacementRange: NSRange(location: range.location - 1, length: 2)); return }
        }
        super.deleteBackward(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            NotificationCenter.default.post(name: .editorDroppedFiles, object: self, userInfo: ["urls": urls]); return true
        }
        return super.performDragOperation(sender)
    }
    override func cancelOperation(_ sender: Any?) { pressedEscape?() }
    override func setSelectedRange(_ charRange: NSRange) {
        super.setSelectedRange(charRange)
        needsDisplay = true
        changedSelection?()
    }
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard selectedRange().length == 0, let manager = layoutManager, let container = textContainer else { return }
        let source = string as NSString
        var line: NSRect
        if source.length == 0 { line = NSRect(x: 0, y: 0, width: bounds.width, height: font.map { manager.defaultLineHeight(for: $0) } ?? 20) }
        else if selectedRange().location >= source.length && [10, 13, 0x85, 0x2028, 0x2029].contains(source.character(at: source.length - 1)) { line = manager.extraLineFragmentRect }
        else {
            let glyph = manager.glyphIndexForCharacter(at: min(selectedRange().location, max(0, source.length - 1)))
            line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        _ = container
        line = editorLineRect(line, in: self)
        line.origin.y += textContainerOrigin.y
        line.origin.x = 0
        line.size.width = bounds.width
        if line.intersects(rect) { Palette.currentLine.setFill(); line.fill() }
    }
}

final class LineNumberView: NSRulerView {
    weak var editor: NSTextView?
    var index = TextIndex("") { didSet { updateWidth(); needsDisplay = true } }
    var bookmarks: [Int] = [] { didSet { needsDisplay = true } }
    var toggleBookmark: ((Int) -> Void)?
    override func mouseDown(with event: NSEvent) {
        guard let editor = editor, let manager = editor.layoutManager, let container = editor.textContainer else { return }
        let source = editor.string as NSString
        let point = editor.convert(event.locationInWindow, from: nil)
        let y = point.y - editor.textContainerOrigin.y
        guard y >= 0 else { return }
        let visible = editor.visibleRect.offsetBy(dx: -editor.textContainerOrigin.x, dy: -editor.textContainerOrigin.y)
        manager.ensureLayout(forBoundingRect: visible, in: container)
        if source.length == 0 || (index.starts.last == source.length && manager.extraLineFragmentTextContainer === container) {
            let rect = editorLineRect(manager.extraLineFragmentRect, in: editor)
            if y >= rect.minY && y < rect.maxY { toggleBookmark?(source.length); return }
            if source.length == 0 { return }
        }
        let glyph = manager.glyphIndex(for: NSPoint(x: 0, y: y), in: container)
        guard glyph < manager.numberOfGlyphs else { return }
        let rect = editorLineRect(manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil), in: editor)
        guard y >= rect.minY && y < rect.maxY else { return }
        let character = manager.characterIndexForGlyph(at: glyph)
        let location = index.starts[index.line(at: character)]
        toggleBookmark?(location)
    }
    init(editor: NSTextView, scrollView: NSScrollView) {
        self.editor = editor
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = editor
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        ruleThickness = 48
        wantsLayer = true
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    private func updateWidth() {
        let width = max(44, CGFloat(String(index.starts.count).count) * 8 + 24)
        if ruleThickness != width { ruleThickness = width }
    }
    override var isOpaque: Bool { true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let editor = editor, let manager = editor.layoutManager, let container = editor.textContainer else {
            Palette.canvas.setFill(); bounds.fill(using: .copy); return
        }
        let visible = editor.visibleRect.offsetBy(dx: -editor.textContainerOrigin.x, dy: -editor.textContainerOrigin.y)
        manager.ensureLayout(forBoundingRect: visible, in: container)
        let glyphRange = manager.glyphRange(forBoundingRect: visible, in: container)
        var lines: [(Int, NSRect)] = []
        manager.enumerateLineFragments(forGlyphRange: glyphRange) { line, _, _, range, _ in
            guard range.length > 0 else { return }
            let character = manager.characterIndexForGlyph(at: range.location)
            let number = self.index.line(at: character)
            if self.index.starts[number] == character { lines.append((number, line)) }
        }
        let length = (editor.string as NSString).length
        if length == 0 {
            lines.append((0, NSRect(x: 0, y: 0, width: 0, height: editor.font.map { manager.defaultLineHeight(for: $0) } ?? 20)))
        } else if index.starts.last == length, manager.extraLineFragmentTextContainer === container {
            lines.append((index.starts.count - 1, manager.extraLineFragmentRect))
        }
        let offset = convert(NSPoint.zero, from: editor).y + editor.textContainerOrigin.y
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor]
        Palette.canvas.setFill(); bounds.fill(using: .copy)
        for (number, line) in lines {
            let line = editorLineRect(line, in: editor)
            let label = String(number + 1) as NSString
            let size = label.size(withAttributes: attributes)
            let y = line.minY + offset + max(0, (line.height - size.height) / 2)
            if bookmarks.contains(index.starts[number]) {
                Palette.accent.setFill()
                NSBezierPath(ovalIn: NSRect(x: 4, y: y + (size.height - 5) / 2, width: 5, height: 5)).fill()
            }
            label.draw(at: NSPoint(x: ruleThickness - size.width - 12, y: y), withAttributes: attributes)
        }
    }
    override var isFlipped: Bool { true }
}

final class SyntaxHighlighter {
    struct Token { let range: NSRange; let kind: Int }
    private static let patterns: [(String, Int)] = [
        (#"\b(?:class|struct|enum|extension|func|function|let|var|const|import|from|export|default|return|if|else|for|while|switch|case|break|continue|try|catch|throw|throws|async|await|def|in|as|is|with|pass|raise|lambda|yield|public|private|static|final|override|guard|self|super|new|typeof|interface|type|extends|implements|package|void|int|float|double|char|bool|String|List|Array|None|True|False|true|false|null|nil)\b"#, 0),
        (#"\b(?:0[xX][0-9a-fA-F]+|\d+(?:\.\d+)?)\b"#, 1),
        (#"(?:\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`)"#, 2),
        (#"//[^\r\n]*|/\*[\s\S]*?\*/"#, 3)
    ]
    static func tokens(_ text: String, syntax: Syntax) -> [Token] {
        guard syntax != .plain, text.utf8.count <= 512 * 1024 else { return [] }
        var rules = patterns
        if [.python, .shell, .ruby, .yaml, .toml, .dockerfile, .makefile, .perl, .r, .powershell, .graphql].contains(syntax) { rules.removeLast(); rules.append((#"#[^\r\n]*"#, 3)) }
        if syntax == .ini { rules.removeLast(); rules.append((#"[;#][^\r\n]*"#, 3)) }
        if syntax == .sql || syntax == .lua { rules.removeLast(); rules.append((#"--[^\r\n]*|/\*[\s\S]*?\*/"#, 3)) }
        if syntax == .sql { rules.insert((#"(?i)\b(?:SELECT|FROM|WHERE|JOIN|LEFT|RIGHT|INNER|OUTER|ON|AS|INSERT|INTO|VALUES|UPDATE|SET|DELETE|CREATE|TABLE|ALTER|DROP|INDEX|PRIMARY|KEY|NOT|NULL|AND|OR|ORDER|BY|GROUP|HAVING|LIMIT|DISTINCT|UNION|ALL|ASC|DESC|BEGIN|COMMIT|ROLLBACK)\b"#, 0), at: 0) }
        if syntax == .yaml || syntax == .toml || syntax == .ini { rules.insert((#"(?m)^\s*[\w.\-]+(?=\s*[:=])|\[[^\]\r\n]+\]"#, 0), at: 0) }
        if syntax == .json { rules = Array(patterns.prefix(3)) }
        if [.html, .xml, .plist].contains(syntax) { rules = [(#"</?[a-zA-Z][^>]*>"#, 0), (patterns[2].0, 2), (#"<!--[\s\S]*?-->"#, 3)] }
        if syntax == .plist { rules.append((#"(?<=<key>)[^<]+(?=</key>)"#, 1)) }
        if syntax == .diff { rules = [(#"(?m)^\+[^\r\n]*"#, 2), (#"(?m)^-[^\r\n]*"#, 1), (#"(?m)^@@[^\r\n]*"#, 0)] }
        if syntax == .markdown { rules = [(#"(?m)^#{1,6}\s+[^\r\n]*"#, 0), (#"\*\*[^*]+\*\*|__[^_]+__"#, 0), (#"`[^`]+`|```[\s\S]*?```"#, 2), (#"\[[^\]]+\]\([^)]+\)"#, 1)] }
        var tokens: [Token] = []
        let range = NSRange(location: 0, length: (text as NSString).length)
        for (pattern, kind) in rules {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            expression.enumerateMatches(in: text, range: range) { match, _, stop in
                if tokens.count > 15000 { stop.pointee = true; return }
                if let match = match { tokens.append(Token(range: match.range, kind: kind)) }
            }
        }
        return tokens
    }
    static func apply(_ tokens: [Token], to editor: NSTextView) {
        guard let manager = editor.layoutManager else { return }
        let length = (editor.string as NSString).length
        manager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: length))
        let dark = editor.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let colors: [NSColor] = dark
            ? [NSColor(calibratedRed: 0.74, green: 0.63, blue: 0.90, alpha: 1), NSColor(calibratedRed: 0.86, green: 0.69, blue: 0.44, alpha: 1), NSColor(calibratedRed: 0.54, green: 0.75, blue: 0.61, alpha: 1), .secondaryLabelColor]
            : [NSColor(calibratedRed: 0.48, green: 0.31, blue: 0.66, alpha: 1), NSColor(calibratedRed: 0.62, green: 0.39, blue: 0.20, alpha: 1), NSColor(calibratedRed: 0.20, green: 0.48, blue: 0.35, alpha: 1), .secondaryLabelColor]
        for token in tokens where NSMaxRange(token.range) <= length { manager.addTemporaryAttribute(.foregroundColor, value: colors[token.kind], forCharacterRange: token.range) }
    }
}

final class AppearanceView: NSView {
    var appearanceChanged: (() -> Void)?
    var proposeTabDrop: ((UUID, NSPoint) -> (EditorDropZone, NSRect)?)?
    var receiveTabDrop: ((UUID, EditorDropZone) -> Bool)?
    private let preview = DropPreviewView()
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([TabItemView.dragType]) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    private func proposal(_ sender: NSDraggingInfo) -> (UUID, EditorDropZone, NSRect)? {
        guard let value = sender.draggingPasteboard.string(forType: TabItemView.dragType), let id = UUID(uuidString: value),
              let proposal = proposeTabDrop?(id, convert(sender.draggingLocation, from: nil)) else { return nil }
        return (id, proposal.0, proposal.1)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let (_, zone, rect) = proposal(sender) else { preview.removeFromSuperview(); return [] }
        preview.frame = zone.preview(in: rect); preview.title = zone.title; preview.needsDisplay = true
        if preview.superview == nil { addSubview(preview, positioned: .above, relativeTo: nil) }
        return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { preview.removeFromSuperview() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { preview.removeFromSuperview() }
        guard let (id, zone, _) = proposal(sender) else { return false }
        return receiveTabDrop?(id, zone) ?? false
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { preview.removeFromSuperview() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged?()
    }
}

class ChromeView: NSView {
    var fill: NSColor = Palette.chrome
    var drawsTopLine = false
    var drawsBottomLine = false
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        fill.setFill(); bounds.fill()
        NSColor.separatorColor.withAlphaComponent(0.45).setFill()
        if drawsTopLine { NSRect(x: 0, y: bounds.maxY - 0.5, width: bounds.width, height: 0.5).fill() }
        if drawsBottomLine { NSRect(x: 0, y: 0, width: bounds.width, height: 0.5).fill() }
    }
}

func symbolButton(_ name: String, tooltip: String, target: AnyObject?, action: Selector?) -> NSButton {
    let button = NSButton(image: NSImage(systemSymbolName: name, accessibilityDescription: tooltip) ?? NSImage(), target: target, action: action)
    button.bezelStyle = .texturedRounded
    button.isBordered = false
    button.imagePosition = .imageOnly
    button.contentTintColor = .secondaryLabelColor
    button.toolTip = tooltip
    button.setAccessibilityLabel(tooltip)
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 28), button.heightAnchor.constraint(equalToConstant: 26)])
    return button
}

func label(_ text: String, size: CGFloat = 11, color: NSColor = .secondaryLabelColor) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = NSFont.systemFont(ofSize: size)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    field.translatesAutoresizingMaskIntoConstraints = false
    return field
}

final class TabItemView: ChromeView, NSDraggingSource {
    static let dragType = NSPasteboard.PasteboardType("cn.jamsg.editdot.document-tab")
    let documentID: UUID
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onPin: ((UUID) -> Void)?
    var canMove: ((UUID) -> Bool)?
    var onMove: ((UUID, Bool) -> Void)?
    var onDetach: ((UUID, NSPoint) -> Void)?
    private var pressedPoint: NSPoint?
    private var dragging = false
    private var middlePressed = false
    private var dragCancelled = false
    private var dragKeyMonitor: Any?
    private var dropAfter: Bool? { didSet { needsDisplay = true } }
    var contextMenu: (() -> NSMenu)?
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
    init(document: EditorDocument, active: Bool) {
        documentID = document.id
        super.init(frame: .zero)
        registerForDraggedTypes([Self.dragType])
        fill = active ? Palette.canvas : Palette.chrome
        translatesAutoresizingMaskIntoConstraints = false
        let title = label(document.title, size: 12, color: active ? .labelColor : .secondaryLabelColor)
        let state = document.isDirty ? tr("common.unsaved_changes") : tr("editor.no_unsaved_changes")
        toolTip = (document.url?.path ?? document.title) + "\n" + tr("editor.drag_to_reorder_tabs_in_this_group")
        title.toolTip = (document.url?.path ?? document.title) + "\n" + state
        let symbol = document.syntax == .plain ? "doc.text" : "chevron.left.forwardslash.chevron.right"
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: state) ?? NSImage())
        icon.contentTintColor = document.isDirty ? .systemOrange : active ? Palette.accent : .secondaryLabelColor
        icon.toolTip = state
        icon.translatesAutoresizingMaskIntoConstraints = false
        let pinned = document.pinned == true
        let close = symbolButton(pinned ? "pin.fill" : "xmark", tooltip: pinned ? tr("common.unpin_document") : tr("editor.close_tab"), target: self, action: pinned ? #selector(unpinTab) : #selector(closeTab))
        close.controlSize = .mini
        addSubview(icon); addSubview(title); addSubview(close)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 35), widthAnchor.constraint(greaterThanOrEqualToConstant: 126), widthAnchor.constraint(lessThanOrEqualToConstant: 210),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), icon.centerYAnchor.constraint(equalTo: centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 13), icon.heightAnchor.constraint(equalToConstant: 13),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7), title.centerYAnchor.constraint(equalTo: centerYAnchor), title.widthAnchor.constraint(lessThanOrEqualToConstant: 135),
            close.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 10), close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3), close.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        if active {
            let accent = NSView(); accent.wantsLayer = true; accent.layer?.backgroundColor = Palette.accent.cgColor; accent.translatesAutoresizingMaskIntoConstraints = false
            addSubview(accent)
            NSLayoutConstraint.activate([accent.leadingAnchor.constraint(equalTo: leadingAnchor), accent.trailingAnchor.constraint(equalTo: trailingAnchor), accent.topAnchor.constraint(equalTo: topAnchor), accent.heightAnchor.constraint(equalToConstant: 2)])
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(document.title + (pinned ? tr("editor.pinned") : "") + (document.isDirty ? tr("editor.unsaved") : ""))
        setAccessibilityValue(active ? tr("editor.active_tab") : "")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func mouseDown(with event: NSEvent) {
        pressedPoint = convert(event.locationInWindow, from: nil)
        dragging = false
    }
    override func accessibilityPerformPress() -> Bool { onSelect?(documentID); return true }
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { middlePressed = true } else { super.otherMouseDown(with: event) }
    }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 {
            defer { middlePressed = false }
            if middlePressed, bounds.contains(convert(event.locationInWindow, from: nil)) { onClose?(documentID) }
        } else { super.otherMouseUp(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        defer { pressedPoint = nil }
        if !dragging, pressedPoint != nil, bounds.contains(convert(event.locationInWindow, from: nil)) { onSelect?(documentID) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let pressed = pressedPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - pressed.x, point.y - pressed.y) >= 5 else { return }
        let value = NSPasteboardItem(); value.setString(documentID.uuidString, forType: Self.dragType)
        let item = NSDraggingItem(pasteboardWriter: value)
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { return }
        cacheDisplay(in: bounds, to: bitmap)
        let image = NSImage(size: bounds.size); image.addRepresentation(bitmap)
        item.setDraggingFrame(bounds, contents: image)
        dragging = true
        dragCancelled = false
        dragKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.dragCancelled = true }
            return event
        }
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        finishDragging(at: screenPoint, operation: operation, mouseReleased: NSEvent.pressedMouseButtons & 1 == 0)
    }
    override func cancelOperation(_ sender: Any?) { dragCancelled = true }
    func finishDragging(at screenPoint: NSPoint, operation: NSDragOperation, mouseReleased: Bool) {
        if let monitor = dragKeyMonitor { NSEvent.removeMonitor(monitor); dragKeyMonitor = nil }
        if operation.isEmpty, !dragCancelled, mouseReleased { onDetach?(documentID, screenPoint) }
        pressedPoint = nil; dragging = false; dragCancelled = false
    }
    deinit { if let monitor = dragKeyMonitor { NSEvent.removeMonitor(monitor) } }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    private func draggedID(_ sender: NSDraggingInfo) -> UUID? {
        guard let value = sender.draggingPasteboard.string(forType: Self.dragType), let id = UUID(uuidString: value), canMove?(id) == true else { return nil }
        return id
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard draggedID(sender) != nil else { dropAfter = nil; return [] }
        if let scroll = enclosingScrollView {
            let clip = scroll.contentView, point = clip.convert(sender.draggingLocation, from: nil)
            var proposed = clip.bounds
            if point.x < clip.bounds.minX + 24 { proposed.origin.x -= 12 }
            else if point.x > clip.bounds.maxX - 24 { proposed.origin.x += 12 }
            clip.scroll(to: clip.constrainBoundsRect(proposed).origin); scroll.reflectScrolledClipView(clip)
        }
        dropAfter = convert(sender.draggingLocation, from: nil).x >= bounds.midX
        return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropAfter = nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropAfter = nil }
        guard let id = draggedID(sender) else { return false }
        onMove?(id, convert(sender.draggingLocation, from: nil).x >= bounds.midX)
        return true
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { dropAfter = nil }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let after = dropAfter {
            Palette.accent.setFill()
            NSRect(x: after ? bounds.maxX - 2 : 0, y: 3, width: 2, height: max(0, bounds.height - 6)).fill()
        }
    }
    @objc private func closeTab() { onClose?(documentID) }
    @objc private func unpinTab() { onPin?(documentID) }
}

extension Notification.Name { static let editorDroppedFiles = Notification.Name("EditDotDroppedFiles") }
