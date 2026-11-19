//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation
import IsiXMail
import IsiXPreferences
import Security

/// The password of the web portal's mail server: a generic password of the
/// Keychain under a service of the application's own, one item for each user
/// at each server (`PortalMailServer.passwordAccount`). It is never written
/// to the preferences. An application reads and writes the generic passwords
/// it made without any entitlement, in the sandbox too.
enum WebPortalMailPassword {
    static let service = "org.horosproject.horos.webportal.mailserver"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func failure(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"])
    }

    /// The password kept for `account`, or nil when there is none or it
    /// cannot be read without asking the user. An email is sent with nobody
    /// at the computer, so the read never puts up a Keychain dialog: an item
    /// that would need one counts as absent, and the email fails with that
    /// reason. Takes up to a few seconds: not for the main thread.
    static func read(account: String) -> String? {
        let (status, item) = NonInteractiveKeychainRead.read(service: service, account: account, data: true)
        guard status == errSecSuccess, let data = item?[kSecValueData as String] as? Data,
              let password = String(data: data, encoding: .utf8), !password.isEmpty else { return nil }
        return password
    }

    /// Keeps `password` for `account`, replacing the one it had.
    static func save(_ password: String, account: String) throws {
        var item = query(account)
        let value = [kSecValueData as String: Data(password.utf8)]
        let status = SecItemUpdate(item as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            item.merge(value) { _, new in new }
            item[kSecAttrSynchronizable as String] = false
            item[kSecAttrLabel as String] = "IsiX DICOM Viewer web portal mail server"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess {
            throw failure(status)
        }
    }

    /// Forgets the password of `account`; nothing to forget is not an error.
    static func remove(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }

    /// What the pane's sheet saves with a server: `typed` becomes the password
    /// of `server`; left empty, the password already kept for the same user at
    /// the same server stays. The item of the server it replaces, when that is
    /// another account, is removed, as is the item of a server that no longer
    /// authenticates.
    static func update(from former: PortalMailServer, to server: PortalMailServer, typed: String) throws {
        if former.authenticates, !server.authenticates || former.passwordAccount != server.passwordAccount {
            try remove(account: former.passwordAccount)
        }
        if server.isSet, server.authenticates, !typed.isEmpty {
            try save(typed, account: server.passwordAccount)
        }
    }
}

extension WebPortalMailDelivery {
    /// The delivery of the running application: the server of the
    /// preferences, its password from the Keychain, and the Mail application
    /// in the build that may tell it to send. Each email's end goes to the
    /// pane's status, to the unified log when it failed and to the portal's
    /// own log.
    static let process = WebPortalMailDelivery(
        server: { PortalMailServer(preferences: PreferencesSource.process.preferences) },
        password: { WebPortalMailPassword.read(account: $0) },
        mailApplication: mailApplicationOfThisBuild,
        record: { report in
            WebPortalMailStatus.process.record(report)
            if let failure = report.failure {
                NSLog("Web portal: an email was not sent: %@", failure.logText)
            }
            // The portal's log is written with the database of the thread: the main one's here.
            DispatchQueue.main.async {
                WebPortal.default()?.updateLogEntry(forStudy: nil, withMessage: report.logMessage, forUser: nil, ip: nil)
            }
        })

    #if MACAPPSTORE
    private static let mailApplicationOfThisBuild: MailApplication? = nil
    #else
    /// The message as the portal always handed it to the Mail client: its
    /// HTML and the To, Sender and Subject headers.
    private static let mailApplicationOfThisBuild: MailApplication? = { mail in
        CSMailMailClient.mailClient()?.deliverMessage(mail.body, headers: ["To": mail.recipients, "Sender": mail.sender,
                                                                             "Subject": mail.subject]) ?? false
    }
    #endif
}
