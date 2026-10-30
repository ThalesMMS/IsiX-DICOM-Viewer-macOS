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

// Sending from the browser by e-mail: a notification of the selected studies
// to web portal users, and the selection as a password-protected ZIP in a Mail
// draft with no recipient.

extension BrowserController {

    #if !OSIRIX_LIGHT

    /// The notification sheet: the chosen web portal users (and a new user
    /// for a typed address) get the selected studies and a notification
    /// e-mail with the custom text.
    @objc(sendEmailNotification:)
    func sendEmailNotification(_ sender: Any!) {
        temporaryNotificationEmail = ""
        customTextNotificationEmail = ""
        horos_notificationEmailArrayController?.setSelectionIndexes(IndexSet())
        guard let sheet = horos_notificationEmailWindow else { return }
        window?.beginSheet(sheet, completionHandler: nil)

        while true {
            let result = NSApp.runModal(for: sheet)
            sheet.makeFirstResponder(nil)
            guard result == .stop else { break }

            let selectedUsers = horos_notificationEmailArrayController?.selectedObjects ?? []
            var retry = false
            if let exception = BrowserObjC.attempt({
                var destinationUsers = selectedUsers
                switch EmailSheetRules.notificationRecipients(selectedUsers: selectedUsers.count, typedAddress: temporaryNotificationEmail) {
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
                if let exception = BrowserObjC.attempt({ self.notify(destinationUsers) }) {
                    BrowserObjC.log(exception, stack: true, "-[BrowserController sendEmailNotification:]")
                }
            }) {
                BrowserObjC.log(exception, stack: true, "-[BrowserController sendEmailNotification:]")
            }
            if !retry { break }
        }

        sheet.sheetParent?.endSheet(sheet)
        sheet.orderOut(self)
    }

    private func notificationError(_ message: String) {
        _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Error", comment: ""), message: message,
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
    }

    /// Adds the selected studies to the users (as of the last notification
    /// date) and sends them the notification e-mail.
    private func notify(_ destinationUsers: [Any]) {
        guard !destinationUsers.isEmpty else { return }
        let portal = WebPortal.default()
        for case let user as NSManagedObject in destinationUsers {
            var linkedStudyUIDs = ((user.value(forKey: "studies") as? NSSet)?.allObjects as NSArray?)?.value(forKey: "studyInstanceUID") as? [Any] ?? []
            var linkedPatientUIDs = ((user.value(forKey: "studies") as? NSSet)?.allObjects as NSArray?)?.value(forKey: "patientUID") as? [Any] ?? []
            for case var study as NSManagedObject in databaseSelection() ?? [] {
                if BrowserObjC.literallyEqual(study.value(forKey: "type") as? String, "Series"), let parent = study.value(forKey: "study") as? NSManagedObject {
                    study = parent
                }
                guard WebPortalStudyLink.needsLink(studyUID: study.value(forKey: "studyInstanceUID") as? String,
                                                   patientUID: study.value(forKey: "patientUID") as? String,
                                                   linkedStudyUIDs: linkedStudyUIDs, linkedPatientUIDs: linkedPatientUIDs),
                      let context = user.managedObjectContext else { continue }
                let studyLink = NSEntityDescription.insertNewObject(forEntityName: "Study", into: context)
                studyLink.setValue((study.value(forKey: "studyInstanceUID") as? NSString)?.copy(), forKey: "studyInstanceUID")
                studyLink.setValue((study.value(forKey: "patientUID") as? NSString)?.copy(), forKey: "patientUID")
                studyLink.setValue(Date(timeIntervalSinceReferenceDate: UserDefaults.standard.double(forKey: "lastNotificationsDate")), forKey: "dateAdded")
                studyLink.setValue(user, forKey: "user")
                if let exception = BrowserObjC.attempt({ _ = portal?.database?.save() }) {
                    BrowserObjC.log(exception, stack: true, "-[BrowserController sendEmailNotification:]")
                }
                linkedStudyUIDs = ((user.value(forKey: "studies") as? NSSet)?.allObjects as NSArray?)?.value(forKey: "studyInstanceUID") as? [Any] ?? []
                linkedPatientUIDs = ((user.value(forKey: "studies") as? NSSet)?.allObjects as NSArray?)?.value(forKey: "patientUID") as? [Any] ?? []
                portal?.updateLogEntry(forStudy: study, withMessage: "Add Study to User", forUser: user.value(forKey: "name") as? String, ip: nil)
            }
        }
        _ = portal?.sendNotificationsEmails(to: destinationUsers, aboutStudies: databaseSelection(), predicate: nil,
                                            customText: customTextNotificationEmail)
    }

    /// "Send by e-mail": the selection exported as an encrypted ZIP (the
    /// password typed in the sheet, 8 characters at least), wrapped as a
    /// protected attachment in a Mail draft with no recipient.
    @objc(sendMail:)
    func sendMail(_ sender: Any!) {
        guard AppController.hasMacOSXSnowLeopard() else {
            if Thread.isMainThread {
                _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Unsupported", comment: ""),
                                                message: NSLocalizedString("This function requires MacOS 10.6 or higher.", comment: ""),
                                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }
            return
        }
        let defaults = UserDefaults.standard
        defaults.setValue("", forKey: "defaultZIPPasswordForEmail")
        guard let sheet = horos_ZIPpasswordWindow else { return }

        var result: NSApplication.ModalResponse
        repeat {
            window?.beginSheet(sheet, completionHandler: nil)
            result = NSApp.runModal(for: sheet)
            sheet.makeFirstResponder(nil)
            sheet.sheetParent?.endSheet(sheet)
            sheet.orderOut(self)
            if result == .stop && !EmailSheetRules.acceptsPassword(defaults.value(forKey: "defaultZIPPasswordForEmail") as? String) {
                NSSound.beep()
                continue
            }
            break
        } while true
        guard result == .stop else { return }

        let dicomFiles2Export = NSMutableArray()
        let filesToExport = files(forDatabaseOutlineSelection: dicomFiles2Export, onlyImages: false)

        let emailDirectory = (NSTemporaryDirectory() as NSString).appendingPathComponent("horos-mail-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(atPath: emailDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch let directoryError {
            showDICOMExportError(directoryError as NSError)
            return
        }

        let encrypt = defaults.bool(forKey: "encryptForExport")
        defaults.set(true, forKey: "encryptForExport")
        passwordForExportEncryption = defaults.value(forKey: "defaultZIPPasswordForEmail") as? String
        let exported = exportDICOMFileInt(emailDirectory, files: filesToExport, objects: dicomFiles2Export)
        defaults.set(encrypt, forKey: "encryptForExport")

        guard (exported?.count ?? 0) > 0 else { return }
        var mailFilePaths: [String] = []
        let root = emailDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] where BrowserObjC.literallyEqual((name as NSString).pathExtension, "zip") {
            let sourceArchive = (root as NSString).appendingPathComponent(name)
            let attachment = (root as NSString).appendingPathComponent("Images-\(UUID().uuidString).zip")
            // The export clears passwordForExportEncryption after packaging.
            var attachmentError: NSError?
            guard BrowserController.prepareProtectedEmailAttachment(sourceArchive, destination: attachment,
                                                                    password: defaults.string(forKey: "defaultZIPPasswordForEmail"),
                                                                    error: &attachmentError) else {
                showDICOMExportError(attachmentError)
                return
            }
            if !BrowserObjC.literallyEqual(sourceArchive, attachment) {
                try? FileManager.default.removeItem(atPath: sourceArchive)
            }
            mailFilePaths.append(attachment)
        }

        MailDraftComposer.compose(subject: "subject", filePaths: mailFilePaths) { mailError in
            if let mailError {
                _ = HorosAlertPanel.run(title: NSLocalizedString("Email Export Failed", comment: ""), message: mailError,
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }
        }
    }

    #endif
}
