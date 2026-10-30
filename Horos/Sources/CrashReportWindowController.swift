//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

#if !MACAPPSTORE
import AppKit
import IsiXCrashReporting

/// The window that tells the user, on the launch after a crash, that the
/// application quit unexpectedly, and offers to send the report: in a mail
/// to the developer with the report attached, or in a new issue on the
/// public repository. Both open for the user to review and send; nothing
/// leaves the computer otherwise, because a report can name the files, and
/// so the patients, the application had open.
///
/// GitHub builds only: the App Store and TestFlight builds do not compile it,
/// and their crashes reach the developer through Xcode's Organizer.
@MainActor final class CrashReportWindowController: NSWindowController {
    private static var shown: CrashReportWindowController?

    let draft: CrashReportDraft

    /// Shows the window when the system wrote a crash report of this
    /// application since the last look, and records the look.
    @discardableResult
    static func showIfCrashed() -> Bool {
        let bundle = Bundle.main
        guard let report = newReport(defaults: .standard, directories: reportDirectories(),
                                     baseName: bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? "",
                                     bundleIdentifier: bundle.bundleIdentifier) else { return false }
        NSLog("Crash found.")
        let controller = CrashReportWindowController(report: report, applicationName: applicationName(bundle))
        shown = controller
        controller.showWindow(nil)
        return true
    }

    /// The system's DiagnosticReports folders.
    static func reportDirectories() -> [URL] {
        let manager = FileManager.default
        var realHome: String?
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            realHome = String(cString: directory)
        }
        return CrashReportFinder.directories(localLibrary: manager.urls(for: .libraryDirectory, in: .localDomainMask).first,
                                             userLibrary: manager.urls(for: .libraryDirectory, in: .userDomainMask).first,
                                             realHome: realHome)
    }

    /// The newest crash report since the last look, which this records.
    static func newReport(defaults: UserDefaults, directories: [URL], baseName: String, bundleIdentifier: String?) -> URL? {
        let lastCheck = defaults.object(forKey: CrashReportFinder.lastCheckKey) as? Date
        let reports = CrashReportFinder.reports(in: directories, since: lastCheck, baseName: baseName,
                                                bundleIdentifier: bundleIdentifier)
        defaults.set(Date(), forKey: CrashReportFinder.lastCheckKey)
        return CrashReportOffer.reportToOffer(isAppStore: DistributionChannel.isAppStore, newReports: reports)
    }

    static func applicationName(_ bundle: Bundle) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "IsiX DICOM Viewer"
    }

    convenience init(report: URL, applicationName: String) {
        let data = (try? Data(contentsOf: report, options: .mappedIfSafe)) ?? Data()
        self.init(draft: CrashReportDraft(applicationName: applicationName, summary: CrashSummary.of(report: data), report: report))
    }

    init(draft: CrashReportDraft) {
        self.draft = draft
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = NSLocalizedString("Crash Report", comment: "Title of the window shown after a crash")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let content = makeContent()
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("CrashReportWindowController is made in code")
    }

    private func label(_ text: String, bold: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        if bold { field.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1) }
        field.preferredMaxLayoutWidth = 480
        return field
    }

    private func makeContent() -> NSView {
        let name = draft.applicationName
        let title = label(String(format: NSLocalizedString("%@ quit unexpectedly the last time it was used.", comment: "Crash report window"), name), bold: true)
        let explanation = label(NSLocalizedString("You can help fix the problem by sending the crash report to the developer, by email or in a new issue on GitHub.", comment: "Crash report window"))
        let privacy = label(NSLocalizedString("Nothing is sent without you. The report can contain names of files and folders, which may identify patients: the email and the issue open for you to review, and to send only if you agree.", comment: "Crash report window"))

        let summary = NSTextView()
        summary.isEditable = false
        summary.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        summary.string = (draft.summary.lines + [""] + draft.summary.frames).joined(separator: "\n")
        summary.textContainerInset = NSSize(width: 4, height: 4)
        let scroll = NSScrollView()
        scroll.documentView = summary
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        summary.autoresizingMask = [.width]
        summary.minSize = NSSize(width: 0, height: 0)
        summary.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        summary.isVerticallyResizable = true
        scroll.heightAnchor.constraint(equalToConstant: 140).isActive = true

        let mail = NSButton(title: NSLocalizedString("Send by Email…", comment: "Crash report window button"),
                            target: self, action: #selector(sendByEmail(_:)))
        mail.keyEquivalent = "\r"
        let issue = NSButton(title: NSLocalizedString("Open an Issue on GitHub…", comment: "Crash report window button"),
                             target: self, action: #selector(openIssue(_:)))
        let reveal = NSButton(title: NSLocalizedString("Show Report in Finder", comment: "Crash report window button"),
                              target: self, action: #selector(showReport(_:)))
        let close = NSButton(title: NSLocalizedString("Close", comment: ""), target: self, action: #selector(closeWindow(_:)))
        close.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [reveal, NSView(), close, issue, mail])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [title, explanation, privacy, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for view in [scroll, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 560).isActive = true
        return stack
    }

    /// The mail, composed by the user's mail application with the report
    /// attached; nil when no mail application can compose one.
    func mailService() -> NSSharingService? {
        guard let service = NSSharingService(named: .composeEmail) else { return nil }
        service.recipients = draft.mailRecipients
        service.subject = draft.mailSubject
        return service.canPerform(withItems: mailItems) ? service : nil
    }

    var mailItems: [Any] { [draft.mailBody, draft.report] }

    /// The same mail as a mailto: address, without the attachment, for a
    /// computer whose mail application cannot take one.
    var mailtoURL: URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = CrashReportDraft.recipient
        components.queryItems = [URLQueryItem(name: "subject", value: draft.mailSubject),
                                 URLQueryItem(name: "body", value: draft.mailBody)]
        return components.url!
    }

    @objc func sendByEmail(_ sender: Any?) {
        if let service = mailService() {
            service.perform(withItems: mailItems)
        } else {
            // The report is then attached by hand: show it.
            NSWorkspace.shared.open(mailtoURL)
            showReport(nil)
        }
    }

    @objc func openIssue(_ sender: Any?) {
        NSWorkspace.shared.open(draft.issueURL)
        // GitHub takes the report only from the user's hand.
        showReport(nil)
    }

    @objc func showReport(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([draft.report])
    }

    @objc func closeWindow(_ sender: Any?) {
        window?.close()
        CrashReportWindowController.shown = nil
    }
}
#endif
