//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit

/// The sheet the Listener pane's "Set Password…" button opens: the user name
/// and password other computers send to the XML-RPC interface.
///
/// The password goes to the keychain, never to the preferences, and is never
/// read back into the sheet: only the user name is shown again.
// Main actor: a sheet of the Listener pane.
@MainActor
@objc(HorosXMLRPCRemoteAccessPanel)
public final class XMLRPCRemoteAccessPanel: NSObject {
    /// What the sheet is editing.
    public struct Settings: Equatable {
        public var username: String
        public var password: String

        public init(username: String, password: String) {
            self.username = username
            self.password = password
        }

        /// Why these values cannot be saved, or `nil` when they can.
        public var refusal: String? {
            guard XMLRPCServerAccess.basicHeader(username: username, password: password) != nil else {
                return NSLocalizedString(
                    "Enter a user name without a colon and a password before letting the XML-RPC "
                        + "interface answer other network interfaces.",
                    comment: "XML-RPC credential refusal")
            }
            return nil
        }
    }

    static let shared = XMLRPCRemoteAccessPanel()

    private var sheet: NSWindow?
    private var usernameField: NSTextField?
    private var passwordField: NSSecureTextField?
    private var refusalLabel: NSTextField?
    private var completion: (() -> Void)?

    /// Opens the sheet on `window`; `completion` runs once it is closed,
    /// whether the credential was saved or not.
    @objc(editCredentialAttachedToWindow:completion:)
    public static func editCredential(attachedTo window: NSWindow, completion: (() -> Void)?) {
        let panel = shared
        let sheet = panel.makeSheet(settings: Settings(username: XMLRPCServerCredential.username ?? "", password: ""))
        panel.sheet = sheet
        panel.completion = completion
        window.beginSheet(sheet) { _ in
            panel.sheet = nil
            let done = panel.completion
            panel.completion = nil
            done?()
        }
    }

    /// The sheet, built in code: what the password protects, and the credential.
    func makeSheet(settings: Settings) -> NSWindow {
        let width: CGFloat = 460
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 220))

        let title = label(NSLocalizedString("XML-RPC User Name and Password", comment: "XML-RPC password sheet title"),
                          frame: NSRect(x: 20, y: 180, width: width - 40, height: 20))
        title.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        content.addSubview(title)

        let warning = label(XMLRPCServerAccess.exposureWarning,
                            frame: NSRect(x: 20, y: 110, width: width - 40, height: 62))
        warning.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        warning.textColor = .secondaryLabelColor
        warning.cell?.wraps = true
        content.addSubview(warning)

        let userLabel = label(NSLocalizedString("User name:", comment: "XML-RPC user name"),
                              frame: NSRect(x: 20, y: 84, width: 110, height: 17))
        userLabel.alignment = .right
        content.addSubview(userLabel)
        let username = NSTextField(frame: NSRect(x: 138, y: 82, width: width - 158, height: 22))
        username.stringValue = settings.username
        content.addSubview(username)
        usernameField = username

        let passwordLabel = label(NSLocalizedString("Password:", comment: "XML-RPC password"),
                                  frame: NSRect(x: 20, y: 54, width: 110, height: 17))
        passwordLabel.alignment = .right
        content.addSubview(passwordLabel)
        let password = NSSecureTextField(frame: NSRect(x: 138, y: 52, width: width - 158, height: 22))
        password.stringValue = settings.password
        content.addSubview(password)
        passwordField = password

        let refusal = label("", frame: NSRect(x: 20, y: 14, width: width - 200, height: 30))
        refusal.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        refusal.textColor = .systemRed
        refusal.cell?.wraps = true
        content.addSubview(refusal)
        refusalLabel = refusal

        let cancel = NSButton(title: NSLocalizedString("Cancel", comment: ""), target: self, action: #selector(cancel(_:)))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: width - 190, y: 12, width: 80, height: 32)
        cancel.keyEquivalent = "\u{1b}"
        content.addSubview(cancel)

        let save = NSButton(title: NSLocalizedString("Save", comment: ""), target: self, action: #selector(save(_:)))
        save.bezelStyle = .rounded
        save.frame = NSRect(x: width - 100, y: 12, width: 80, height: 32)
        save.keyEquivalent = "\r"
        content.addSubview(save)

        let sheet = NSWindow(contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: true)
        sheet.contentView = content
        return sheet
    }

    func label(_ text: String, frame: NSRect) -> NSTextField {
        let field = NSTextField(frame: frame)
        field.stringValue = text
        field.isEditable = false
        field.isSelectable = false
        field.isBezeled = false
        field.drawsBackground = false
        return field
    }

    /// What the sheet currently holds.
    var settings: Settings {
        return Settings(username: usernameField?.stringValue ?? "", password: passwordField?.stringValue ?? "")
    }

    @objc func cancel(_ sender: Any?) {
        finish()
    }

    @objc func save(_ sender: Any?) {
        let settings = self.settings
        if let refusal = settings.refusal {
            refusalLabel?.stringValue = refusal
            return
        }
        do {
            try XMLRPCServerCredential.save(username: settings.username, password: settings.password)
        } catch {
            refusalLabel?.stringValue = error.localizedDescription
            return
        }
        finish()
    }

    func finish() {
        guard let sheet = sheet, let host = sheet.sheetParent else { return }
        host.endSheet(sheet)
    }
}

extension XMLRPCServerCredential {
    /// The user name stored with the credential, decoded from the header, so
    /// the sheet can show it without the password.
    @objc public static var username: String? {
        guard let header = header, header.hasPrefix("Basic ") else { return nil }
        guard let decoded = Data(base64Encoded: String(header.dropFirst(6))),
              let joined = String(data: decoded, encoding: .utf8),
              let colon = joined.firstIndex(of: ":") else { return nil }
        return String(joined[joined.startIndex..<colon])
    }
}
