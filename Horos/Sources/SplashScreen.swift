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
/// Implemented in Swift since #714: the Objective-C name, the selectors and
/// <Horos/SplashScreen.h> are those of the former class. The C functions
/// vramSize() and useQuartz() of the former SplashScreen.m are in
/// SplashScreen+CAPI.m.
@objc(SplashScreen)
public final class SplashScreen: NSWindowController, NSWindowDelegate {
    // Outlets the xib sets: ivars of the former class.
    @IBOutlet @objc var version: NSButton!
    @IBOutlet @objc var view: AnyObject!
    @IBOutlet @objc var aboutWebView: WKWebView!
    @IBOutlet @objc var partnersWebView: WKWebView!
    @IBOutlet @objc var releaseNotesWebView: WKWebView!

    private var timerIn: Timer?
    private var timerOut: Timer?
    private var versionType: Int32 = 0

    /// The navigation delegate of the three web views, which hold it weakly.
    private var pageNavigation: SplashPageNavigation?

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
                loadSplashPage("Splash/releasenotes.html", in: releaseNotesWebView)

                //TODO - Try to load remotely, and in case if fails, load locally

                //theURL = [NSURL URLWithString:@"http://127.0.0.1:8887/releasenotes.html"];
                //theURLRequest = [NSURLRequest requestWithURL:theURL];
                //[mf loadRequest:theURLRequest];;
            }

            do {
                loadSplashPage("Splash/partners.html", in: partnersWebView)

                //TODO - Try to load remotely, and in case if fails, load locally

                //theURL = [NSURL URLWithString:@"http://127.0.0.1:8887/partners.html"];
                //theURLRequest = [NSURLRequest requestWithURL:theURL];
                //[mf loadRequest:theURLRequest];;
            }

            self.window?.level = .floating
        }
    }

    public override func windowDidLoad() {
        super.windowDidLoad()

        self.window?.center()
        versionType = 0
        switchVersion(self)

        self.window?.delegate = self
        self.window?.alphaValue = 0.0
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

    @IBAction public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
    }

    @objc(affiche)
    public func affiche() {
        timerIn = Timer.scheduledTimer(timeInterval: 0.02, target: self, selector: #selector(fadeIn(_:)), userInfo: nil, repeats: true)
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

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        timerIn?.invalidate()
        timerIn = nil

        // Set up our timer to periodically call the fade: method.
        timerOut = Timer.scheduledTimer(timeInterval: 0.02, target: self, selector: #selector(fade(_:)), userInfo: nil, repeats: true)
        // Don't close just yet.
        return false
    }

    @objc(fade:)
    func fade(_ theTimer: Timer!) {
        if (self.window?.alphaValue ?? 0) > 0.0 {
            self.window?.alphaValue = (self.window?.alphaValue ?? 0) - 0.1
        } else {
            timerOut?.invalidate()
            timerOut = nil

            self.window?.close()
        }
    }

    @objc(fadeIn:)
    func fadeIn(_ theTimer: Timer!) {
        if (self.window?.alphaValue ?? 0) < 1.0 {
            self.window?.alphaValue = (self.window?.alphaValue ?? 0) + 0.1
        } else {
            timerIn?.invalidate()
            timerIn = nil

            self.window?.alphaValue = 1.0
        }
    }

    @IBAction @objc(openHorosWebsite:)
    public func openHorosWebsite(_ sender: Any!) {
        if let url = URL(string: "https://www.horosproject.org") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Where the About pages may go. The bundled pages and the files beside them
/// (licenses.html, the license texts) open in their tab; a link to the web or
/// to mail opens once in the user's browser or mail application and leaves the
/// page as it is. Nothing else navigates: the pages load no remote content.
///
/// Private, so that the generated Objective-C interface does not name WebKit's
/// protocol (#970).
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
