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

import CoreData
import Foundation

// TODO: NSUserDefaults access for keys @"logWebServer", @"notificationsEmailsSender" and @"lastNotificationsDate" must be replaced with WebPortal properties

/// The NSException an HorosObjCException error carries, or the error itself,
/// for %@.
private func emailLogCaught(_ error: Error) -> NSObject {
    return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException ?? (error as NSError)
}

/// -setObject:forKey:, which raised NSInvalidArgumentException on a nil object.
private func emailLogSetObject(_ object: Any?, forKey key: String, in dictionary: NSMutableDictionary) {
    dictionary.perform(#selector(NSMutableDictionary.setObject(_:forKey:)), with: object, with: key)
}

/// +dictionaryWithObjectsAndKeys:, whose list ended at the first nil object.
private func emailLogMessage(template: NSMutableString?, headers: NSMutableDictionary) -> NSDictionary {
    guard let template = template else { return NSDictionary() }
    return NSDictionary(objects: [template, headers], forKeys: ["template" as NSString, "headers" as NSString])
}

/// +predicateWithFormat: with object arguments that may be nil, passed as an
/// Objective-C argument list passes them: a nil object is a null pointer, which
/// the format reads as nil.
private func emailLogPredicate(_ format: String, _ objects: [AnyObject?], _ double: Double) -> NSPredicate {
    var arguments: [CVarArg] = objects.map { object -> CVarArg in (object as? NSObject) ?? Int(0) }
    arguments.append(double)
    return withVaList(arguments) { NSPredicate(format: format, arguments: $0) }
}

/// A property of the study, sent as the former message to whatever object the
/// caller passed.
private func emailLogMessage(_ object: NSManagedObject?, _ name: String) -> AnyObject? {
    return object?.perform(NSSelectorFromString(name))?.takeUnretainedValue()
}

/// The portal's notification e-mails, temporary users and log.
///
/// Implemented in Swift since #718: the category's Objective-C name, its
/// selectors and <Horos/WebPortal+Email+Log.h> are those of the former
/// category. E-mails are handed to CSMailMailClient on the main thread, as
/// before.
extension WebPortal {

    @objc(sendEmailOnMainThread:)
    public func sendEmailOnMainThread(_ dict: NSDictionary!) {
        autoreleasepool {
            let ts = dict?.object(forKey: "template")
            let messageHeaders = dict?.object(forKey: "headers")

            // -deliverMessage:headers: of the objects themselves, not of copies
            // bridged through Swift. Its BOOL answer was not read.
            let client = CSMailMailClient.mailClient() as? NSObject
            _ = client?.perform(#selector(CSMailMailClient.deliverMessage(_:headers:)), with: ts, with: messageHeaders)
        }
    }

    @objc(sendNotificationsEmailsTo:aboutStudies:predicate:customText:)
    public func sendNotificationsEmails(to users: [Any]!, aboutStudies filteredStudies: [Any]!, predicate: String!, customText: String!) -> Bool {
        return sendNotificationsEmails(to: users, aboutStudies: filteredStudies, predicate: predicate, customText: customText, from: nil)
    }

    @objc(sendNotificationsEmailsTo:aboutStudies:predicate:customText:from:)
    public func sendNotificationsEmails(to users: [Any]!, aboutStudies filteredStudies: [Any]!, predicate: String!, customText: String!, from: WebPortalUser!) -> Bool {
        var fromEmailAddress = UserDefaults.standard.value(forKey: "notificationsEmailsSender")
        if fromEmailAddress == nil {
            fromEmailAddress = ""
        }

        for case let user as WebPortalUser in (users as NSArray?) ?? [] {
            let tokens = NSMutableDictionary()

            if let customText = customText { tokens.setObject(customText, forKey: "customText" as NSString) }
            tokens.setObject(user, forKey: "Destination" as NSString)
            if let from = from {
                tokens.setObject(from, forKey: "FromUser" as NSString)
            }
            emailLogSetObject(self.url(), forKey: "WebServerURL", in: tokens)
            emailLogSetObject(filteredStudies as NSArray?, forKey: "Studies", in: tokens)
            if let predicate = predicate { tokens.setObject(predicate, forKey: "predicate" as NSString) }

            let ts = (string(forPath: "emailTemplate.html") as NSString?)?.mutableCopy() as? NSMutableString
            WebPortalResponse.mutableString(ts, evaluateTokensWith: tokens, context: nil)

            let emailSubject = NSLocalizedString("A new radiology exam is available for you", comment: "")

            let messageHeaders = NSMutableDictionary()
            emailLogSetObject(user.email, forKey: "To", in: messageHeaders)
            emailLogSetObject(fromEmailAddress, forKey: "Sender", in: messageHeaders)
            messageHeaders.setObject(emailSubject, forKey: "Subject" as NSString)

            // NSAttributedString initWithHTML is NOT thread-safe
            performSelector(onMainThread: #selector(sendEmailOnMainThread(_:)),
                            with: emailLogMessage(template: ts, headers: messageHeaders), waitUntilDone: false)

            for case let s as NSManagedObject in (filteredStudies as NSArray?) ?? [] {
                updateLogEntry(forStudy: s, withMessage: "notification email", forUser: user.name, ip: nil)
            }
        }

        return true // succeeded
    }

    // TEMPORARY USERS
    @objc(deleteTemporaryUsers:)
    public func deleteTemporaryUsers(_ timer: Timer!) {
        let database = self.database
        database?.managedObjectContext.lock()

        do {
            try HorosObjCException.perform {
                var toBeSaved = false

                let users = database?.objects(forEntity: database?.userEntity())

                for case let user as WebPortalUser in (users as NSArray?) ?? [] {
                    if user.autoDelete?.boolValue == true, let deletionDate = user.deletionDate, deletionDate.timeIntervalSinceNow < 0 {
                        NSLog("----- Temporary User reached the EOL (end-of-life) : %@", user.name ?? "(null)")

                        self.updateLogEntry(forStudy: nil, withMessage: "temporary user deleted", forUser: user.name, ip: nil)

                        toBeSaved = true
                        database?.managedObjectContext.delete(user)
                    }
                }

                if toBeSaved {
                    // -save:NULL; -save, which Swift sees under this name, sends it.
                    _ = database?.save()
                }
            }
        } catch {
            NSLog("***** deleteTemporaryUsers exception for deleting temporary users: %@", emailLogCaught(error))
        }

        database?.managedObjectContext.unlock()
    }

    @objc public func emailNotifications() {
        if !Thread.isMainThread {
            NSLog("********* emailNotifications: applescript needs to be in the main thread")
            return
        }

        if !UserDefaults.standard.bool(forKey: "passwordWebServer") {
            return
        }

        // Lets check if new studies are available for each users! and if temporary users reached the end of their life.....

        let lastCheckDate = Date(timeIntervalSinceReferenceDate: UserDefaults.standard.double(forKey: "lastNotificationsDate"))
        let newCheckString = String(format: "%lf", Date.timeIntervalSinceReferenceDate)

        if UserDefaults.standard.object(forKey: "lastNotificationsDate") == nil {
            UserDefaults.standard.setValue(String(format: "%lf", Date.timeIntervalSinceReferenceDate), forKey: "lastNotificationsDate")
            return
        }

        let database = self.database
        let dicomDatabase = self.dicomDatabase
        database?.managedObjectContext.lock()

        // CHECK dateAdded

        if self.notificationsEnabled {
            do {
                try HorosObjCException.perform {
                    // Find all studies AFTER the lastCheckDate
                    let studies = dicomDatabase?.objects(forEntity: "Study") as NSArray?

                    if (studies?.count ?? 0) > 0 {
                        let users = database?.objects(forEntity: database?.userEntity())

                        for case let user as WebPortalUser in (users as NSArray?) ?? [] {
                            if (user.value(forKey: "emailNotification") as? NSNumber)?.boolValue == true,
                               ((user.value(forKey: "email") as? NSString)?.length ?? 0) > 2 {
                                var filteredStudies = studies

                                do {
                                    try HorosObjCException.perform {
                                        filteredStudies = studies?.filtered(using: DicomDatabase.predicate(forSmartAlbumFilter: user.value(forKey: "studyPredicate") as? String)) as NSArray?

                                        if ((user.studyPredicate as NSString?)?.length ?? 0) != 0 {
                                            filteredStudies = user.arrayByAddingSpecificStudies(to: filteredStudies as? [Any]) as NSArray?
                                        }

                                        filteredStudies = filteredStudies?.filtered(using: NSPredicate(format: "dateAdded > CAST(%lf, \"NSDate\")", lastCheckDate.timeIntervalSinceReferenceDate)) as NSArray?
                                        filteredStudies = filteredStudies?.sortedArray(using: [NSSortDescriptor(key: "date", ascending: false)]) as NSArray?
                                    }
                                } catch {
                                    NSLog("******* studyPredicate exception : %@ %@", emailLogCaught(error), user)
                                }

                                if (filteredStudies?.count ?? 0) > 0 {
                                    _ = self.sendNotificationsEmails(to: [user], aboutStudies: dicomDatabase?.objects(withIDs: filteredStudies as? [Any]),
                                                                     predicate: String(format: "browse=newAddedStudies&browseParameter=%lf", lastCheckDate.timeIntervalSinceReferenceDate),
                                                                     customText: nil)
                                }
                            }
                        }
                    }
                }
            } catch {
                NSLog("***** emailNotifications exception: %@", emailLogCaught(error))
            }
        }
        database?.managedObjectContext.unlock()

        UserDefaults.standard.setValue(newCheckString, forKey: "lastNotificationsDate")
    }

    @objc(updateLogEntryForStudy:withMessage:forUser:ip:)
    public func updateLogEntry(forStudy study: NSManagedObject!, withMessage message: String!, forUser user: String!, ip: String!) {
        if !UserDefaults.standard.bool(forKey: "logWebServer") { return }

        var independentDatabase: DicomDatabase?

        if Thread.isMainThread {
            independentDatabase = self.dicomDatabase
        } else {
            independentDatabase = self.dicomDatabase?.independentDatabase() as? DicomDatabase
        }

        var message: String? = message
        var ip: String? = ip

        do {
            try HorosObjCException.perform {
                if let user = user {
                    message = user + ": " + (message ?? "(null)")
                }

                if ip == nil {
                    ip = AppController.shared()?.privateIP()
                }

                // Search for same log entry during last 5 min
                var logs: NSArray?

                let predicate = emailLogPredicate("(patientName==%@) AND (studyName==%@) AND (message==%@) AND (originName==%@) AND (endTime >= CAST(%lf, \"NSDate\"))",
                                                  [emailLogMessage(study, "name"), emailLogMessage(study, "studyName"), message as NSString?, ip as NSString?],
                                                  Date(timeIntervalSinceNow: -5 * 60).timeIntervalSinceReferenceDate)
                logs = independentDatabase?.objects(forEntity: independentDatabase?.logEntryEntity(), predicate: predicate) as NSArray?

                if (logs?.count ?? 0) == 0 {
                    // -newObjectForEntity: answers an autoreleased object, although its
                    // name puts it in the "new" family, whose result Swift would release.
                    let logEntry = independentDatabase?
                        .perform(#selector(N2ManagedDatabase.newObject(forEntity:)), with: independentDatabase?.logEntryEntity())?
                        .takeUnretainedValue() as? NSManagedObject
                    logEntry?.setValue(Date(), forKey: "startTime")
                    logEntry?.setValue(Date(), forKey: "endTime")
                    logEntry?.setValue("Web", forKey: "type")

                    if let study = study {
                        logEntry?.setValue(emailLogMessage(study, "name"), forKey: "patientName")
                        logEntry?.setValue(emailLogMessage(study, "studyName"), forKey: "studyName")
                    }

                    logEntry?.setValue(message, forKey: "message")

                    if let ip = ip {
                        logEntry?.setValue(ip, forKey: "originName")
                    }
                } else {
                    logs?.setValue(Date(), forKey: "endTime")
                }
            }
        } catch {
            NSLog("****** OsiriX HTTPConnection updateLogEntry exception : %@", emailLogCaught(error))
        }
        _ = independentDatabase?.save()
    }

    @objc(newUserWithEmail:)
    public func newUser(withEmail email: String!) -> WebPortalUser! {
        // create user

        //NSArray* users = [self usersWithPredicate:[NSPredicate predicateWithFormat:@"email ==[cd] %@", email]];
        //if (users.count)
        //	[NSException raise:NSGenericException format:NSLocalizedString(@"A user with email %@ already exists.", NULL), email];

        if !((email as NSString?)?.isEmail() ?? false) {
            NSException(name: .genericException,
                        reason: String(format: NSLocalizedString("%@ is not an email address.", comment: ""), email ?? "(null)"),
                        userInfo: nil).raise()
        }

        let existingUsers = (self.database?.independentDatabase() as? WebPortalDatabase)?.users(with: NSPredicate(format: "email == %@", email as NSString))

        var user: WebPortalUser?

        if let existing = existingUsers, existing.count != 0 {
            user = existing[0] as? WebPortalUser
        } else {
            user = (self.database?.independentDatabase() as? WebPortalDatabase)?.newUser()
            user?.email = email
            let name = (email as NSString).substring(to: (email as NSString).range(of: "@").location)
            user?.name = name

            var i: Int32 = 1
            while !((try? user?.validateForInsert()) != nil) {
                user?.name = name + String(format: "-%d", i)
                i += 1
            }

            user?.autoDelete = NSNumber(value: true)

            // send message
            let tokens = NSMutableDictionary()

            emailLogSetObject(user, forKey: "User", in: tokens)
            emailLogSetObject(self.url(), forKey: "WebServerURL", in: tokens)

            let ts = (string(forPath: "tempUserEmail.html") as NSString?)?.mutableCopy() as? NSMutableString
            WebPortalResponse.mutableString(ts, evaluateTokensWith: tokens, context: nil)

            let emailSubject = String(format: NSLocalizedString("Temporary account on %@", comment: ""), self.url() ?? "(null)")

            let messageHeaders = NSMutableDictionary()
            emailLogSetObject(user?.email, forKey: "To", in: messageHeaders)

            if let sender = UserDefaults.standard.value(forKey: "notificationsEmailsSender") {
                messageHeaders.setObject(sender, forKey: "Sender" as NSString)
            } else {
                messageHeaders.setObject("", forKey: "Sender" as NSString)
            }
            messageHeaders.setObject(emailSubject, forKey: "Subject" as NSString)

            // NSAttributedString initWithHTML is NOT thread-safe
            performSelector(onMainThread: #selector(sendEmailOnMainThread(_:)),
                            with: emailLogMessage(template: ts, headers: messageHeaders), waitUntilDone: false)
        }

        return user
    }
}
