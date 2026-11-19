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
import IsiXMail
import IsiXPreferences

/// What the pane says of the portal's mail server and of its emails.
enum WebPortalMailText {
    /// Why an email was not sent, for a person. What the server or the
    /// connection said is shown as it came.
    static func reason(_ failure: PortalMailFailure) -> String {
        switch failure {
        case .noServer:
            return NSLocalizedString("No mail server is set.", comment: "Web Sharing pane, why an email of the web portal was not sent")
        case .noPassword:
            return NSLocalizedString("The password of the mail server is not in the Keychain. Enter it again.", comment: "Web Sharing pane, why an email of the web portal was not sent")
        case .smtp(.emptySender):
            return NSLocalizedString("The portal has no email address to send from. Enter it in Email Address.", comment: "Web Sharing pane, why an email of the web portal was not sent; Email Address is the field of the pane")
        case let .smtp(error):
            return error.reason
        case let .connection(text):
            return text ?? NSLocalizedString("The connection to the mail server could not be opened.", comment: "Web Sharing pane, why an email of the web portal was not sent")
        case .mailApplication:
            return NSLocalizedString("The Mail application did not take the message.", comment: "Web Sharing pane, why an email of the web portal was not sent")
        }
    }

    /// The status line: when the last email was, to whom, and how it ended.
    static func status(_ report: PortalMailReport) -> String {
        let when = DateFormatter.localizedString(from: report.date, dateStyle: .short, timeStyle: .short)
        if let failure = report.failure {
            return String(format: NSLocalizedString("Last email: %1$@, to %2$@: not sent. %3$@", comment: "Web Sharing pane, status of the last email of the web portal: date and time, recipients, reason"),
                          when, report.recipients, reason(failure))
        }
        if case .server = report.route {
            return String(format: NSLocalizedString("Last email: %1$@, to %2$@: sent.", comment: "Web Sharing pane, status of the last email of the web portal: date and time, recipients"),
                          when, report.recipients)
        }
        return String(format: NSLocalizedString("Last email: %1$@, to %2$@: handed to the Mail application.", comment: "Web Sharing pane, status of the last email of the web portal: date and time, recipients"),
                      when, report.recipients)
    }

    /// The server beside its label: its address, or what happens without one
    /// in a build that may, or may not, send through the Mail application.
    static func description(of server: PortalMailServer, mailApplicationAvailable: Bool) -> String {
        if server.isSet { return server.address }
        return mailApplicationAvailable
            ? NSLocalizedString("None set: emails go through the Mail application.", comment: "Web Sharing pane, beside Mail server:")
            : NSLocalizedString("None set: emails are not sent.", comment: "Web Sharing pane, beside Mail server:")
    }
}

/// The mail server of the web portal in Settings › Web Server: two rows at the
/// bottom of the Emails box, made in code so that the localized nibs keep one
/// structure. The first has the server set, or what happens without one, and
/// the button that opens its sheet; the second, how the last email of the
/// portal ended. The box grows by the two rows with the pane.
@MainActor
final class WebPortalMailServerSettings: NSObject {
    static let rowHeight: CGFloat = 22
    static let tag = 21460

    private let server = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let edit = NSButton(title: NSLocalizedString("Edit…", comment: "Web Sharing pane, opens the sheet of the mail server"), target: nil, action: nil)
    private let preferences: UserDefaults
    private weak var box: NSBox?
    /// The box's title in the nib, which says that the Mail application has to be set up.
    private var titleWithMail = ""
    private var observation: Int?
    private var sheet: WebPortalMailServerSheet?

    /// The field of the sender's address, which every localized nib binds to the same preference.
    static func senderField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField,
           field.infoForBinding(.value)?[.observedKeyPath] as? String == "values." + WebPortalPreferences.notificationsEmailsSender.name {
            return field
        }
        for subview in view.subviews {
            if let found = senderField(in: subview) { return found }
        }
        return nil
    }

    /// Adds the rows under the box that holds the sender's address; once per view.
    static func install(in mainView: NSView, preferences: UserDefaults = PreferencesSource.process.preferences) -> WebPortalMailServerSettings? {
        guard mainView.viewWithTag(tag) == nil, let anchor = senderField(in: mainView), let content = anchor.superview,
              let box = content.superview as? NSBox, box.superview === mainView else { return nil }
        let settings = WebPortalMailServerSettings(preferences: preferences)
        settings.box = box
        settings.titleWithMail = box.title

        // The rows take the bottom of the box: what it holds moves up by their
        // height, and so does everything of the pane above the box's lower edge.
        let grow = 2 * rowHeight + 2
        let bottom = box.frame.minY
        let paneFrames = mainView.subviews.map { ($0, $0.frame) }
        let contentFrames = content.subviews.map { ($0, $0.frame) }
        let contentHeight = content.frame.height + grow
        mainView.setFrameSize(NSSize(width: mainView.frame.width, height: mainView.frame.height + grow))
        for (view, frame) in paneFrames {
            if view === box {
                view.frame = NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height + grow)
            } else {
                view.frame = frame.minY > bottom ? frame.offsetBy(dx: 0, dy: grow) : frame
            }
        }
        // A box tiles its content when it is resized; the content is given the
        // height itself if it was not, since the rows are laid out inside it.
        if content.frame.height < contentHeight { content.setFrameSize(NSSize(width: content.frame.width, height: contentHeight)) }
        for (view, frame) in contentFrames { view.frame = frame.offsetBy(dx: 0, dy: grow) }
        settings.layOut(in: content, beside: anchor)
        settings.refresh()
        settings.observation = WebPortalMailStatus.process.observe { [weak settings] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { settings?.refresh() } }
        }
        return settings
    }

    private init(preferences: UserDefaults) {
        self.preferences = preferences
        super.init()
    }

    isolated deinit {
        if let observation { WebPortalMailStatus.process.stopObserving(observation) }
    }

    /// The rows in the coordinates of a pane read from left to right, then
    /// put on the other side when the pane was mirrored for its language.
    private func layOut(in content: NSView, beside anchor: NSView) {
        let mirrored = PaneMirror.isNeeded()
        let width = content.bounds.width
        // Where the sender's field starts, and its label ends, before any mirroring.
        let fieldX = mirrored ? width - anchor.frame.maxX : anchor.frame.minX
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let margin: CGFloat = 10
        let serverY = Self.rowHeight + 8

        let label = NSTextField(labelWithString: NSLocalizedString("Mail server:", comment: "Web Sharing pane, before the SMTP server the web portal sends its emails through"))
        label.tag = Self.tag
        label.font = small
        label.alignment = .right
        label.lineBreakMode = .byTruncatingHead
        label.frame = NSRect(x: margin, y: serverY + 3, width: fieldX - 4 - margin, height: 14)

        edit.controlSize = .small
        edit.font = small
        edit.target = self
        edit.action = #selector(editServer(_:))
        edit.sizeToFit()
        edit.frame = NSRect(x: width - margin - edit.frame.width, y: serverY - 2, width: edit.frame.width, height: edit.frame.height)

        server.font = small
        server.lineBreakMode = .byTruncatingTail
        server.frame = NSRect(x: fieldX, y: serverY + 3, width: edit.frame.minX - 8 - fieldX, height: 14)

        status.font = small
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.frame = NSRect(x: margin + 5, y: 8, width: width - 2 * margin - 10, height: 14)

        for view in [label, server, edit, status] as [NSView] {
            if mirrored {
                view.frame.origin.x = width - view.frame.maxX
                view.userInterfaceLayoutDirection = .rightToLeft
            }
            view.autoresizingMask = [mirrored ? .minXMargin : .maxXMargin, .maxYMargin]
            content.addSubview(view)
        }
        if mirrored { label.alignment = .left }
    }

    /// The rows as the preferences and the last email are now.
    func refresh() {
        let set = PortalMailServer(preferences: preferences)
        let throughMail = WebPortalMailDelivery.sendsThroughMailApplication
        server.stringValue = WebPortalMailText.description(of: set, mailApplicationAvailable: throughMail)
        server.toolTip = server.stringValue
        // The nib's title asks for the Mail application, which is only true
        // of the emails that go through it.
        box?.title = !set.isSet && throughMail ? titleWithMail
            : NSLocalizedString("Emails", comment: "Web Sharing pane, title of the box of the web portal's emails")
        let line = WebPortalMailStatus.process.last.map(WebPortalMailText.status) ?? ""
        status.stringValue = line
        status.toolTip = line.isEmpty ? nil : line
    }

    @objc private func editServer(_ sender: Any?) {
        guard let window = edit.window, sheet == nil else { return }
        let sheet = WebPortalMailServerSheet(preferences: preferences)
        self.sheet = sheet
        sheet.begin(on: window) { [weak self] in
            self?.sheet = nil
            self?.refresh()
        }
    }
}

/// The sheet of the portal's mail server: its address, port, use of TLS, user
/// name and password, and a test message sent with what the sheet shows,
/// saved or not. OK stores the server in the preferences and the password in
/// the Keychain; a server without a host is no server.
@MainActor
final class WebPortalMailServerSheet: NSObject {
    private let preferences: UserDefaults
    private let former: PortalMailServer
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 260), styleMask: [.titled], backing: .buffered, defer: true)
    private let host = NSTextField(string: "")
    private let port = NSTextField(string: "")
    private let security = NSPopUpButton(frame: .zero, pullsDown: false)
    private let username = NSTextField(string: "")
    private let password = NSSecureTextField(string: "")
    private let result = NSTextField(wrappingLabelWithString: "")
    private let test = NSButton(title: NSLocalizedString("Send Test Message", comment: "Mail server sheet of the Web Sharing pane"), target: nil, action: nil)
    /// The Keychain has a password for the server the sheet opened with.
    private var formerPasswordIsKept = false
    private var ended: (() -> Void)?

    init(preferences: UserDefaults) {
        self.preferences = preferences
        former = PortalMailServer(preferences: preferences)
        super.init()
        build()
        load()
    }

    private func build() {
        func label(_ title: String) -> NSTextField {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            return label
        }
        host.placeholderString = "smtp.example.org"
        port.placeholderString = PortalMailServer.defaultPorts.map(String.init).joined(separator: ", ")
        for (title, mode) in [(NSLocalizedString("No TLS", comment: "Mail server sheet of the Web Sharing pane, Security"), SMTPTLSMode.none),
                              (NSLocalizedString("TLS if the server offers it", comment: "Mail server sheet of the Web Sharing pane, Security"), .ifPossible),
                              (NSLocalizedString("TLS required", comment: "Mail server sheet of the Web Sharing pane, Security"), .required)] {
            security.addItem(withTitle: title)
            security.lastItem?.tag = mode.rawValue
        }
        result.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        result.textColor = .secondaryLabelColor
        result.isSelectable = true

        let grid = NSGridView(views: [
            [label(NSLocalizedString("Server:", comment: "Mail server sheet of the Web Sharing pane")), host],
            [label(NSLocalizedString("Port:", comment: "Mail server sheet of the Web Sharing pane")), port],
            [label(NSLocalizedString("Security:", comment: "Mail server sheet of the Web Sharing pane, how the connection uses TLS")), security],
            [label(NSLocalizedString("User name:", comment: "Mail server sheet of the Web Sharing pane")), username],
            [label(NSLocalizedString("Password:", comment: "Mail server sheet of the Web Sharing pane")), password],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        for field in [host, username, password] { field.widthAnchor.constraint(equalToConstant: 280).isActive = true }
        port.widthAnchor.constraint(equalToConstant: 110).isActive = true

        test.target = self
        test.action = #selector(sendTest(_:))
        let cancel = NSButton(title: NSLocalizedString("Cancel", comment: ""), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: NSLocalizedString("OK", comment: ""), target: self, action: #selector(save(_:)))
        ok.keyEquivalent = "\r"
        // The test on the leading side, Cancel and OK on the trailing one: the space between them takes what is left.
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        for button in [test, cancel, ok] { button.setContentHuggingPriority(.defaultHigh, for: .horizontal) }
        let buttons = NSStackView(views: [test, spacer, cancel, ok])
        buttons.orientation = .horizontal
        buttons.distribution = .fill
        host.delegate = self
        username.delegate = self

        let column = NSStackView(views: [grid, result, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        column.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor), column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            column.topAnchor.constraint(equalTo: content.topAnchor), column.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40),
            // The answer of a test wraps within the sheet, on two lines kept for it.
            result.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40),
            result.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        panel.initialFirstResponder = host
    }

    /// The fields as the stored server is. A server never set starts with TLS
    /// required, so that a password is not sent in clear text unless that is
    /// chosen. The password is never read into its field: the field says
    /// whether the Keychain has one, and stays empty to keep it.
    private func load() {
        host.stringValue = former.host
        port.stringValue = former.port == 0 ? "" : String(former.port)
        _ = security.selectItem(withTag: (former.isSet ? former.tlsMode : .required).rawValue)
        username.stringValue = former.username
        guard former.isSet, former.authenticates else { return }
        let account = former.passwordAccount
        DispatchQueue.global(qos: .userInitiated).async {
            let kept = WebPortalMailPassword.read(account: account) != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.formerPasswordIsKept = kept
                    self.showWhetherPasswordIsKept()
                }
            }
        }
    }

    /// The password field says that the Keychain has a password only while
    /// the fields show the user and the server it is kept for: an empty field
    /// keeps that one, and no password of another account.
    private func showWhetherPasswordIsKept() {
        let server = shown
        let kept = formerPasswordIsKept && server.isSet && server.authenticates && server.passwordAccount == former.passwordAccount
        password.placeholderString = kept
            ? NSLocalizedString("Stored in the Keychain", comment: "Mail server sheet of the Web Sharing pane, placeholder of Password when one is kept")
            : nil
    }

    /// The server the fields show.
    private var shown: PortalMailServer {
        PortalMailServer(host: host.stringValue, port: port.integerValue,
                         tlsMode: SMTPTLSMode(clientValue: security.selectedTag()), username: username.stringValue)
    }

    func begin(on window: NSWindow, ended: @escaping () -> Void) {
        self.ended = ended
        window.beginSheet(panel) { [self] _ in
            panel.orderOut(nil)
            self.ended?()
            self.ended = nil
        }
    }

    @objc private func cancel(_ sender: Any?) {
        panel.sheetParent?.endSheet(panel, returnCode: .cancel)
    }

    @objc private func save(_ sender: Any?) {
        panel.makeFirstResponder(nil)
        let server = shown
        do {
            try WebPortalMailPassword.update(from: former, to: server, typed: password.stringValue)
        } catch {
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Error", comment: ""),
                                            message: String(format: NSLocalizedString("The password could not be saved in the Keychain: %@", comment: "Mail server sheet of the Web Sharing pane"), error.localizedDescription),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }
        server.store(in: preferences)
        panel.sheetParent?.endSheet(panel, returnCode: .OK)
    }

    /// Sends a message from the portal's address to itself through the server
    /// the fields show, with the password typed or, when none is typed, the
    /// one the Keychain has. Nothing is stored and the pane's status does not
    /// change: the answer is shown in the sheet.
    @objc private func sendTest(_ sender: Any?) {
        panel.makeFirstResponder(nil)
        let server = shown
        let typed = password.stringValue
        let address = preferences[WebPortalPreferences.notificationsEmailsSender] ?? ""
        let text = NSLocalizedString("Test message from the web portal", comment: "Subject and text of the test message of the mail server sheet")
        let mail = PortalMail(body: "<p>\(text)</p>", subject: text, sender: address, recipients: address)
        let delivery = WebPortalMailDelivery(server: { server },
                                             password: { typed.isEmpty ? WebPortalMailPassword.read(account: $0) : typed },
                                             mailApplication: nil, record: { _ in })
        test.isEnabled = false
        result.stringValue = NSLocalizedString("Sending...", comment: "")
        delivery.send(mail) { [weak self] report in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.showTest(report) } }
        }
    }

    private func showTest(_ report: PortalMailReport) {
        test.isEnabled = true
        if let failure = report.failure {
            result.stringValue = String(format: NSLocalizedString("The test message was not sent. %@", comment: "Mail server sheet of the Web Sharing pane; %@ is the reason"),
                                        WebPortalMailText.reason(failure))
        } else {
            result.stringValue = String(format: NSLocalizedString("The server accepted the test message for %@.", comment: "Mail server sheet of the Web Sharing pane; %@ is the address it was sent to"),
                                        report.recipients)
        }
    }
}

extension WebPortalMailServerSheet: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        showWhetherPasswordIsKept()
    }
}
