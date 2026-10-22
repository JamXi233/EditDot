// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import AppKit
import WebKit
import JavaScriptCore
import UniformTypeIdentifiers

enum MarkdownRenderError: LocalizedError {
    case unavailable, tooLarge
    var errorDescription: String? {
        self == .tooLarge ? tr("markdown.preview_supports_markdown_up_to_2_mb_source_editing_remains_available") : tr("markdown.the_markdown_preview_component_is_unavailable")
    }
}

final class MarkdownRenderer {
    static let shared = MarkdownRenderer()
    let queue = DispatchQueue(label: "com.jamxi.editdot.markdown", qos: .userInitiated)
    private let scriptURL: URL?
    private var context: JSContext?
    private var directory: URL?
    private var imageBytes = 0
    init(scriptURL: URL? = Bundle.main.url(forResource: "marked", withExtension: "js", subdirectory: "Vendor") ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Vendor/marked.js")) { self.scriptURL = scriptURL }
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }
    static func link(_ value: String, directory: URL?) -> String {
        if value.hasPrefix("#") { return value }
        guard let url = URL(string: value, relativeTo: directory)?.absoluteURL,
              ["https", "http", "mailto", "file"].contains(url.scheme?.lowercased() ?? "") else { return "" }
        return url.absoluteString
    }
    private func image(_ value: String) -> String {
        if let url = URL(string: value), url.scheme?.lowercased() == "https" { return url.absoluteString }
        guard let directory = directory?.standardizedFileURL.resolvingSymlinksInPath(),
              let url = URL(string: value, relativeTo: directory)?.absoluteURL, url.isFileURL else { return "" }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(directory.path + "/"), let type = UTType(filenameExtension: resolved.pathExtension), type.conforms(to: .image),
              let size = try? resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 10 * 1024 * 1024, imageBytes + size <= 20 * 1024 * 1024,
              let bytes = try? Data(contentsOf: resolved) else { return "" }
        imageBytes += bytes.count
        return "data:\(type.preferredMIMEType ?? "application/octet-stream");base64," + bytes.base64EncodedString()
    }
    func body(_ text: String, directory: URL? = nil) throws -> String {
        try queue.sync { try parse(text, directory: directory) }
    }
    func render(_ text: String, directory: URL?, completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            let result = Result { try self.parse(text, directory: directory) }
            DispatchQueue.main.async { completion(result) }
        }
    }
    private func parse(_ text: String, directory: URL?) throws -> String {
        guard text.utf8.count <= 2 * 1024 * 1024 else { throw MarkdownRenderError.tooLarge }
        self.directory = directory; imageBytes = 0
        if context == nil {
            guard let scriptURL = scriptURL, let script = try? String(contentsOf: scriptURL), let engine = JSContext() else { throw MarkdownRenderError.unavailable }
            engine.evaluateScript(script)
            let image: @convention(block) (String) -> String = { [weak self] in self?.image($0) ?? "" }
            let link: @convention(block) (String) -> String = { [weak self] in Self.link($0, directory: self?.directory) }
            engine.setObject(image, forKeyedSubscript: "resolveImage" as NSString)
            engine.setObject(link, forKeyedSubscript: "resolveLink" as NSString)
            engine.evaluateScript(#"""
            function escapeHTML(s) { return String(s || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;'); }
            function renderMarkdown(source) {
              var renderer = new marked.Renderer(), headings = {};
              renderer.html = function(html) { return escapeHTML(html); };
              renderer.listitem = function(text, task) { return '<li' + (task ? ' class="task-item"' : '') + '>' + text + '</li>\n'; };
              renderer.link = function(href, title, text) {
                var url = resolveLink(href || '');
                return url ? '<a href="' + escapeHTML(url) + '"' + (title ? ' title="' + escapeHTML(title) + '"' : '') + '>' + text + '</a>' : text;
              };
              renderer.image = function(href, title, text) {
                var url = resolveImage(href || '');
                return url ? '<img src="' + escapeHTML(url) + '" alt="' + escapeHTML(text) + '"' + (title ? ' title="' + escapeHTML(title) + '"' : '') + '>' : escapeHTML(text);
              };
              renderer.heading = function(text, level, raw) {
                var slug = String(raw || text).toLowerCase().replace(/<[^>]*>/g,'').replace(/[^\w\u0080-\uffff -]/g,'').trim().replace(/\s+/g,'-');
                var count = headings[slug] || 0; headings[slug] = count + 1;
                return '<h' + level + ' id="' + escapeHTML(slug + (count ? '-' + count : '')) + '">' + text + '</h' + level + '>\n';
              };
              return marked.parse(source, { renderer: renderer, gfm: true, breaks: false });
            }
            """#)
            guard engine.exception == nil else { throw MarkdownRenderError.unavailable }
            context = engine
        }
        guard let context = context else { throw MarkdownRenderError.unavailable }
        context.exception = nil
        context.setObject(text, forKeyedSubscript: "markdownSource" as NSString)
        guard let html = context.evaluateScript("renderMarkdown(markdownSource)")?.toString(), context.exception == nil else { throw MarkdownRenderError.unavailable }
        context.setObject("", forKeyedSubscript: "markdownSource" as NSString)
        return html
    }
    static func page(_ body: String, dark: Bool) -> String {
        """
        <!doctype html><html lang="\(Language.current.rawValue)"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: https:; style-src 'unsafe-inline'; script-src 'none'; base-uri 'none'; form-action 'none'; object-src 'none'"><style>
        :root{color-scheme:\(dark ? "dark" : "light");--bg:\(dark ? "#202122" : "#fff");--fg:\(dark ? "#e5e5e5" : "#282b2d");--sub:\(dark ? "#afb3b5" : "#62686b");--line:\(dark ? "#414548" : "#e1e5e7");--code:\(dark ? "#2b2e30" : "#f5f7f8");--accent:\(dark ? "#75c6a4" : "#318464")}
        *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.65 -apple-system,BlinkMacSystemFont,sans-serif;overflow-wrap:anywhere}main{max-width:820px;padding:20px 24px 56px;margin:auto}h1,h2,h3,h4,h5,h6{line-height:1.3;margin:1.4em 0 .65em;font-weight:600}h1{font-size:27px}h2{font-size:22px;border-bottom:1px solid var(--line);padding-bottom:.3em}h3{font-size:18px}h4,h5,h6{font-size:15px}main>:first-child{margin-top:0}p,ul,ol,blockquote,table,pre{margin:.8em 0}a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}code,pre{font:12px/1.6 ui-monospace,Menlo,monospace}code{padding:2px 5px;border-radius:4px;background:var(--code)}pre{background:var(--code);padding:13px 15px;border:1px solid var(--line);border-radius:6px;overflow:auto}pre code{padding:0;background:none}blockquote{border-left:3px solid var(--accent);padding:0 14px;margin-left:0;color:var(--sub)}ul,ol{padding-left:24px}li+li{margin-top:3px}table{border-collapse:collapse;display:block;overflow:auto}th,td{border:1px solid var(--line);padding:6px 12px;text-align:left}th{background:var(--code)}img{max-width:100%;height:auto}hr{border:0;border-top:1px solid var(--line);margin:1.5em 0}input[type=checkbox]{accent-color:var(--accent);margin-right:6px}del{color:var(--sub)}@media(max-width:420px){main{padding:16px}h1{font-size:24px}}
        li.task-item{list-style:none;margin-left:-20px}
        </style></head><body><main>\(body)</main></body></html>
        """
    }
}

final class MarkdownPreviewView: NSView, WKNavigationDelegate {
    private(set) var webView: WKWebView
    var onOpen: ((URL) -> Void)?
    private var version = 0
    private var lastText: String?
    private var lastDirectory: URL?
    private var lastDark: Bool?
    private var lastLanguage: Language?
    private var lastDocument: UUID?
    private var pendingScroll: Double = 0
    private var pendingNavigation: WKNavigation?
    private(set) var renderedBody = ""
    override init(frame: NSRect) {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frame)
        webView.navigationDelegate = self; webView.underPageBackgroundColor = Palette.canvas
        webView.translatesAutoresizingMaskIntoConstraints = false; addSubview(webView)
        NSLayoutConstraint.activate([webView.leadingAnchor.constraint(equalTo: leadingAnchor), webView.trailingAnchor.constraint(equalTo: trailingAnchor), webView.topAnchor.constraint(equalTo: topAnchor), webView.bottomAnchor.constraint(equalTo: bottomAnchor)])
        webView.setAccessibilityLabel(tr("common.markdown_preview"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func update(_ text: String, directory: URL?, dark: Bool, documentID: UUID? = nil) {
        guard text != lastText || directory != lastDirectory || dark != lastDark || Language.current != lastLanguage || documentID != lastDocument else { return }
        let preserveScroll = lastText != nil && lastDocument == documentID
        lastText = text; lastDirectory = directory; lastDark = dark; lastLanguage = Language.current
        lastDocument = documentID
        version += 1; let current = version
        webView.setAccessibilityLabel(tr("common.markdown_preview"))
        MarkdownRenderer.shared.render(text, directory: directory) { [weak self] result in
            guard let self = self, self.version == current else { return }
            switch result {
            case .success(let body): self.renderedBody = body
            case .failure(let error): self.renderedBody = "<p>" + MarkdownRenderer.escape(error.localizedDescription) + "</p>"
            }
            let page = MarkdownRenderer.page(self.renderedBody, dark: dark)
            if preserveScroll && self.webView.url != nil {
                self.webView.evaluateJavaScript("window.scrollY", in: nil, in: .defaultClient) { [weak self] result in
                    guard let self = self, self.version == current else { return }
                    self.pendingScroll = ((try? result.get()) as? NSNumber)?.doubleValue ?? 0
                    self.pendingNavigation = self.webView.loadHTMLString(page, baseURL: nil)
                }
            } else { self.pendingScroll = 0; self.pendingNavigation = self.webView.loadHTMLString(page, baseURL: nil) }
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === pendingNavigation, pendingScroll > 0, pendingScroll.isFinite else { return }
        webView.evaluateJavaScript("window.scrollTo(0,\(pendingScroll))", in: nil, in: .defaultClient) { _ in }
        pendingScroll = 0
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            if url.absoluteString.hasPrefix("about:blank#") { decisionHandler(.allow); return }
            if ["https", "http", "mailto", "file"].contains(url.scheme?.lowercased() ?? "") { onOpen?(url) }
            decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }
}
