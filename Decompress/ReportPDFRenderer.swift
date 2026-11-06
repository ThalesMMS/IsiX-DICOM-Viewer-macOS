//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import PDFKit
import WebKit

/// The HTML and XML reports (dsr2html's rendering of a structured report)
/// printed to a paginated PDF. WebKit finds the printable page bounds
/// asynchronously, and a synchronous print can finish before that and leave
/// pages out: the page is printed through a print operation whose end is
/// waited for.
///
/// It runs in the Decompress service rather than the application: WebKit
/// needs the main thread, which the application's callers - export, web
/// portal and image loading threads, some holding locks the main thread may
/// wait for - cannot hand over safely, while the service's main thread does
/// nothing else. A print that outlives its time is answered with nothing and
/// can only finish into the service's own temporary folder, which it is
/// removed from. The report arrives as its contents: the service's sandbox
/// cannot open the application's files, and dsr2html's pages are whole in
/// themselves.
@MainActor
final class ReportPDFRenderer: NSObject, WKNavigationDelegate {

    /// The prints under way, kept until they answer.
    private static var running: [ReportPDFRenderer] = []

    /// Prints `document`, of the MIME type given, within `timeout` seconds:
    /// `reply` gets the PDF, or nil for a page that did not load or print in
    /// time or a PDF without pages.
    static func render(_ document: Data, mimeType: String, timeout: TimeInterval,
                       reply: @escaping @Sendable (Data?) -> Void) {
        // WebKit and printing need the process's NSApplication; the service
        // makes it with its first report, which conversions do not wait for.
        _ = NSApplication.shared
        let renderer = ReportPDFRenderer(reply: reply)
        running.append(renderer)
        renderer.start(document, mimeType: mimeType, timeout: timeout)
    }

    private var reply: (@Sendable (Data?) -> Void)?
    private let destination = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("isix-report-\(UUID().uuidString).pdf")
    private var webView: WKWebView?
    private var window: NSWindow?
    /// A print operation has this as its delegate until it ends.
    private var printing = false

    private init(reply: @escaping @Sendable (Data?) -> Void) {
        self.reply = reply
    }

    private func start(_ document: Data, mimeType: String, timeout: TimeInterval) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 612, height: 792), configuration: configuration)
        let window = NSWindow(contentRect: webView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        webView.navigationDelegate = self
        self.webView = webView
        self.window = window
        DispatchQueue.main.asyncAfter(deadline: .now() + max(timeout, 0)) { [self] in finish(nil) }
        // No encoding named: the page's own declaration decides, as when
        // WebKit read the file itself.
        webView.load(document, mimeType: mimeType, characterEncodingName: "", baseURL: URL(string: "about:blank")!)
    }

    /// Answers once, and lets the page go once no print operation needs it.
    private func finish(_ pdf: Data?) {
        if let reply {
            self.reply = nil
            reply(pdf)
            webView?.stopLoading()
            webView?.navigationDelegate = nil
        }
        if !printing { Self.running.removeAll { $0 === self } }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard reply != nil else { return }
        var dictionary = NSPrintInfo.shared.dictionary() as? [NSPrintInfo.AttributeKey: Any] ?? [:]
        dictionary[.jobDisposition] = NSPrintInfo.JobDisposition.save
        dictionary[.jobSavingURL] = destination
        dictionary[.allPages] = true
        dictionary[.selectionOnly] = false
        dictionary.removeValue(forKey: .firstPage)
        dictionary.removeValue(forKey: .lastPage)
        let info = NSPrintInfo(dictionary: dictionary)
        info.paperSize = NSSize(width: 612, height: 792)
        info.orientation = .portrait
        info.topMargin = 30
        info.bottomMargin = 30
        info.leftMargin = 24
        info.rightMargin = 24
        info.horizontalPagination = .automatic
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.canSpawnSeparateThread = true
        guard let window else { return finish(nil) }
        printing = true
        operation.runModal(for: window, delegate: self,
                           didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(nil) }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(nil) }

    /// AppKit may end the print on its worker thread. A print that ended after
    /// its time only leaves its file to remove.
    @objc nonisolated func printOperationDidRun(_ operation: NSPrintOperation, success: Bool,
                                                contextInfo: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                var pdf: Data?
                if success, let document = PDFDocument(url: self.destination), document.pageCount > 0,
                   document.allowsPrinting {
                    pdf = try? Data(contentsOf: self.destination)
                }
                try? FileManager.default.removeItem(at: self.destination)
                self.printing = false
                self.finish(pdf)
            }
        }
    }
}
