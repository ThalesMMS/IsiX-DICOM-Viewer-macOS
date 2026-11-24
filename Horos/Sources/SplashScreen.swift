/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit
import WebKit

/// Window Controller for Splash Window: the File's Owner of Splash.xib.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/SplashScreen.h> are those of the former class.
@objc(SplashScreen)
public final class SplashScreen: NSWindowController, NSWindowDelegate {
    // Outlets the xib sets: ivars of the former class.
    @IBOutlet @objc var version: NSButton!
    @IBOutlet @objc var view: AnyObject!
    @IBOutlet @objc var aboutWebView: WKWebView!
    @IBOutlet @objc var partnersWebView: WKWebView!
    @IBOutlet @objc var releaseNotesWebView: WKWebView!

    private var versionType: Int32 = 0

    /// The navigation delegate of the three web views, which hold it weakly.
    private var pageNavigation: SplashPageNavigation?

    /// Waits for the bundled release notes page when the release's notes arrive first.
    private var releaseNotesLoading: NSKeyValueObservation?

    /// Loads a page of the application's resources into a web view: the
    /// former [NSString stringWithFormat:@"%@Splash/about.html", resourceURLString]
    /// and its two siblings. The web view may read the Splash folder, so the
    /// page's style sheet, images and linked license files resolve.
    private func loadSplashPage(_ page: String, in webView: WKWebView?) {
        guard let webView = webView,
              let resourceURL = Bundle.main.resourceURL else { return }

        let pageURL = resourceURL.appendingPathComponent(page)
        let pagesDirectory = pageURL.deletingLastPathComponent()

        if pageNavigation == nil {
            pageNavigation = SplashPageNavigation(pagesDirectory: pagesDirectory)
        }
        webView.navigationDelegate = pageNavigation
        webView.loadFileURL(pageURL, allowingReadAccessTo: pagesDirectory)
    }

    public override func awakeFromNib() {
        MainActor.assumeIsolated {
            do {
                loadSplashPage("Splash/about.html", in: aboutWebView)

                //TODO - Try to load remotely, and in case if fails, load locally

                //theURL = [NSURL URLWithString:@"http://127.0.0.1:8887/about.html"];
                //theURLRequest = [NSURLRequest requestWithURL:theURL];
                //[mf loadRequest:theURLRequest];;
                let missingNotices = LicenseAttribution.missingNotices(in: Bundle.main)
                if !missingNotices.isEmpty {
                    NSLog("Horos: missing bundled license notices: %@", missingNotices.joined(separator: ", "))
                }
            }

            do {
                // The bundled page stays when the latest release cannot be read.
                loadSplashPage("Splash/releasenotes.html", in: releaseNotesWebView)
                #if !MACAPPSTORE
                ReleaseNotes.fetchLatest { [weak self] notes in
                    if let notes = notes { self?.showReleaseNotes(notes.html) }
                }
                #endif
            }

            do {
                loadSplashPage("Splash/licenses.html", in: partnersWebView)

                //TODO - Try to load remotely, and in case if fails, load locally

                //theURL = [NSURL URLWithString:@"http://127.0.0.1:8887/licenses.html"];
                //theURLRequest = [NSURLRequest requestWithURL:theURL];
                //[mf loadRequest:theURLRequest];;
            }
        }
    }

    /// Puts the latest release's notes in the bundled page, which keeps its
    /// header and style sheet. The web view itself loads nothing remote: the
    /// notes were fetched apart and arrive here as markup.
    private func showReleaseNotes(_ html: String) {
        guard let webView = releaseNotesWebView else { return }
        if webView.isLoading {
            releaseNotesLoading = webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard !webView.isLoading, let self = self, self.releaseNotesLoading != nil else { return }
                    self.releaseNotesLoading = nil
                    self.showReleaseNotes(html)
                }
            }
            return
        }
        webView.callAsyncJavaScript("const content = document.getElementById('content'); if (content) { content.innerHTML = html; }",
                                    arguments: ["html": html], in: nil, in: .page, completionHandler: nil)
    }

    public override func windowDidLoad() {
        super.windowDidLoad()

        self.window?.center()
        versionType = 0
        switchVersion(self)

        self.window?.delegate = self
        // A window of information, not a palette: it stays when the
        // application is left for another, at the level of the other windows,
        // and opens on the desktop in use, over a window in full screen too.
        self.window?.hidesOnDeactivate = false
        self.window?.level = .normal
        self.window?.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    }

    @IBAction @objc(switchVersion:)
    public func switchVersion(_ sender: Any!) {
        var currVersionNumber: NSMutableString? = nil
        let infoDictionary = Bundle(for: type(of: self)).infoDictionary

        // +stringWithString: raised on a missing key, which ended the method
        // there; the three keys are in the application's Info.plist.
        switch versionType {
        case 0:
            guard let info = infoDictionary?["CFBundleGetInfoString"] as? String else { return }
            currVersionNumber = NSMutableString(string: info)

        case 1:
            guard let info = infoDictionary?["CFBundleVersion"] as? String else { return }
            currVersionNumber = NSMutableString(string: info)
            currVersionNumber?.insert("Revision ", at: 0)

        case 2:
            guard let info = infoDictionary?["GitHash"] as? String else { return }
            let hash = NSMutableString(string: info)
            currVersionNumber = hash

            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([hash])

        default:
            break
        }

        // -setTitle: accepted nil, which left an empty title.
        version?.title = (currVersionNumber as String?) ?? ""

        versionType += 1

        if versionType >= 3 {
            versionType = 0
        }
    }

    /// Shows the window. Closed, it opens centred on the screen of the window
    /// the user is working in: centred once when the nib loaded, it opened on
    /// whatever screen that was, which with several displays and desktops
    /// could be one the user was not looking at, and choosing About seemed to
    /// do nothing. Open, it stays where the user put it.
    @IBAction public override func showWindow(_ sender: Any?) {
        if let window = self.window, !window.isVisible,
           let screen = Self.workingScreen(excluding: window) {
            window.setFrame(Self.centredFrame(window.frame.size, in: screen.visibleFrame), display: false)
        }
        super.showWindow(sender)
    }

    /// The screen of the application's main window, else of its key window,
    /// else the screen with the menu bar.
    private static func workingScreen(excluding about: NSWindow) -> NSScreen? {
        for window in [NSApp.mainWindow, NSApp.keyWindow] {
            if let window, window !== about, window.isVisible, let screen = window.screen { return screen }
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// `size` centred in `visible`; a window taller or wider than the screen
    /// keeps its top and left edges on it.
    static func centredFrame(_ size: NSSize, in visible: NSRect) -> NSRect {
        let x = size.width < visible.width ? visible.midX - size.width / 2 : visible.minX
        let y = size.height < visible.height ? visible.midY - size.height / 2 : visible.maxY - size.height
        return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    private static var saidTheWindowIsMissing = false

    /// Shows the window, opaque, in front and key, the application active.
    ///
    /// It used to open transparent and fade in by a timer of the run loop's
    /// default mode: with the run loop in another mode the window stayed on
    /// screen at no opacity, where choosing About seemed to do nothing.
    @objc(affiche)
    public func affiche() {
        guard let window = self.window else {
            if !Self.saidTheWindowIsMissing {
                Self.saidTheWindowIsMissing = true
                NSLog("Horos: the About window could not be loaded from %@.nib", self.windowNibName ?? "its")
            }
            return
        }
        window.alphaValue = 1.0
        NSApp.activate()
        window.makeKeyAndOrderFront(self)
        // Where it opened, for whoever cannot see it, a second later: the
        // window server reports the desktop and the occlusion after it has
        // placed the window, and at the next turn of the run loop a window on
        // screen still read as hidden. All in numbers, which the system log
        // shows; it hides text arguments.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated {
            let frame = window.frame, screen = window.screen?.frame ?? .zero
            NSLog("IsiX: the About window opened at x %.0f y %.0f, %.0f x %.0f, on the screen at x %.0f y %.0f, %.0f x %.0f, of %ld screens; on the desktop in use: %d, visible: %d",
                  frame.minX, frame.minY, frame.width, frame.height, screen.minX, screen.minY, screen.width, screen.height,
                  NSScreen.screens.count, window.isOnActiveSpace ? 1 : 0, window.occlusionState.contains(.visible) ? 1 : 0)
        } }
    }

    /// The former -init loaded SplashQtz when useQuartz() said so; it always
    /// answers NO, so the window is Splash.xib.
    @objc public convenience init() {
        self.init(windowNibName: "Splash")
    }

    /// Overridden so that -initWithWindowNibName: is inherited, unchanged.
    public override init(window: NSWindow?) {
        super.init(window: window)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// The window closes at once. It used to refuse, and close when a timer
    /// had faded it out.
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        return true
    }

    /// The former fade-out and fade-in steps, each a tick of a timer: the
    /// window now closes and opens at once. The selectors stay for whoever
    /// sends them.
    @objc(fade:)
    func fade(_ theTimer: Timer!) {
        self.window?.close()
    }

    @objc(fadeIn:)
    func fadeIn(_ theTimer: Timer!) {
        self.window?.alphaValue = 1.0
    }

    /// The link under the version: this fork's page. The selector is the one
    /// the nibs and the former class's interface name.
    @IBAction @objc(openHorosWebsite:)
    public func openHorosWebsite(_ sender: Any!) {
        if let url = URL(string: "https://github.com/ThalesMMS/IsiX-DICOM-Viewer-macOS") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Where the About pages may go. The bundled pages and the files beside them
/// (licenses.html, the license texts) open in their tab; a link to the web or
/// to mail opens once in the user's browser or mail application and leaves the
/// page as it is. Nothing else navigates: the pages load no remote content.
/// The latest release's notes are fetched apart and set in the bundled page.
///
/// Private, so that the generated Objective-C interface does not name WebKit's
/// protocol.
@MainActor
private final class SplashPageNavigation: NSObject, WKNavigationDelegate {
    private let pagesDirectory: URL

    init(pagesDirectory: URL) {
        self.pagesDirectory = pagesDirectory.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static let externalSchemes: Set<String> = ["http", "https", "mailto"]

    /// Whether the URL is a file in the pages' folder or below it.
    private func isBundledPage(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(pagesDirectory.path + "/")
    }

    // The Objective-C name is spelled out: a closure type that only nearly
    // matches WebKit's (without @MainActor) exported the method under
    // another selector, which WebKit never called.
    @objc(webView:decidePolicyForNavigationAction:decisionHandler:)
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        if isBundledPage(url) || url.absoluteString == "about:blank" {
            decisionHandler(.allow)
            return
        }

        if navigationAction.navigationType == .linkActivated,
           let scheme = url.scheme?.lowercased(), Self.externalSchemes.contains(scheme) {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }
}
