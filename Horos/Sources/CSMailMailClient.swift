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
//
//  CSMailMailClient.m
//  CSMail
//
//  Created by Alastair Houghton on 27/01/2006.
//  Copyright 2006 Coriolis Systems Limited. All rights reserved.
//


import AppKit
import Carbon
import CoreServices
import Security

/// Sends the web portal's e-mails: through Mail.app with an AppleScript, or
/// through SMTPClient with the account and password Mail keeps.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/CSMailMailClient.h> are those of the former class. The exported C
/// function QuitAndSleep() stays Objective-C, in CSMailMailClient+CAPI.m.
@objc(CSMailMailClient)
public final class CSMailMailClient: NSObject {
    // Ivars of the former class.
    private var _script: NSAppleScript?
    private var defaultSMTPAccount: NSDictionary?
    private var fromAddress: String?

    /// Two C functions Swift does not see: GetMacOSStatusCommentString
    /// (CarbonCore's Debugging.h is not in its module) and random(), marked
    /// unavailable. They are called through their symbols, so the log text and
    /// the attachment folder names stay the same.
    private static let getMacOSStatusCommentString: @convention(c) (OSStatus) -> UnsafePointer<CChar>? =
        unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2) /* RTLD_DEFAULT */, "GetMacOSStatusCommentString"),
                      to: (@convention(c) (OSStatus) -> UnsafePointer<CChar>?).self)
    private static let cRandom: @convention(c) () -> Int =
        unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2) /* RTLD_DEFAULT */, "random"),
                      to: (@convention(c) () -> Int).self)

    /// What %@ printed for an object: its description, or (null).
    private static func describe(_ object: Any?) -> String {
        guard let object = object else { return "(null)" }
        return (object as AnyObject).description
    }

    /// The AppleScript record {name: name, address: address}.
    private static func recipientRecord(name: String, address: String) -> NSAppleEventDescriptor {
        let fields = NSAppleEventDescriptor.list()
        let userRecord = NSAppleEventDescriptor.record()

        fields.insert(NSAppleEventDescriptor(string: "name"), at: 1)
        fields.insert(NSAppleEventDescriptor(string: name), at: 2)
        fields.insert(NSAppleEventDescriptor(string: "address"), at: 3)
        fields.insert(NSAppleEventDescriptor(string: address), at: 4)
        userRecord.setDescriptor(fields, forKeyword: AEKeyword(keyASUserRecordFields))

        return userRecord
    }

    /// A list of AppleScript records {name, address} for "Name <address>, address".
    ///
    /// Entries without an address (", ,", "<>") are left out. Every pass of
    /// the loop consumes at least one character, so any string ends it; the
    /// former loop only moved when it scanned an address or a name, and an
    /// empty entry or a leading "<" held it where it was forever. Records go
    /// at the end of the list: its positions start at 1, and the former
    /// insertion at 0 then 1 made the second recipient replace the first.
    @objc(recipientListFromString:)
    public func recipientList(from string: String!) -> NSAppleEventDescriptor! {
        let list = NSAppleEventDescriptor.list()

        guard let string = string else { return list }

        let scanner = Scanner(string: string)
        let interestingSet = CharacterSet(charactersIn: "<,")
        let blanks = CharacterSet.whitespacesAndNewlines

        while !scanner.isAtEnd {
            var name = ""
            var address = ""

            // Up to "<" or ",": the address, or the name before "<address>".
            // Nothing is scanned when the entry starts with either character.
            let text = scanner.scanUpToCharacters(from: interestingSet)

            if scanner.scanString("<") != nil {
                name = text ?? ""
                let bracketed = scanner.scanUpToString(">")
                _ = scanner.scanString(">")
                address = bracketed ?? ""
                // Whatever follows "<address>" in this entry is not an address.
                _ = scanner.scanUpToString(",")
            } else {
                address = text ?? ""
            }

            // The comma that ends the entry; an empty entry is only this.
            _ = scanner.scanString(",")

            address = address.trimmingCharacters(in: blanks)
            if !address.isEmpty {
                list.insert(CSMailMailClient.recipientRecord(name: name.trimmingCharacters(in: blanks), address: address),
                            at: list.numberOfItems + 1)
            }
        }

        return list
    }

    @objc(mailClient)
    public class func mailClient() -> CSMailMailClient! {
        return CSMailMailClient()
    }

    public override init() {
        super.init()

        if UserDefaults.standard.bool(forKey: "WebServerUseMailAppForEmails") == false {
            if defaultSMTPAccount == nil {
                defaultSMTPAccount = defaultSMTPAccountFromMail()
                if defaultSMTPAccount == nil {
                    //We can't do anything without an account.
                    NSLog("**** MailMe: No suitable SMTP account found")
                }
            }
        }
    }

    @objc(script)
    public func script() -> NSAppleScript! {
        if let script = _script {
            return script
        }

        var errorInfo: NSDictionary? = nil

        /* This AppleScript code is here to communicate with Mail.app */
        let ourScript =
            "on build_message(sendr, recip, subj, ccrec, bccrec, msgbody," +
            "                 attachfiles)\n" +
            "  tell application \"Mail\"\n" +
            "    set mailversion to version as string\n" +
            "    set msg to make new outgoing message at beginning of" +
            "      outgoing messages\n" +
            "    tell msg\n" +
            "      set the subject to subj\n" +
            "      set the content to msgbody\n" +
            "      if (sendr is not equal to \"\") then\n" +
            "        set sender to sendr\n" +
            "      end if\n" +
            "      repeat with rec in recip\n" +
            "        make new to recipient at end of to recipients with properties {" +
            "          name: |name| of rec, address: |address| of rec }\n" +
            "      end repeat\n" +
            "      repeat with rec in ccrec\n" +
            "        make new to recipient at end of cc recipients with properties {" +
            "          name: |name| of rec, address: |address| of rec }\n" +
            "      end repeat\n" +
            "      repeat with rec in bccrec\n" +
            "        make new to recipient at end of bcc recipients with properties {" +
            "          name: |name| of rec, address: |address| of rec }\n" +
            "      end repeat\n" +
            "      tell content\n" +
            "        repeat with attch in attachfiles\n" +
            "          make new attachment with properties { file name: attch } at " +
            "            after the last paragraph\n" +
            "        end repeat\n" +
            "      end tell\n" +
            "    end tell\n" +
            "    return msg\n" +
            "  end tell\n" +
            "end build_message\n" +
            "\n" +
            "on deliver_message(sendr, recip, subj, ccrec, bccrec, msgbody," +
            "                   attachfiles)\n" +
            "tell application \"Mail\" to activate\n" +
            "  set msg to build_message(sendr, recip, subj, ccrec, bccrec, msgbody," +
            "                           attachfiles)\n" +
            "  tell application \"Mail\"\n" +
            "    send msg\n" +
            "  end tell\n" +
            "end deliver_message\n" +
            "\n" +
            "on construct_message(sendr, recip, subj, ccrec, bccrec, msgbody," +
            "                     attachfiles)\n" +
            "  set msg to build_message(sendr, recip, subj, ccrec, bccrec, msgbody," +
            "                           attachfiles)\n" +
            "  tell application \"Mail\"\n" +
            "    tell msg\n" +
            "      set visible to true\n" +
            "      activate\n" +
            "    end tell\n" +
            "  end tell\n" +
            "end construct_message\n"

        _script = NSAppleScript(source: ourScript)

        if _script?.compileAndReturnError(&errorInfo) != true {
            NSLog("Unable to compile script: %@", CSMailMailClient.describe(errorInfo))
            _script = nil
        }

        return _script
    }

    @objc(name)
    public func name() -> String! {
        return "Mail.app Plugin"
    }

    @objc(applicationName)
    public func applicationName() -> String! {
        return "Mail.app"
    }

    @objc(version)
    public func version() -> String! {
        return "1.0.0"
    }

    @objc(applicationIsInstalled)
    public func applicationIsInstalled() -> Bool {
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail") != nil
    }

    @objc(applicationIcon)
    public func applicationIcon() -> NSImage! {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail") else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// SecItem defaults to the file-based search list on macOS, as the former
    /// SecKeychainFind calls did. Omit wildcard attributes: port zero and
    /// authentication type `any` must not become exact-match constraints.
    static func internetPasswordQuery(hostname: String?, username: String, port: Int) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassInternetPassword,
                                  kSecAttrAccount as String: username,
                                  kSecAttrProtocol as String: kSecAttrProtocolSMTP]
        if let hostname = hostname, !hostname.isEmpty { query[kSecAttrServer as String] = hostname }
        let number = UInt16(truncatingIfNeeded: port)
        if number != 0 { query[kSecAttrPort as String] = Int(number) }
        return query
    }

    static func mobileMePasswordQuery(username: String) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "iTools"]
        if !username.isEmpty { query[kSecAttrAccount as String] = username }
        return query
    }

    /// Query-local result ownership replaces SecKeychainItemFreeContent. Mail's
    /// interactive lookup policy is preserved; failure statuses are not hidden.
    static func copyPassword(query: [String: Any],
                             matching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching)
        -> (status: OSStatus, data: Data?) {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = matching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return (status, nil) }
        guard let data = result as? Data else { return (errSecDecode, nil) }
        return (status, data)
    }

    @objc(defaultSMTPAccountFromMail)
    public func defaultSMTPAccountFromMail() -> NSDictionary! {
        var viableAccount: NSMutableDictionary? = nil
        var selectedAccount: NSMutableDictionary? = nil
        var found = false
        var deliveryAccounts: NSArray? = nil
        var mailAccounts: NSArray? = nil

        let LionPath = ("~/Library/Mail/V2/MailData/Accounts.plist" as NSString).expandingTildeInPath

        if FileManager.default.fileExists(atPath: LionPath) {
            deliveryAccounts = NSDictionary(contentsOfFile: LionPath)?.object(forKey: "DeliveryAccounts") as? NSArray
            mailAccounts = NSDictionary(contentsOfFile: LionPath)?.object(forKey: "MailAccounts") as? NSArray
        } else {
            NSLog("***** File NOT found: %@", LionPath)
        }

        if deliveryAccounts == nil {
            deliveryAccounts = CFPreferencesCopyAppValue("DeliveryAccounts" as CFString, "com.apple.Mail" as CFString) as? NSArray
        }

        if deliveryAccounts == nil {
            NSLog("***** No DeliveryAccounts found")
            return viableAccount
        }

        if mailAccounts == nil {
            mailAccounts = CFPreferencesCopyAppValue("MailAccounts" as CFString, "com.apple.Mail" as CFString) as? NSArray
        }

        if mailAccounts == nil {
            NSLog("***** No MailAccounts found")
            return viableAccount
        }

        let deliveryAccountsBySMTPIdentifier = NSMutableDictionary(capacity: deliveryAccounts!.count)
        for case let account as NSDictionary in deliveryAccounts! {
            var identifier: String

            if account.object(forKey: "Username") != nil {
                identifier = "\(CSMailMailClient.describe(account.object(forKey: "Hostname"))):\(CSMailMailClient.describe(account.object(forKey: "Username")))"
            } else {
                identifier = CSMailMailClient.describe(account.object(forKey: "Hostname"))
            }

            deliveryAccountsBySMTPIdentifier.setObject(account, forKey: identifier as NSString)
        }

        for case let account as NSDictionary in mailAccounts! {
            guard let identifier = account.object(forKey: "SMTPIdentifier") else {
                continue
            }

            viableAccount = (deliveryAccountsBySMTPIdentifier.object(forKey: identifier) as? NSDictionary)?.mutableCopy() as? NSMutableDictionary
            // -isEqualToString: of the first address; NO when either is nil.
            let firstAddress = (account.object(forKey: "EmailAddresses") as? NSArray)?.firstObject
            let isNotificationsSender: Bool = {
                guard let address = firstAddress as? NSString,
                      let sender = UserDefaults.standard.object(forKey: "notificationsEmailsSender") as? String else { return false }
                return address.isEqual(to: sender)
            }()
            if viableAccount != nil && (found == false || isNotificationsSender) {
                let bareAddress = firstAddress
                let name = account.object(forKey: "FullUserName")
                if let name = name {
                    fromAddress = "\(CSMailMailClient.describe(name)) <\(CSMailMailClient.describe(bareAddress))>"
                } else {
                    fromAddress = (bareAddress as? NSString)?.copy() as? String
                }
                if fromAddress == nil {
                    viableAccount = nil
                }

                if (viableAccount?.object(forKey: "UseDefaultPorts") as? NSNumber)?.boolValue == true
                    || (viableAccount?.object(forKey: "UseDefaultPorts") as? NSString)?.boolValue == true {
                    viableAccount?.removeObject(forKey: "PortNumber")
                }

                if let viableAccount = viableAccount {
                    let hostname = viableAccount.value(forKey: "Hostname") as? NSString
                    var username = viableAccount.value(forKey: "Username") as? NSString
                    var port: AnyObject? = viableAccount.value(forKey: "PortNumber") as AnyObject?

                    if port == nil {
                        port = "0" as NSString
                    }

                    var err: OSStatus = noErr
                    var passwordData: Data? = nil

                    if (username?.length ?? 0) > 0 { // Do we need to retrieve a password?
                        do {
                            try HorosObjCException.perform {
                                let portNumber = (port as? NSNumber)?.intValue ?? (port as? NSString)?.integerValue ?? 0
                                let result = CSMailMailClient.copyPassword(query:
                                    CSMailMailClient.internetPasswordQuery(hostname: hostname as String?,
                                                                          username: username! as String,
                                                                          port: portNumber))
                                err = result.status
                                passwordData = result.data
                            }
                        } catch {
                            let e = (error as NSError).userInfo[HorosObjCExceptionKey]
                            NSLog("***** exception in %s: %@", "-[CSMailMailClient defaultSMTPAccountFromMail]", CSMailMailClient.describe(e))
                        }
                    }

                    if err != noErr {
                        //Try looking it up as a MobileMe account.
                        let usernameComponents = (username?.components(separatedBy: "@") as NSArray?)?.mutableCopy() as? NSMutableArray
                        usernameComponents?.removeLastObject()
                        username = usernameComponents?.componentsJoined(by: "@") as NSString?

                        let result = CSMailMailClient.copyPassword(query:
                            CSMailMailClient.mobileMePasswordQuery(username: username as String? ?? ""))
                        err = result.status
                        passwordData = result.data

                        if err != noErr {
                            let comment = CSMailMailClient.getMacOSStatusCommentString(err).map { String(cString: $0) } ?? ""
                            NSLog("**** MailMe: Could not get password for SMTP account %@: %i/%@", CSMailMailClient.describe(username), Int32(err), comment)
                        }
                    }

                    //If we successfully got either a regular SMTP password or a MobileMe password…
                    if err == noErr {
                        //…then let's proceed with sending the message.
                        let tempDictionary = NSMutableDictionary(dictionary: viableAccount)

                        if let passwordData = passwordData {
                            tempDictionary.setValue(NSString(data: passwordData, encoding: String.Encoding.utf8.rawValue), forKey: "Password")
                        }

                        selectedAccount = tempDictionary
                    }
                }

                if selectedAccount != nil {
                    found = true
                }
            }
        }
        //    NSLog( @"SMTP Account selected: %@ %@", [selectedAccount valueForKey: @"Hostname"], [selectedAccount valueForKey: @"Username"]);
        return selectedAccount
    }

    @objc(descriptorForThisProcess)
    public func descriptorForThisProcess() -> NSAppleEventDescriptor! {
        var thePSN = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kCurrentProcess))

        return NSAppleEventDescriptor(descriptorType: DescType(typeProcessSerialNumber),
                                      bytes: &thePSN,
                                      length: MemoryLayout<ProcessSerialNumber>.size)
    }

    /// -[NSUserDefaults setPersistentDomain:forName:] as the former code sent
    /// it: with nil when Mail's domain could not be read.
    private func setMailPersistentDomain(_ domain: NSDictionary?) {
        _ = UserDefaults.standard.perform(#selector(UserDefaults.setPersistentDomain(_:forName:)), with: domain, with: "com.apple.mail")
    }

    @objc(doHandler:forMessage:headers:)
    public func doHandler(_ handler: String!, forMessage messageBody: NSAttributedString!, headers messageHeaders: NSDictionary!) -> Bool {
        let body = NSMutableString()
        var errorInfo: NSDictionary? = nil
        let target = descriptorForThisProcess()
        let event = NSAppleEventDescriptor.appleEvent(withEventClass: AEEventClass(0x61736372) /* 'ascr' */,
                                                      eventID: AEEventID(kASSubroutineEvent),
                                                      targetDescriptor: target,
                                                      returnID: AEReturnID(kAutoGenerateReturnID),
                                                      transactionID: AETransactionID(kAnyTransactionID))
        let params = NSAppleEventDescriptor.list()
        let files = NSAppleEventDescriptor.list()
        let tmpdir = NSTemporaryDirectory()
        var attachtmp: String? = nil
        let fileManager = FileManager.default
        var sendr = "", subj = "", replyto = ""
        let recip = recipientList(from: messageHeaders?.object(forKey: "To") as? String)
        let ccrec = recipientList(from: messageHeaders?.object(forKey: "Cc") as? String)
        let bccrec = recipientList(from: messageHeaders?.object(forKey: "Bcc") as? String)
        var numFiles = 0
        let length = messageBody?.length ?? 0
        var pos = 0
        var range = NSRange(location: 0, length: 0)

        if let s = messageHeaders?.object(forKey: "Subject") as? String {
            subj = s
        }
        if let s = messageHeaders?.object(forKey: "ReplyTo") as? String {
            replyto = s
        }
        if let s = messageHeaders?.object(forKey: "Sender") as? String {
            sendr = s
        }

        /* Find all the attachments and replace them with placeholder text */
        while pos < length {
            let attributes = messageBody.attributes(at: pos, effectiveRange: &range)
            let attachment = attributes[.attachment] as? NSTextAttachment

            if attachment != nil && attachtmp == nil {
                /* Create a temporary directory to hold the attachments (we have to do this
                 because we can't get the full path from the NSFileWrapper) */
                repeat {
                    attachtmp = (tmpdir as NSString).appendingPathComponent(String(format: "csmail-%08lx", CSMailMailClient.cRandom()))
                } while (try? fileManager.createDirectory(atPath: attachtmp!, withIntermediateDirectories: true, attributes: nil)) == nil
            }

            if let attachment = attachment {
                let fileWrapper = attachment.fileWrapper
                let filename = (attachtmp! as NSString).appendingPathComponent(fileWrapper?.preferredFilename ?? "")
                do {
                    guard let fileWrapper else { return false }
                    try fileWrapper.write(to: URL(fileURLWithPath: filename), options: [], originalContentsURL: nil)
                } catch {
                    NSLog("Unable to prepare Mail attachment: %@", error.localizedDescription)
                    if let attachtmp { try? fileManager.removeItem(atPath: attachtmp) }
                    return false
                }
                body.append("<\(CSMailMailClient.describe(fileWrapper?.preferredFilename))>\n")

                numFiles += 1
                files.insert(NSAppleEventDescriptor(string: filename), at: numFiles)

                pos = range.location + range.length

                continue
            }

            body.append((messageBody.string as NSString).substring(with: range))

            pos = range.location + range.length
        }

        /* Replace any CF/LF pairs with just LF; also replace CRs with LFs */
        body.replaceOccurrences(of: "\r\n", with: "\n",
                                options: .literal, range: NSMakeRange(0, body.length))
        body.replaceOccurrences(of: "\r", with: "\n",
                                options: .literal, range: NSMakeRange(0, body.length))

        event.setParam(NSAppleEventDescriptor(string: handler ?? ""),
                       forKeyword: AEKeyword(keyASSubroutineName))
        params.insert(NSAppleEventDescriptor(string: sendr), at: 1)
        params.insert(recip!, at: 2)
        params.insert(NSAppleEventDescriptor(string: subj), at: 3)
        params.insert(ccrec!, at: 4)
        params.insert(bccrec!, at: 5)
        params.insert(NSAppleEventDescriptor(string: body as String), at: 6)
        params.insert(files, at: 7)

        event.setParam(params, forKeyword: AEKeyword(keyDirectObject))

        let mailDomain = UserDefaults.standard.persistentDomain(forName: "com.apple.mail") as NSDictionary?
        let UserHeaders = (mailDomain?.object(forKey: "UserHeaders") as? NSDictionary)?.mutableCopy() as? NSDictionary

        if (replyto as NSString).length > 0 {
            let defaults = (UserDefaults.standard.persistentDomain(forName: "com.apple.mail") as NSDictionary?)?.mutableCopy() as? NSMutableDictionary
            var MutableUserHeaders = (defaults?.object(forKey: "UserHeaders") as? NSDictionary)?.mutableCopy() as? NSMutableDictionary

            if MutableUserHeaders == nil {
                MutableUserHeaders = NSMutableDictionary()
            }

            MutableUserHeaders!.setValue(replyto, forKey: "Reply-To")

            defaults?.setObject(MutableUserHeaders!, forKey: "UserHeaders" as NSString)

            setMailPersistentDomain(defaults)
            UserDefaults.standard.synchronize()

            QuitAndSleep("com.apple.mail", 0.5)
        }

        if script()?.executeAppleEvent(event, error: &errorInfo) == nil {
            NSLog("Unable to communicate with Mail.app.  Error was %@.\n",
                  CSMailMailClient.describe(errorInfo))
            return false
        }

        if (replyto as NSString).length > 0 {
            let defaults = (UserDefaults.standard.persistentDomain(forName: "com.apple.mail") as NSDictionary?)?.mutableCopy() as? NSMutableDictionary

            if let UserHeaders = UserHeaders {
                defaults?.setObject(UserHeaders, forKey: "UserHeaders" as NSString)
            } else {
                defaults?.removeObject(forKey: "UserHeaders")
            }

            setMailPersistentDomain(defaults)
            UserDefaults.standard.synchronize()
        }

        return true
    }

    @objc(deliverMessage:headers:)
    public func deliverMessage(_ messageBody: String!, headers messageHeaders: NSDictionary!) -> Bool {
        let useMail = UserDefaults.standard.bool(forKey: "WebServerUseMailAppForEmails")

        return deliverMessage(messageBody, headers: messageHeaders, withMailApp: useMail)
    }

    @objc(deliverMessage:headers:withMailApp:)
    public func deliverMessage(_ messageBody: String!, headers messageHeaders: NSDictionary!, withMailApp mailApp: Bool) -> Bool {
        if mailApp {
            // This function is NOT thread safe !
            let m = messageBody?.data(using: .utf8).flatMap { NSAttributedString(html: $0, documentAttributes: nil) }

            if Thread.isMainThread == false {
                NSLog("************** This function is NOT thread safe : [[NSAttributedString alloc] initWithHTML")
            }

            return doHandler("deliver_message",
                             forMessage: m,
                             headers: messageHeaders)
        } else {
            if defaultSMTPAccount == nil {
                defaultSMTPAccount = defaultSMTPAccountFromMail()
                if defaultSMTPAccount == nil {
                    //We can't do anything without an account.
                    NSLog("**** MailMe: No suitable SMTP account found")
                    return false
                }
            }

            return CSMailMailClient.deliverSMTPMessage(messageBody, headers: messageHeaders,
                                                       account: defaultSMTPAccount!, accountAddress: fromAddress)
        }
    }

    /// The sender of an SMTP message: the Sender header when it names one,
    /// otherwise the address of the Mail account that sends it. The web
    /// portal puts an empty Sender in the headers when no
    /// notificationsEmailsSender is set, so empty counts as absent.
    static func smtpSender(header: Any?, accountAddress: String?) -> String? {
        if let sender = (header as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !sender.isEmpty {
            return sender
        }
        if let address = accountAddress?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty {
            return address
        }
        return nil
    }

    /// Hands the message to SMTPClient through this Mail account. The former
    /// code chose the account's address as a fallback sender but passed only
    /// the Sender header on: with it empty or missing, SMTPClient raised
    /// "Empty sender email address" instead of sending from the account.
    static func deliverSMTPMessage(_ messageBody: String!, headers messageHeaders: NSDictionary!, account: NSDictionary, accountAddress: String?) -> Bool {
        var mode = SMTPClientTLSModeNone

        if (account.value(forKey: "SSLEnabled") as? NSNumber)?.boolValue == true
            || (account.value(forKey: "SSLEnabled") as? NSString)?.boolValue == true {
            mode = SMTPClientTLSModeTLSIfPossible
        }

        guard let fromEmail = smtpSender(header: messageHeaders?.object(forKey: "Sender"), accountAddress: accountAddress) else {
            NSLog("**** MailMe: No sender address for the SMTP message")
            return false
        }

        var ports: [Any]

        if let portNumber = account.value(forKey: "PortNumber") {
            ports = [portNumber]
        } else {
            ports = [NSNumber(value: 25), NSNumber(value: 465), NSNumber(value: 587)]
        }

        SMTPClient.client(withServerAddress: account.value(forKey: "Hostname") as? String,
                          ports: ports,
                          tlsMode: mode,
                          username: account.value(forKey: "Username") as? String,
                          password: account.value(forKey: "Password") as? String)
            .sendMessage(messageBody,
                         withSubject: messageHeaders?.object(forKey: "Subject") as? String,
                         from: fromEmail,
                         to: messageHeaders?.object(forKey: "To") as? String)

        return true
    }

    @objc(features)
    public func features() -> Int32 {
        return Int32(kCSMCMessageDispatchFeature
                      | kCSMCMessageConstructionFeature)
    }

    @objc(applicationBundleIdentifier)
    public func applicationBundleIdentifier() -> String! {
        return "com.apple.mail"
    }
}
