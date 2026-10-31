/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit
import IsiXDatabase
import IsiXPreferences

/// Sending from the browser by e-mail: a notification of the selected studies
/// to web portal users, and the selection as a password-protected ZIP in a
/// Mail draft with no recipient.
@MainActor struct MailExport {
    let browser: BrowserController
    let preferences: any PreferenceStore

    init(browser: BrowserController, preferences: any PreferenceStore = PreferencesSource.process.preferences) {
        self.browser = browser
        self.preferences = preferences
    }

    // MARK: Notification

    /// The notification sheet: the chosen web portal users (and a new user
    /// for a typed address) get the selected studies and a notification
    /// e-mail with the custom text.
    func notifyPortalUsers() {
        browser.temporaryNotificationEmail = ""
        browser.customTextNotificationEmail = ""
        browser.horos_notificationEmailArrayController?.setSelectionIndexes(IndexSet())
        guard let sheet = browser.horos_notificationEmailWindow else { return }
        browser.window?.beginSheet(sheet, completionHandler: nil)

        while true {
            let result = NSApp.runModal(for: sheet)
            sheet.makeFirstResponder(nil)
            guard result == .stop else { break }

            let selectedUsers = browser.horos_notificationEmailArrayController?.selectedObjects ?? []
            var retry = false
            if let exception = HorosObjCException.caught({
                var destinationUsers = selectedUsers
                switch EmailSheetRules.notificationRecipients(selectedUsers: selectedUsers.count, typedAddress: browser.temporaryNotificationEmail) {
                case .noneSelected:
                    notificationError(NSLocalizedString("Select one or more users.", comment: ""))
                    retry = true
                    return
                case .missingAt:
                    notificationError(NSLocalizedString("Is the user email correct? the @ character is not found.", comment: ""))
                    retry = true
                    return
                case .nameTooShort:
                    notificationError(NSLocalizedString("Name needs to be at least 2 characters.", comment: ""))
                    retry = true
                    return
                case .accepted(let newUserEmail):
                    // First, a temporary user for the typed address.
                    if let newUserEmail, let user = WebPortal.default()?.newUser(withEmail: newUserEmail) {
                        destinationUsers.append(user)
                    }
                }
                if let exception = HorosObjCException.caught({ notify(destinationUsers) }) {
                    BrowserObjC.log(exception, stack: true, "-[BrowserController sendEmailNotification:]")
                }
            }) {
                BrowserObjC.log(exception, stack: true, "-[BrowserController sendEmailNotification:]")
            }
            if !retry { break }
        }

        sheet.sheetParent?.endSheet(sheet)
        sheet.orderOut(browser)
    }

    private func notificationError(_ message: String) {
        _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Error", comment: ""), message: message,
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
    }

    /// Links the selected studies to the users (as of the last notification
    /// date) and sends them the notification e-mail.
    private func notify(_ destinationUsers: [Any]) {
        guard !destinationUsers.isEmpty else { return }
        let portal = WebPortal.default()
        PortalStudyLinks(portal: portal).link(browser.databaseSelection() ?? [], to: destinationUsers,
                                              dateAdded: Date(timeIntervalSinceReferenceDate: preferences[WebPortalPreferences.lastNotificationsDate]))
        _ = portal?.sendNotificationsEmails(to: destinationUsers, aboutStudies: browser.databaseSelection(), predicate: nil,
                                            customText: browser.customTextNotificationEmail)
    }

    // MARK: Send by e-mail

    /// "Send by e-mail": the selection exported as an encrypted ZIP (the
    /// password typed in the sheet, 8 characters at least), wrapped as a
    /// protected attachment in a Mail draft with no recipient.
    func sendSelection() {
        guard AppController.hasMacOSXSnowLeopard() else {
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Unsupported", comment: ""),
                                            message: NSLocalizedString("This function requires MacOS 10.6 or higher.", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }
        // A password an earlier version left in the preferences goes now.
        preferences.remove(ApplicationPreferences.emailZIPPassword)
        guard let sheet = browser.horos_ZIPpasswordWindow else { return }
        let field = Self.passwordField(in: sheet)
        field?.stringValue = ""

        var result: NSApplication.ModalResponse
        repeat {
            browser.window?.beginSheet(sheet, completionHandler: nil)
            result = NSApp.runModal(for: sheet)
            sheet.makeFirstResponder(nil)
            sheet.sheetParent?.endSheet(sheet)
            sheet.orderOut(browser)
            if result == .stop && !EmailSheetRules.acceptsPassword(typedPassword(field)) {
                NSSound.beep()
                continue
            }
            break
        } while true
        let password = typedPassword(field)
        field?.stringValue = ""
        preferences.remove(ApplicationPreferences.emailZIPPassword)
        guard result == .stop else { return }

        let selection = SelectedFiles(of: browser, thumbnails: false, onlyImages: false)
        // The folder holds copies of the images and the archive: it goes once
        // Mail has the draft, and folders a crash or quit left go here.
        MailDraftComposer.ExportFolder.removeLeftovers()
        let folder: URL
        do {
            folder = try MailDraftComposer.ExportFolder.make()
        } catch let directoryError {
            DICOMFolderExport.presentError(directoryError as NSError)
            return
        }
        let emailDirectory = folder.path

        let request = DICOMFolderExportRequest(location: emailDirectory, files: selection.paths, objects: selection.objects.map(\.objectID),
                                               encrypt: true, password: password,
                                               folderTreeTag: browser.horos_folderTree?.selectedTag() ?? 0,
                                               compressionTag: browser.horos_compressionMatrix?.selectedTag() ?? 0)
        let exported = DICOMFolderExport(preferences: preferences).run(request, for: browser)
        guard !exported.patientFolderNames.isEmpty else {
            try? FileManager.default.removeItem(at: folder)
            return
        }

        var mailFilePaths: [String] = []
        let archiver = ProtectedZipArchiver()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: emailDirectory)) ?? [] where BrowserObjC.literallyEqual((name as NSString).pathExtension, "zip") {
            let sourceArchive = (emailDirectory as NSString).appendingPathComponent(name)
            let attachment = (emailDirectory as NSString).appendingPathComponent("Images-\(UUID().uuidString).zip")
            do {
                try archiver.protectedAttachment(from: sourceArchive, to: attachment, password: password)
            } catch let attachmentError {
                try? FileManager.default.removeItem(at: folder)
                DICOMFolderExport.presentError(attachmentError as NSError)
                return
            }
            try? FileManager.default.removeItem(atPath: sourceArchive)
            mailFilePaths.append(attachment)
        }

        MailDraftComposer.compose(subject: MailDraftComposer.protectedArchiveSubject, filePaths: mailFilePaths,
                                  removingFolder: folder) { mailError in
            if let mailError {
                _ = HorosAlertPanel.run(title: NSLocalizedString("Email Export Failed", comment: ""), message: mailError,
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }
        }
    }

    /// The sheet's password field: a secure field, which hides what is typed
    /// and keeps it from the accessibility value, with no binding, so the
    /// password is read from it and kept in memory for this export only.
    private static func passwordField(in sheet: NSWindow) -> NSSecureTextField? {
        func secureField(in view: NSView) -> NSSecureTextField? {
            if let field = view as? NSSecureTextField { return field }
            return view.subviews.lazy.compactMap(secureField).first
        }
        return sheet.contentView.flatMap(secureField)
    }

    private func typedPassword(_ field: NSSecureTextField?) -> String {
        field?.stringValue ?? ""
    }
}
