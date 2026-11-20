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
import IsiXHTTPServer
import IsiXPreferences

/// The look, once the application has launched, at which application the
/// system gives the schemes of the links to.
///
/// With the URL support on, a scheme another application opens means the
/// links of a RIS open that application, and nothing is seen here. What is
/// done about it is the rule's answer (LinkSchemeHandlers): by default the
/// user is told, in a panel that is not modal, since a link may have launched
/// the application and is being carried out; only when the user chose it is
/// the scheme taken back without asking.
@MainActor
struct LinkSchemeStartupCheck {
    let preferences: any PreferenceStore

    func run() {
        let urlSupportOn = preferences[NetworkPreferences.linkSchemeSupport]
        // The system is asked only when the answer can matter.
        let handlers = urlSupportOn ? LinkSchemeRegistry.handlers() : []
        let policy = LinkSchemeHandlers.StartupPolicy(stored: preferences[NetworkPreferences.linkSchemeStartupPolicy])
        let decisions = LinkSchemeHandlers.decisions(handlers: handlers, running: LinkSchemeRegistry.running,
                                                     urlSupportOn: urlSupportOn, policy: policy)
        let registry = LinkSchemeRegistry(preferences: preferences)

        let taken = decisions.filter { $0.action == .takeBack }.map(\.scheme)
        if !taken.isEmpty {
            NSLog("link schemes opened by another application at launch, taken back as chosen: %@", taken.joined(separator: ", ") as NSString)
            Task { @MainActor in
                let failures = await LinkSchemeNotice.take(taken, with: registry)
                if !failures.isEmpty { LinkSchemeNotice.shared.report(failures) }
            }
        }

        let told = decisions.filter { $0.action == .notify }
        if !told.isEmpty {
            NSLog("link schemes opened by another application at launch: %@", told.map(\.scheme).joined(separator: ", ") as NSString)
            LinkSchemeNotice.shared.ask(about: told, registry: registry)
        }
    }
}

/// The panel that tells which application opens the schemes of the links, and
/// the one that tells a change did not happen. Never modal, and never made
/// the key window by itself: whatever a link opened stays in front.
@MainActor
final class LinkSchemeNotice: NSObject, NSWindowDelegate {
    static let shared = LinkSchemeNotice()

    private var panel: NSPanel?
    private var registry: LinkSchemeRegistry?
    private var schemes: [String] = []
    private var alwaysBox: NSButton?
    private var neverBox: NSButton?

    /// Takes each of `schemes`, one after the other, and answers what to tell
    /// the user of the ones the system did not hand over.
    static func take(_ schemes: [String], with registry: LinkSchemeRegistry) async -> [String] {
        var failures: [String] = []
        for scheme in schemes {
            if let failure = await registry.take(scheme) { failures.append(failure) }
        }
        return failures
    }

    /// What the panel says of `decisions`: one line for each scheme, with the
    /// application as the system names it, then what follows from it.
    static func text(for decisions: [LinkSchemeHandlers.Decision]) -> String {
        let lines = decisions.map { decision in
            String(format: NSLocalizedString("%@:// links are opened by %@", comment: "Link schemes: %1$@ is a scheme, %2$@ an application's name and path, or the text for no application"),
                   decision.scheme, LinkSchemeRegistry.describe(decision.handler))
        }
        return lines.joined(separator: "\n") + "\n\n"
            + NSLocalizedString("A RIS, a web page or a document that uses these links opens that application, not IsiX DICOM Viewer.\n\nAn application that also declares a scheme can take it again later. isix:// links are declared by IsiX DICOM Viewer alone.", comment: "Link schemes: the notice at launch")
    }

    /// Tells the user of the schemes another application opens, with the choice.
    func ask(about decisions: [LinkSchemeHandlers.Decision], registry: LinkSchemeRegistry) {
        self.registry = registry
        schemes = decisions.map(\.scheme)

        let always = NSButton(checkboxWithTitle: NSLocalizedString("Always at startup", comment: "Link schemes: make this application the default at every launch, without asking"),
                              target: self, action: #selector(optionChanged(_:)))
        let never = NSButton(checkboxWithTitle: NSLocalizedString("Don't ask again", comment: "Link schemes: no notice at launch any more"),
                             target: self, action: #selector(optionChanged(_:)))
        alwaysBox = always
        neverBox = never

        let make = NSButton(title: NSLocalizedString("Make IsiX the Default", comment: "Link schemes: this application opens the links from now on"),
                            target: self, action: #selector(makeDefault(_:)))
        let later = NSButton(title: NSLocalizedString("Not Now", comment: "Link schemes: leave the links as they are"),
                             target: self, action: #selector(notNow(_:)))
        later.keyEquivalent = "\u{1b}"

        show(title: NSLocalizedString("Another application opens the links of IsiX DICOM Viewer", comment: "Link schemes: title of the notice at launch"),
             text: Self.text(for: decisions), options: [always, never], buttons: [later, make])
    }

    /// Tells the user of changes the system did not make.
    func report(_ failures: [String]) {
        alwaysBox = nil
        neverBox = nil
        schemes = []
        let done = NSButton(title: NSLocalizedString("OK", comment: ""), target: self, action: #selector(dismiss(_:)))
        show(title: NSLocalizedString("The links are still opened by another application", comment: "Link schemes: title of the notice of a change that did not happen"),
             text: failures.joined(separator: "\n\n"), options: [], buttons: [done])
    }

    private func show(title: String, text: String, options: [NSButton], buttons: [NSButton]) {
        panel?.orderOut(nil)

        let heading = NSTextField(wrappingLabelWithString: title)
        heading.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        let body = NSTextField(wrappingLabelWithString: text)
        body.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        body.isSelectable = true
        for label in [heading, body] {
            label.preferredMaxLayoutWidth = 440
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        // The buttons at the trailing edge: what is left of the row goes before them.
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let buttonRow = NSStackView(views: [spacer] + buttons)
        buttonRow.orientation = .horizontal
        buttonRow.distribution = .fill
        buttonRow.spacing = 10

        let column = NSStackView(views: [heading, body] + options + [buttonRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        column.setCustomSpacing(16, after: body)
        column.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            column.topAnchor.constraint(equalTo: content.topAnchor),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            column.widthAnchor.constraint(equalToConstant: 480),
            buttonRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -20),
        ])

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
                            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        panel.title = NSLocalizedString("URL scheme", comment: "")
        panel.contentView = content
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.delegate = self
        panel.layoutIfNeeded()
        panel.setContentSize(content.fittingSize)
        panel.center()
        // In front without taking the keyboard from what a link opened.
        panel.orderFront(nil)
        self.panel = panel
    }

    /// The two options exclude each other.
    @objc private func optionChanged(_ sender: NSButton) {
        guard sender.state == .on else { return }
        if sender === alwaysBox { neverBox?.state = .off } else { alwaysBox?.state = .off }
    }

    /// The schemes become this application's; with an option ticked, the
    /// choice for the launches to come is kept too.
    @objc private func makeDefault(_ sender: Any?) {
        guard let registry else { return }
        if alwaysBox?.state == .on {
            registry.preferences.set(LinkSchemeHandlers.StartupPolicy.takeBack.rawValue, for: NetworkPreferences.linkSchemeStartupPolicy)
        } else if neverBox?.state == .on {
            registry.preferences.set(LinkSchemeHandlers.StartupPolicy.never.rawValue, for: NetworkPreferences.linkSchemeStartupPolicy)
        }
        let schemes = self.schemes
        close()
        Task { @MainActor in
            let failures = await Self.take(schemes, with: registry)
            if !failures.isEmpty { self.report(failures) }
        }
    }

    /// Nothing changes; "Don't ask again" alone is kept. "Always at startup"
    /// says what to do with the schemes, which was just declined.
    @objc private func notNow(_ sender: Any?) {
        if neverBox?.state == .on {
            registry?.preferences.set(LinkSchemeHandlers.StartupPolicy.never.rawValue, for: NetworkPreferences.linkSchemeStartupPolicy)
        }
        close()
    }

    @objc private func dismiss(_ sender: Any?) {
        close()
    }

    private func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// The close button is "Not Now" with nothing ticked.
    func windowWillClose(_ notification: Notification) {
        panel = nil
    }
}
