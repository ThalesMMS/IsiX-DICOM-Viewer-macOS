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

import Foundation

// SMTPClient is implemented in Swift since #710. The Objective-C name, the
// selectors and <Horos/SMTPClient.h> are those of the former class; the SMTP*
// constants stay in Objective-C, in SMTPClient+CAPI.m.

/// An NSException the former code raised, carried as a Swift error: Swift
/// cannot unwind an NSException through its own frames, so the session code
/// throws this and -start logs it where the former @catch did.
fileprivate struct SMTPFailure: Error, @unchecked Sendable {
    let exception: NSException

    init(_ name: NSExceptionName, _ reason: String) {
        exception = NSException(name: name, reason: reason, userInfo: nil)
    }

    init(_ exception: NSException) {
        self.exception = exception
    }

    /// Raises it, for the public methods whose callers expect the exception.
    func raise() {
        exception.raise()
    }
}

/// The NSException HorosObjCException caught, or a generic one.
fileprivate func caughtException(_ error: Error) -> NSException {
    if let failure = error as? SMTPFailure { return failure.exception }
    if let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException { return exception }
    return NSException(name: .genericException, reason: (error as NSError).localizedDescription, userInfo: nil)
}

/// The former NSDictionary (SMTP) -SMTP_objectForKey:ofClass:, which only
/// SMTPClient used: the object, if it is of the class.
fileprivate func smtpObject(_ params: NSDictionary?, _ key: String, _ cls: AnyClass) -> Any? {
    guard let obj = params?.object(forKey: key) else { return nil }
    if !(obj as AnyObject).isKind(of: cls) { return nil }
    return obj
}

/// The former NSString (SMTP) -splitStringAtCharacterFromSet:intoChunks::separator:,
/// the same as NSString (N2)'s: the string before and after the first
/// character of the set, and that character (0 if there is none).
fileprivate func smtpSplit(_ string: String?, at charset: CharacterSet) -> (part1: String?, part2: String?, separator: unichar) {
    guard let string = string as NSString? else { return (nil, nil, 0) }
    let i = string.rangeOfCharacter(from: charset).location
    if i != NSNotFound {
        return (string.substring(to: i), string.substring(from: i + 1), string.character(at: i))
    }
    return (string as String, nil, 0)
}

/// NSData (N2) is translated in the same issue; these call its selectors,
/// whichever language implements them, so what goes on the wire is what
/// -base64, +dataWithBase64:, -md5 and -hex produced before.
fileprivate extension NSData {
    func smtpBase64() -> String? {
        perform(NSSelectorFromString("base64"))?.takeUnretainedValue() as? String
    }

    func smtpMD5() -> NSData? {
        perform(NSSelectorFromString("md5"))?.takeUnretainedValue() as? NSData
    }

    func smtpHex() -> String? {
        perform(NSSelectorFromString("hex"))?.takeUnretainedValue() as? String
    }

    static func smtpData(base64: String?) -> NSData? {
        guard let cls = (NSData.self as AnyObject) as? NSObjectProtocol else { return nil }
        return cls.perform(NSSelectorFromString("dataWithBase64:"), with: base64)?.takeUnretainedValue() as? NSData
    }
}

/// -[NSString dataUsingEncoding:NSUTF8StringEncoding], nil for nil.
fileprivate func utf8Data(_ string: String?) -> NSData? {
    guard let string else { return nil }
    return Data(string.utf8) as NSData
}

/// -base64 of the UTF-8 of a string; nil for nil, as messaging nil gave.
fileprivate func base64UTF8(_ string: String?) -> String? {
    utf8Data(string)?.smtpBase64()
}

/// %@ of an optional string in a format, as Objective-C printed nil.
fileprivate func formatted(_ string: String?) -> String {
    string ?? "(null)"
}

@objc(SMTPClient)
public final class SMTPClient: NSObject {
    @objc public private(set) var address: String
    @objc public private(set) var ports: [Any]
    @objc public private(set) var tlsMode: Int
    @objc public private(set) var username: String?
    @objc public private(set) var password: String?

    @objc(send:)
    public static func send(_ params: NSDictionary?) {
        let serverAddress = smtpObject(params, SMTPServerAddressKey, NSString.self) as? String
        let serverPorts = smtpObject(params, SMTPServerPortsKey, NSArray.self) as? [Any]
        let serverTlsMode = smtpObject(params, SMTPServerTLSModeKey, NSNumber.self) as? NSNumber
        let serverAuthFlag = smtpObject(params, SMTPServerAuthFlagKey, NSNumber.self) as? NSNumber
        let serverUsername = smtpObject(params, SMTPServerAuthUsernameKey, NSString.self) as? String
        let serverPassword = smtpObject(params, SMTPServerAuthPasswordKey, NSString.self) as? String
        let from = smtpObject(params, SMTPFromKey, NSString.self) as? String
        let to = smtpObject(params, SMTPToKey, NSString.self) as? String
        let headers = smtpObject(params, SMTPHeadersKey, NSDictionary.self) as? NSDictionary
        let subject = smtpObject(params, SMTPSubjectKey, NSString.self) as? String
        let message = smtpObject(params, SMTPMessageKey, NSString.self) as? String

        let auth = serverAuthFlag?.boolValue ?? false

        SMTPClient(serverAddress: serverAddress, ports: serverPorts, tlsMode: serverTlsMode?.intValue ?? 0,
                   username: auth ? serverUsername : nil, password: auth ? serverPassword : nil)
            .sendMessage(message, withSubject: subject, from: from, to: to, headers: headers)
    }

    @objc(clientWithServerAddress:ports:tlsMode:username:password:)
    public static func client(withServerAddress address: String?, ports: [Any]?, tlsMode: Int, username authUsername: String?, password authPassword: String?) -> SMTPClient {
        SMTPClient(serverAddress: address, ports: ports, tlsMode: tlsMode, username: authUsername, password: authPassword)
    }

    @objc(initWithServerAddress:ports:tlsMode:username:password:)
    public init(serverAddress address: String?, ports: [Any]?, tlsMode: Int, username authUsername: String?, password authPassword: String?) {
        if ((address as NSString?)?.length ?? 0) == 0 {
            SMTPFailure(.invalidArgumentException, "Invalid server address").raise()
        }
        self.address = address ?? ""
        if let ports, !ports.isEmpty {
            self.ports = ports
        } else {
            self.ports = [NSNumber(value: 25), NSNumber(value: 465), NSNumber(value: 587)]
        }
        self.tlsMode = tlsMode
        self.username = authUsername
        self.password = authPassword
        super.init()
    }

    fileprivate static func splitAddress(_ address: String?) throws -> (email: String?, description: String?) {
        let address = (address ?? "") as NSString
        let lti = address.range(of: "<", options: []).location
        let gti = address.range(of: ">", options: .backwards).location
        if lti != NSNotFound {
            if gti != NSNotFound {
                if lti < gti {
                    let email = address.substring(with: NSRange(location: lti + 1, length: gti - lti - 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                    let desc = address.substring(to: max(0, lti - 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                    return (email, desc)
                } else {
                    throw SMTPFailure(.invalidArgumentException, "Invalid sender email address")
                }
            } else {
                throw SMTPFailure(.invalidArgumentException, "Invalid sender email address")
            }
        } else {
            if gti != NSNotFound {
                throw SMTPFailure(.invalidArgumentException, "Invalid sender email address")
            } else {
                return (address as String, nil)
            }
        }
    }

    @objc(splitAddress:intoEmail:description:)
    public static func splitAddress(_ address: String?, intoEmail email: AutoreleasingUnsafeMutablePointer<NSString?>?, description desc: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        do {
            let split = try splitAddress(address)
            email?.pointee = split.email as NSString?
            desc?.pointee = split.description as NSString?
        } catch {
            (error as? SMTPFailure)?.raise()
        }
    }

    @objc(sendMessage:withSubject:from:to:)
    public func sendMessage(_ message: String?, withSubject subject: String?, from: String?, to toAddresses: String?) {
        sendMessage(message, withSubject: subject, from: from, to: toAddresses, headers: nil)
    }

    @objc(sendMessage:withSubject:from:to:headers:)
    public func sendMessage(_ message: String?, withSubject subject: String?, from: String?, to toAddresses: String?, headers: NSDictionary?) {
        do {
            if ((from as NSString?)?.length ?? 0) == 0 { throw SMTPFailure(.invalidArgumentException, "Empty sender email address") }
            if ((toAddresses as NSString?)?.length ?? 0) == 0 { throw SMTPFailure(.invalidArgumentException, "Empty destination email address") }

            // +hostWithName: is imported as never nil; the check is the former one.
            let host: Host? = Host(name: address)
            if host == nil { throw SMTPFailure(.invalidArgumentException, "Invalid server address") }

            let connector = SMTPConnector()
            connector.client = self
            connector.message = message
            connector.subject = subject

            let sender = try SMTPClient.splitAddress(from)
            connector.from = sender.email
            connector.fromDescription = sender.description

            var to: [[String]] = []
            for component in (toAddresses! as NSString).components(separatedBy: ",") {
                let ito = component.trimmingCharacters(in: .whitespacesAndNewlines)
                let recipient = try SMTPClient.splitAddress(ito)
                // An entry without an address (", ,", "<>") is no recipient: it
                // went out as "RCPT TO: <>", which servers refuse, and the
                // whole message was lost.
                guard let email = recipient.email, !email.isEmpty else { continue }
                // +arrayWithObjects: stopped at a nil description.
                var entry = [email]
                if let label = recipient.description { entry.append(label) }
                to.append(entry)
            }
            if to.isEmpty { throw SMTPFailure(.invalidArgumentException, "Empty destination email address") }

            connector.to = to

            connector.headers = headers

            // -performSelectorInBackground: keeps the connector until -start returns.
            connector.performSelector(inBackground: #selector(SMTPConnector.start), with: nil)
        } catch {
            (error as? SMTPFailure)?.raise()
        }
    }
}

private let ConnectionStatusClosed = 0
private let ConnectionStatusConnecting = 1
private let ConnectionStatusOk = 2

// enum SMTPStatuses
private let InitialStatus = 0
private let StatusHELO = 1
private let StatusEHLO = 2
private let StatusSTARTTLS = 3
private let StatusAUTH = 4
private let StatusMAIL = 5
private let StatusRCPT = 6
private let StatusDATA = 7
private let StatusQUIT = 8

// enum SMTPSubstatuses
private let PlainAUTH = 1
private let LoginAUTH = 2
private let CramMD5AUTH = 3

/// One SMTP session, run on a thread of its own by -start. It subclassed
/// NSConnection without using it; Swift cannot see NSConnection, and the
/// class now descends from NSObject.
@objc(_SMTPConnector)
fileprivate final class SMTPConnector: NSObject, StreamDelegate {
    // setup
    var client: SMTPClient?
    var message: String?
    var subject: String?
    var from: String?
    var fromDescription: String?
    var to: [[String]]?
    var headers: NSDictionary?
    // connection
    var istream: InputStream?
    var ostream: OutputStream?
    private var handleOpenCompleted: UInt = 0
    var connectionStatus = ConnectionStatusClosed
    private let ibuffer = NSMutableData()
    private let obuffer = NSMutableData()
    private var isTLS = false
    // smtp
    var smtpStatus = InitialStatus {
        didSet { smtpSubstatus = 0 }
    }
    var smtpSubstatus = 0
    var authModes: [String]?
    var dataTimeoutTimer: Timer?
    var openTimeoutTimer: Timer?
    var rcptToCount = 0
    var canStartTLS = false
    private var success = false

    /// What an exception raised in a stream or timer callback did before: it
    /// unwound -runMode:beforeDate: into -start, which gave up on the port.
    private var pendingFailure: SMTPFailure?

    @objc func start() {
        autoreleasepool {
            do {
                try HorosObjCException.perform {
                    var exception: NSException?
                    for port in self.client?.ports ?? [] {
                        do {
                            try HorosObjCException.perform {
                                self.pendingFailure = nil
                                self.connect(port)
                            }
                            if let failure = self.pendingFailure {
                                self.pendingFailure = nil
                                throw failure
                            }

                            if self.istream?.streamError == nil && self.ostream?.streamError == nil && self.success {
                                exception = nil
                                break
                            }
                        } catch {
                            let e = caughtException(error)
                            NSLog("SMTP Exception: %@", formatted(e.reason))
                            exception = e
                        }
                    }

                    if let exception {
                        NSLog("******* SMTPClient exception: %@", exception)
                    }
                }
            } catch {
                let e = caughtException(error)
                let function: StaticString = "-[_SMTPConnector start]"
                function.withUTF8Buffer { buffer in
                    buffer.withMemoryRebound(to: CChar.self) { _N2LogExceptionImpl(e, true, $0.baseAddress) }
                }
            }
        }
    }

    /// The body of the former loop over the ports, up to the end of the run loop.
    private func connect(_ port: Any) {
        reset()

        connectionStatus = ConnectionStatusConnecting
        // -integerValue, which NSNumber and NSString answer.
        let portNumber: Int
        if let number = port as? NSNumber {
            portNumber = number.intValue
        } else if let string = port as? NSString {
            portNumber = string.integerValue
        } else {
            pendingFailure = SMTPFailure(.invalidArgumentException, "-[\(type(of: port)) integerValue]: unrecognized selector")
            return
        }
        var input: InputStream?
        var output: OutputStream?
        Stream.getStreamsToHost(withName: client?.address ?? "", port: portNumber, inputStream: &input, outputStream: &output)
        istream = input
        ostream = output
        istream?.delegate = self
        ostream?.delegate = self
        istream?.schedule(in: .current, forMode: .default)
        ostream?.schedule(in: .current, forMode: .default)

        openTimeoutTimer = Timer(fireAt: Date(timeIntervalSinceNow: 10), interval: 0, target: self,
                                 selector: #selector(_openTimeoutCallback(_:)), userInfo: nil, repeats: false)
        RunLoop.current.add(openTimeoutTimer!, forMode: .default)

        istream?.open()
        ostream?.open()

        while connectionStatus != ConnectionStatusClosed && pendingFailure == nil {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 1))
        }
    }

    func startTLS() {
        let settings = NSMutableDictionary()
        connectionStatus = ConnectionStatusConnecting
        settings.setObject(StreamSocketSecurityLevel.negotiatedSSL.rawValue, forKey: kCFStreamSSLLevel as NSString)
        settings.setObject(client?.address ?? "", forKey: kCFStreamSSLPeerName as NSString)
        let key = Stream.PropertyKey(rawValue: kCFStreamPropertySSLSettings as String)
        istream?.setProperty(settings, forKey: key)
        ostream?.setProperty(settings, forKey: key)
        istream?.open()
        ostream?.open()
        isTLS = true
    }

    @objc func _openTimeoutCallback(_ timer: Timer) {
        reset()
    }

    @objc func stream(_ stream: Stream, handle event: Stream.Event) {
        if pendingFailure != nil { return }
        do {
            try handle(stream, event)
        } catch let failure as SMTPFailure {
            pendingFailure = failure
        } catch {
            pendingFailure = SMTPFailure(caughtException(error))
        }
    }

    private func handle(_ stream: Stream, _ event: Stream.Event) throws {
        if event == .openCompleted {
            handleOpenCompleted += 1
            if handleOpenCompleted == 2 {
                openTimeoutTimer?.invalidate()
                openTimeoutTimer = nil

                connectionStatus = ConnectionStatusOk

                dataTimeoutTimer = Timer(fireAt: Date(timeIntervalSinceNow: 1), interval: 0, target: self,
                                         selector: #selector(_dataTimeoutCallback(_:)), userInfo: nil, repeats: false)
                RunLoop.current.add(dataTimeoutTimer!, forMode: .default)

                // A reply read while the other stream was still opening left
                // its command in the buffer: send it now, if there is room.
                trySendingDataNow()
            }
        }

        if stream === istream && event == .hasBytesAvailable {
            let maxLength = 2048
            var buffer = [UInt8](repeating: 0, count: maxLength)
            while true {
                let length = istream?.read(&buffer, maxLength: maxLength) ?? 0

                if length > 0 {
                    ibuffer.append(buffer, length: length)

                    try handleData(ibuffer)

                    if length < maxLength {
                        break
                    }
                } else {
                    break
                }
            }
        }

        if stream === ostream && event == .hasSpaceAvailable && obuffer.length != 0 {
            if isTLS && connectionStatus == ConnectionStatusConnecting {
                connectionStatus = ConnectionStatusOk
            }
            perform(#selector(trySendingDataNow), with: nil, afterDelay: 0)
        }

        if event == .endEncountered {
            stream.close()
            connectionStatus = ConnectionStatusClosed
        }

        if event == .errorOccurred {
            NSLog("Stream error: %@", formatted(stream.streamError?.localizedDescription))
            connectionStatus = ConnectionStatusClosed
        }
    }

    /// strnstr(bytes, "\r\n", length): the offset of the first CRLF, not
    /// looking past a NUL.
    private static func crlfOffset(_ bytes: UnsafePointer<UInt8>, _ length: Int) -> Int? {
        var i = 0
        while i + 1 < length {
            if bytes[i] == 0 { return nil }
            if bytes[i] == 13 && bytes[i + 1] == 10 { return i }
            i += 1
        }
        return nil
    }

    func handleData(_ data: NSMutableData) throws {
        if let timer = dataTimeoutTimer {
            timer.invalidate()
            dataTimeoutTimer = nil
        }

        var datap = data.bytes.assumingMemoryBound(to: UInt8.self)
        var datal = data.length
        var datalused = 0

        while datal > 0 {
            guard var l = SMTPConnector.crlfOffset(datap, datal) else { break }

            if l != 0 {
                let line = NSString(bytes: datap, length: l, encoding: String.Encoding.utf8.rawValue) as String?
                try handleLine(line)
            }

            l += 2
            datap += l
            datal -= l
            datalused += l
        }

        if datalused != 0 {
            data.replaceBytes(in: NSRange(location: 0, length: datalused), withBytes: nil, length: 0)
        }
    }

    func writeData(_ data: Data) {
        obuffer.append(data)
        if connectionStatus == ConnectionStatusOk {
            trySendingDataNow()
        }
    }

    @objc func trySendingDataNow() {
        let length = obuffer.length
        // Written before the output stream has said it has room, the bytes
        // block this thread inside -write:maxLength:, and the event that
        // would free it can only come from the run loop the thread no longer
        // runs: a server that greets as soon as it accepts the connection got
        // no HELO, ever. The command waits in the buffer instead, and the
        // .hasSpaceAvailable event sends it.
        if length != 0 && connectionStatus == ConnectionStatusOk && ostream?.hasSpaceAvailable == true {
            let sentLength = ostream?.write(obuffer.bytes.assumingMemoryBound(to: UInt8.self), maxLength: length) ?? 0
            if sentLength != -1 {
                obuffer.replaceBytes(in: NSRange(location: 0, length: sentLength), withBytes: nil, length: 0)
            } else {
                NSLog("%@ Send error: %@", self, formatted(ostream?.streamError?.localizedDescription))
            }
        }
    }

    deinit {
        reset()
    }

    // MARK: SMTP

    func reset() {
        openTimeoutTimer?.invalidate()
        openTimeoutTimer = nil

        dataTimeoutTimer?.invalidate()
        dataTimeoutTimer = nil

        ostream?.close()
        istream?.close()
        ostream?.remove(from: .current, forMode: .default)
        istream?.remove(from: .current, forMode: .default)
        ostream = nil
        istream = nil

        handleOpenCompleted = 0
        connectionStatus = ConnectionStatusClosed
        ibuffer.length = 0
        obuffer.length = 0
        isTLS = false

        smtpStatus = InitialStatus
        authModes = nil
        canStartTLS = false
        rcptToCount = 0
    }

    static func cramMD5(_ challengeString: String?, key secretString: String?) -> String? {
        var ipad = [UInt8](repeating: 0, count: 64)

        var secretData = utf8Data(secretString) ?? NSData()
        if secretData.length > 64 {
            secretData = secretData.smtpMD5() ?? NSData()
        }
        secretData.getBytes(&ipad, length: secretData.length)
        var opad = ipad
        for i in 0..<64 {
            ipad[i] ^= 0x36
            opad[i] ^= 0x5c
        }

        // MD5(opad, MD5(ipad, challenge))
        let r1 = NSMutableData(bytes: opad, length: 64)
        let r2 = NSMutableData(bytes: ipad, length: 64)
        if let challenge = utf8Data(challengeString) { r2.append(challenge as Data) }
        if let inner = r2.smtpMD5() { r1.append(inner as Data) }
        return r1.smtpMD5()?.smtpHex()
    }

    static func hostname() -> String {
        var hostname = [CChar](repeating: 0, count: 128)
        gethostname(&hostname, 127)
        hostname[127] = 0
        var string = String(cString: hostname)
        if !string.contains(".") { string += ".local" }
        return string
    }

    /// A nil line wrote nothing, not even the CRLF, as messaging nil did.
    func writeLine(_ line: String?) {
        guard let line else { return }
        var data = Data(line.utf8)
        data.append(contentsOf: [13, 10])
        writeData(data)
    }

    func _ehlo() {
        writeLine("EHLO " + SMTPConnector.hostname())
        smtpStatus = StatusEHLO
    }

    func _mail() {
        writeLine("MAIL FROM: " + "<\(formatted(from))>")
        smtpStatus = StatusMAIL
    }

    func _auth() throws {
        if let username = client?.username, let password = client?.password {
            if authModes?.contains("CRAM-MD5") == true {
                writeLine("AUTH CRAM-MD5")
                smtpStatus = StatusAUTH
                smtpSubstatus = CramMD5AUTH
            } else if authModes?.contains("PLAIN") == true {
                writeLine("AUTH PLAIN " + formatted(base64UTF8("\(username)\0\(username)\0\(password)")))
                smtpStatus = StatusAUTH
                smtpSubstatus = PlainAUTH
            } else if authModes?.contains("LOGIN") == true {
                writeLine("AUTH LOGIN")
                smtpStatus = StatusAUTH
                smtpSubstatus = LoginAUTH
            } else {
                throw SMTPFailure(.genericException, "The server doesn't allow any authentication techniques supported by this client.")
            }
        } else {
            _mail()
        }
    }

    /// The UTF-8 string of a base64 challenge.
    private static func decodedChallenge(_ message: String?) -> String? {
        // -[NSString initWithData:nil encoding:] gave an empty string.
        guard let data = NSData.smtpData(base64: message) else { return "" }
        return NSString(data: data as Data, encoding: String.Encoding.utf8.rawValue) as String?
    }

    func handleCode(_ code: Int, withMessage message: String?, separator: unichar) throws {
        var message = message

        if code >= 500 {
            throw SMTPFailure(.genericException, "Error \(Int32(truncatingIfNeeded: code)): \(formatted(message))")
        }

        let tlsMode = client?.tlsMode ?? 0
        let hasCredentials = client?.username != nil && client?.password != nil

        switch smtpStatus {
        case InitialStatus:
            switch code {
            case 220:
                if (!isTLS && tlsMode != 0) || hasCredentials {
                    _ehlo()
                    return
                } else {
                    writeLine("HELO " + SMTPConnector.hostname())
                    smtpStatus = StatusHELO
                    return
                }
            default:
                break
            }
        case StatusHELO, StatusEHLO:
            switch code {
            case 250:
                if separator == unichar(UInt8(ascii: "-")) {
                    let split = smtpSplit(message, at: .whitespaces)
                    let name = split.part1
                    let value = split.part2

                    if name == "AUTH" {
                        authModes = value.map { ($0 as NSString).components(separatedBy: .whitespaces) }
                    }
                    if name == "STARTTLS" {
                        canStartTLS = true
                    }
                } else if !isTLS && tlsMode != 0 {
                    if canStartTLS {
                        writeLine("STARTTLS")
                        smtpStatus = StatusSTARTTLS
                    } else if tlsMode == SMTPClientTLSModeTLSOrClose {
                        throw SMTPFailure(.genericException, "Server doesn't support STARTTLS")
                    } else { // TLSIfPossible, not possible...
                        try _auth()
                    }
                } else {
                    try _auth()
                }
                return
            default:
                break
            }
        case StatusSTARTTLS:
            if code == 220 {
                startTLS()
                _ehlo()
                return
            }
        case StatusAUTH:
            switch smtpSubstatus {
            case PlainAUTH:
                switch code {
                case 235:
                    _mail()
                    return
                default:
                    break
                }
            case LoginAUTH:
                switch code {
                case 334:
                    message = SMTPConnector.decodedChallenge(message)
                    if message == "Username:" {
                        writeLine(utf8Data(client?.username)?.smtpBase64())
                        return
                    } else if message == "Password:" {
                        writeLine(utf8Data(client?.password)?.smtpBase64())
                        return
                    }
                    // Falls through to 235, as the C switch did.
                    _mail()
                    return
                case 235:
                    _mail()
                    return
                default:
                    break
                }
            case CramMD5AUTH:
                switch code {
                case 334:
                    message = SMTPConnector.decodedChallenge(message)
                    let temp = "\(formatted(client?.username)) \(formatted(SMTPConnector.cramMD5(message, key: client?.password)))"
                    writeLine(base64UTF8(temp))
                    return
                case 235:
                    _mail()
                    return
                default:
                    break
                }
            default:
                break
            }
        case StatusMAIL:
            switch code {
            case 250:
                for ito in to ?? [] {
                    var to = ito[0]
                    if (to as NSString).rangeOfCharacter(from: CharacterSet(charactersIn: "<>")).location == NSNotFound {
                        to = "<\(to)>"
                    }
                    writeLine("RCPT TO: " + to)
                    rcptToCount += 1
                }
                smtpStatus = StatusRCPT
                return
            default:
                break
            }
        case StatusRCPT:
            switch code {
            case 250:
                rcptToCount -= 1
                if rcptToCount == 0 {
                    writeLine("DATA")
                    smtpStatus = StatusDATA
                }
                return
            default:
                break
            }
        case StatusDATA:
            switch code {
            case 0, 250: // 0: disconnection
                success = true
                writeLine("QUIT")
                smtpStatus = StatusQUIT
                if code == 0 {
                    reset()
                }
                return
            case 354:
                if let fromDescription {
                    writeLine("From: =?UTF-8?B?\(formatted(base64UTF8(fromDescription)))?= <\(formatted(from))>")
                } else {
                    writeLine("From: \(formatted(from))")
                }

                var to = ""
                for ito in self.to ?? [] {
                    if !to.isEmpty {
                        to += ", "
                    }
                    if ito.count > 1 {
                        to += "=?UTF-8?B?\(formatted(base64UTF8(ito[1])))?= <\(ito[0])>"
                    } else {
                        to += ito[0]
                    }
                }
                writeLine("To: \(to)")

                writeLine("Subject: =?UTF-8?B?\(formatted(base64UTF8(subject)))?=")
                writeLine("Mime-Version: 1.0")
                writeLine("Content-Type: text/html; charset=\"UTF-8\"")
                writeLine("Content-Transfer-Encoding: base64")

                if let headers {
                    // In the dictionary's own order, as for-in over it went.
                    for (key, value) in headers {
                        guard let key = key as? String else {
                            throw SMTPFailure(.invalidArgumentException, "-[\(type(of: key)) lowercaseString]: unrecognized selector")
                        }
                        // these headers are specified by the SMTPClient class and cannot be overridden
                        if !["from", "to", "subject", "mime-version", "content-type", "content-transfer-encoding"].contains(key.lowercased()) {
                            writeLine("\(key): \(String(describing: value as AnyObject))")
                        }
                    }
                }

                writeLine("")

                writeLine(base64UTF8(message))

                writeLine(".")

                return
            default:
                break
            }
        case StatusQUIT:
            switch code {
            case 0, 221: // 0: disconnection
                return
            default:
                break
            }
        default:
            break
        }

        throw SMTPFailure(.genericException, "Don't know how to act with status \(Int32(truncatingIfNeeded: smtpStatus)), code \(Int32(truncatingIfNeeded: code))")
    }

    func handleLine(_ line: String?) throws {
        let split = smtpSplit(line, at: CharacterSet(charactersIn: " -"))
        let code = (split.part1 as NSString?)?.integerValue ?? 0

        if code != 0 {
            try handleCode(code, withMessage: split.part2, separator: split.separator)
        } else {
            throw SMTPFailure(.genericException, "Couldn't parse line")
        }
    }

    @objc func _dataTimeoutCallback(_ timer: Timer) {
        if client?.tlsMode ?? 0 != 0 {
            startTLS()
        } else {
            pendingFailure = SMTPFailure(.genericException, "Connection stalled, probably wants TLS handshake, user said no TLS")
        }
    }
}
