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

import CFNetwork
import CoreData
import Foundation

// TODO: NSUserDefaults access for keys @"logWebServer", @"notificationsEmailsSender" and @"lastNotificationsDate" must be replaced with WebPortal properties

/// The plugins that answer -httpResponseForPath:forConnection:, gathered by
/// the first request that needs them, for the life of the application.
private var pluginWithHTTPResponses: NSMutableArray?

private let SessionDicomCStorePortKey = "DicomCStorePort" // NSNumber (int)

// From HTTPConnection.m.
private let WRITE_ERROR_TIMEOUT: TimeInterval = 240
private let HTTP_RESPONSE = 30

/// DLog of N2Debug.h: NSLog in a DEBUG build, otherwise only while N2Debug is
/// active.
private func webPortalConnectionDLog(_ format: String, _ arguments: CVarArg...) {
    #if DEBUG
    withVaList(arguments) { NSLogv(format, $0) }
    #else
    if N2Debug.isActive() { withVaList(arguments) { NSLogv(format, $0) } }
    #endif
}

/// The NSException an HorosObjCException error carries.
private func caughtException(_ error: Error) -> NSException? {
    return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
}

// MARK: - Objective-C messaging

// The former code sent messages to whatever the request's parameters held: a
// value is a string, an NSNull (a name without "=") or an array (a name given
// twice). These helpers answer as those messages did, including the exception
// an object that does not implement the message raised.

/// -length of a parameter value.
private func messageLength(_ object: Any?) -> Int {
    guard let object = object else { return 0 }
    if let string = object as? NSString { return string.length }
    if let data = object as? NSData { return data.length }
    (object as AnyObject as? NSObject)?.doesNotRecognizeSelector(#selector(getter: NSString.length))
    return 0
}

/// -uppercaseString of a parameter value.
private func messageUppercaseString(_ object: Any) -> String? {
    if let string = object as? NSString { return string.uppercased }
    (object as AnyObject as? NSObject)?.doesNotRecognizeSelector(#selector(getter: NSString.uppercased))
    return nil
}

/// -stringByAddingPercentEscapesUsingEncoding: of a parameter name or value,
/// printed by %@ ("(null)" when it answers nil).
private func messagePercentEscaped(_ object: Any) -> String {
    if let string = object as? NSString {
        return string.addingPercentEscapes(using: String.Encoding.utf8.rawValue) ?? "(null)"
    }
    (object as AnyObject as? NSObject)?.doesNotRecognizeSelector(#selector(NSString.addingPercentEscapes(using:)))
    return "(null)"
}

/// -setObject:forKey:, which raised NSInvalidArgumentException on a nil object.
private func setObject(_ object: Any?, forKey key: Any, in dictionary: NSMutableDictionary) {
    dictionary.perform(#selector(NSMutableDictionary.setObject(_:forKey:)), with: object, with: key)
}

/// -addObject:, which raised NSInvalidArgumentException on a nil object.
private func addObject(_ object: Any?, to array: NSMutableArray) {
    array.perform(#selector(NSMutableArray.add(_:)), with: object)
}

/// A connection of the web portal: it reads the request, finds the session and
/// the user, routes the path to the page, the JSON, WADO or file that answers
/// it, and receives uploads.
///
/// Implemented in Swift since #718: the Objective-C name, the selectors and
/// <Horos/WebPortalConnection.h> are those of the former class. The pages
/// themselves are in the (Data) extension. HTTPConnection, the cocoahttpserver
/// superclass, stays Objective-C: the Swift class reads its instance variables
/// through WebPortalConnection+CAPI.m, and overrides the -isAuthenticated and
/// -replyToHTTPRequest its header does not declare.
///
/// The properties were atomic and are not: they are written and read on the
/// connection's own thread; the threads the connection starts only use
/// -portal.
@objc(WebPortalConnection)
public final class WebPortalConnection: HTTPConnection {
    private let sendLock: NSLock
    private var sessionValue: WebPortalSession?

    // POST / PUT support
    private var dataStartIndex: Int32 = 0
    private var multipartData: NSMutableArray?
    private var postHeaderOK = false
    private var postBoundary: NSData?
    private var POSTfilename: String?

    private var independentDicomDatabaseValue: DicomDatabase?
    private var independentDicomDatabaseThread: Thread?

    @objc public private(set) var response: WebPortalResponse!
    @objc public var user: WebPortalUser!
    // GET and POST params. NSDictionary, as FormatParams: and ExtractParams:
    // take and answer: a Swift dictionary would enumerate in another order,
    // and the parameters the pages write back into links with it.
    @objc public var parameters: NSDictionary!
    @objc public var GETParams: String!
    @objc public var requestedPath: String!

    @objc(initWithAsyncSocket:forServer:)
    public override init!(asyncSocket newSocket: AsyncSocket!, for myServer: HTTPServer!) {
        sendLock = NSLock()
        super.init(asyncSocket: newSocket, for: myServer)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        sendLock.lock()
        sendLock.unlock()

        user = nil

        multipartData = nil
        postBoundary = nil
        POSTfilename = nil

        response = nil
        GETParams = nil
        parameters = nil
        sessionValue = nil

        requestedPath = nil

        if independentDicomDatabaseValue?.managedObjectContext.hasChanges == true {
            independentDicomDatabaseValue?.save()
        }
    }

    @objc public var session: WebPortalSession! {
        get {
            if sessionValue == nil {
                self.session = portal?.newSession()
            }
            response?.setSessionId(sessionValue?.sid)
            return sessionValue
        }
        set {
            sessionValue = newValue
        }
    }

    private func requestHeader(_ name: String) -> NSString? {
        guard let request = request() else { return nil }
        return CFHTTPMessageCopyHeaderFieldValue(request, name as CFString)?.takeRetainedValue()
    }

    private func requestURL() -> String? {
        guard let request = request() else { return nil }
        return (CFHTTPMessageCopyRequestURL(request)?.takeRetainedValue() as NSURL?)?.relativeString
    }

    @objc public func requestIsIPhone() -> Bool {
        return requestHeader("User-Agent")?.n2Contains("iPhone") ?? false
    }

    @objc public func requestIsIPad() -> Bool {
        return requestHeader("User-Agent")?.n2Contains("iPad") ?? false
    }

    @objc public func requestIsIPod() -> Bool {
        return requestHeader("User-Agent")?.n2Contains("iPod") ?? false
    }

    @objc public func requestIsIOS() -> Bool {
        return requestHeader("User-Agent")?.n2Contains("like Mac OS X") ?? false
    }

    @objc public func requestIsMacOS() -> Bool {
        return requestHeader("User-Agent")?.n2Contains("Mac OS X") ?? false
    }

    @objc(managedObjectContextDidSaveNotification:)
    public func managedObjectContextDidSaveNotification(_ n: NSNotification!) {
        let moc = n?.object as AnyObject?
        let context = independentDicomDatabaseValue?.managedObjectContext

        if context === moc {
            return
        }

        if context?.persistentStoreCoordinator !== (moc as? NSManagedObjectContext)?.persistentStoreCoordinator {
            return
        }

        do {
            try HorosObjCException.perform {
                if let context = context, let thread = self.independentDicomDatabaseThread {
                    context.perform(#selector(NSManagedObjectContext.mergeChanges(fromContextDidSave:)),
                                    on: thread, with: n, waitUntilDone: false)
                }
            }
        } catch {
            if let exception = caughtException(error) {
                _N2LogExceptionImpl(exception, false, "-[WebPortalConnection managedObjectContextDidSaveNotification:]")
            }
        }
    }

    @objc public var independentDicomDatabase: DicomDatabase! {
        if Thread.isMainThread {
            return portal?.dicomDatabase
        }

        if let database = independentDicomDatabaseValue {
            if Thread.current !== independentDicomDatabaseThread {
                WebPortalConnectionLogStackTrace("***************** [NSThread currentThread] != _independentDicomDatabaseThread")
            }

            return database
        }

        NotificationCenter.default.removeObserver(self, name: .NSManagedObjectContextDidSave, object: nil)

        independentDicomDatabaseValue = portal?.dicomDatabase?.independentDatabase() as? DicomDatabase

        independentDicomDatabaseThread = Thread.current

        NotificationCenter.default.addObserver(self, selector: #selector(managedObjectContextDidSaveNotification(_:)),
                                               name: .NSManagedObjectContextDidSave, object: nil)

        return independentDicomDatabaseValue
    }

    @objc public var portal: WebPortal! {
        return server?.portal
    }

    @objc public var server: WebPortalServer! {
        // The former cast: the server is the WebPortalServer that made the connection.
        guard let server = webPortalConnectionServer() else { return nil }
        return Unmanaged<WebPortalServer>.fromOpaque(Unmanaged.passUnretained(server).toOpaque()).takeUnretainedValue()
    }

    @objc public var asyncSocket: AsyncSocket! {
        return webPortalConnectionAsyncSocket()
    }

    @objc public func request() -> CFHTTPMessage! {
        return webPortalConnectionRequest()
    }

    @objc public func portalURL() -> String! {
        var requestedHost = requestHeader("Host")
        let usesSSL = portal?.usesSSL ?? false
        if !usesSSL, let host = requestedHost, host.hasSuffix(":80") {
            requestedHost = host.substring(with: NSRange(location: 0, length: host.length - 3)) as NSString
        }
        if usesSSL, let host = requestedHost, host.hasSuffix(":443") {
            requestedHost = host.substring(with: NSRange(location: 0, length: host.length - 4)) as NSString
        }

        if let requestedHost = requestedHost {
            return String(format: "%@://%@", usesSSL ? "https" : "http", requestedHost)
        } else {
            return portal?.url()
        }
    }

    @objc public func guessDicomCStorePort() -> Int32 {
        webPortalConnectionDLog("Trying to guess DICOM C-Store Port...")

        for case let node as NSDictionary in DCMNetServiceDelegate.dicomServersListSendOnly(true, qrOnly: false) ?? [] {
            // NSString *dicomNodeAddress = NotNil([node objectForKey:@"Address"]);
            let port = node.object(forKey: "Port")
            let dicomNodePort = (port as? NSNumber)?.int32Value ?? (port as? NSString)?.intValue ?? 0

            var service = sockaddr_in()
            let hostName = (node.value(forKey: "Address") as? NSString)?.utf8String

            service.sin_family = sa_family_t(AF_INET)

            if let hostName = hostName {
                if isalpha(Int32(hostName[0])) != 0 {
                    if let hp = gethostbyname(hostName), let address = hp.pointee.h_addr_list[0] {
                        withUnsafeMutableBytes(of: &service.sin_addr) {
                            $0.copyMemory(from: UnsafeRawBufferPointer(start: address, count: min(Int(hp.pointee.h_length), $0.count)))
                        }
                    } else {
                        service.sin_addr.s_addr = inet_addr(hostName)
                    }
                } else {
                    service.sin_addr.s_addr = inet_addr(hostName)
                }

                var buffer = [CChar](repeating: 0, count: 256)
                if inet_ntop(AF_INET, &service.sin_addr, &buffer, socklen_t(buffer.count)) != nil {
                    // TODO: this may fail because of comparaisons between ipv6 and ipv4 addys
                    if let connectedHost = asyncSocket?.connectedHost(),
                       NSString(utf8String: buffer)?.isEqual(to: connectedHost) == true {
                        webPortalConnectionDLog("\tFound! %@:%d", connectedHost, dicomNodePort)
                        return dicomNodePort
                    }
                }
            }
        }

        webPortalConnectionDLog("\tNot found, will use 11112")
        return 11112
    }

    @objc public func dicomCStorePortString() -> String! {
        var n = self.session.object(forKey: SessionDicomCStorePortKey) as AnyObject?
        if n == nil {
            n = NSNumber(value: guessDicomCStorePort())
            self.session.setObject(n, forKey: SessionDicomCStorePortKey)
        }
        return (n as? NSNumber)?.stringValue
    }

    @objc(isPasswordProtected:)
    public override func isPasswordProtected(_ path: String!) -> Bool {
        let p = path as NSString?
        if p?.hasPrefix("/wado") == true
            || p?.hasPrefix("/images/") == true
            || p?.isEqual(to: "/") == true
            || p?.hasSuffix(".js") == true
            || p?.hasSuffix(".css") == true
            || p?.hasPrefix("/password_forgotten") == true
            || p?.hasPrefix("/index") == true
            || p?.hasPrefix("/weasis/") == true
            || p?.isEqual(to: "/favicon.ico") == true
            || p?.isEqual(to: "/testdbalive") == true {
            return false
        }

        let selector = NSSelectorFromString("isPasswordProtected:forConnection:")
        for case let (key, _) in PluginManager.plugins() ?? NSMutableDictionary() {
            let plugin = PluginManager.plugins()?.object(forKey: key) as? NSObject

            if plugin?.responds(to: selector) == true {
                let v = plugin?.perform(selector, with: path, with: self)?.takeUnretainedValue()

                if let v = v {
                    return (v as? NSNumber)?.boolValue ?? (v as? NSString)?.boolValue ?? false
                }
            }
        }

        return portal?.authenticationRequired ?? false
    }

    public override func useDigestAccessAuthentication() -> Bool {
        return false
    }

    // Overrides HTTPConnection's method
    public override func isSecureServer() -> Bool {
        return portal?.usesSSL ?? false
    }

    /*
     * Overrides HTTPConnection's method
     *
     * This method is expected to return an array appropriate for use in kCFStreamSSLCertificates SSL Settings.
     * It should be an array of SecCertificateRefs except for the first element in the array, which is a SecIdentityRef.
     */
    public override func sslIdentityAndCertificates() -> [Any]! {
        //	NSArray *result = [DDKeychain SSLIdentityAndCertificates];
        let keyUse = Int32(bitPattern: UInt32(CSSM_KEYUSE_ANY))
        var identity = DDKeychain.keychainAccessPreferredIdentity(forName: "org.horosproject.horoswebserver", keyUse: keyUse)?.takeRetainedValue()
        if identity == nil {
            DDKeychain.createNewIdentity()
            identity = DDKeychain.keychainAccessPreferredIdentity(forName: "org.horosproject.horoswebserver", keyUse: keyUse)?.takeRetainedValue()
        }

        // +arrayWithObject: raised NSInvalidArgumentException on a nil identity.
        let array = NSMutableArray()
        addObject(identity, to: array)

        // We add the chain of certificates that validates the chosen certificate.
        // This way we don't have to install the intermediate certificates on the clients systems. Yay!
        let certificateChain = DDKeychain.keychainAccessCertificateChain(for: identity)
        array.addObjects(from: certificateChain ?? [])

        return NSArray(array: array) as? [Any]
    }

    @objc(FormatParams:)
    public class func FormatParams(_ dict: NSDictionary!) -> String! {
        let str = NSMutableString()
        for case let (key, value) in dict ?? NSDictionary() {
            if let values = value as? NSArray {
                for v2 in values {
                    str.append("\(str.length != 0 ? "&" : "")\(messagePercentEscaped(key))=\(messagePercentEscaped(v2))")
                }
            } else {
                str.append("\(str.length != 0 ? "&" : "")\(messagePercentEscaped(key))=\(messagePercentEscaped(value))")
            }
        }
        return str as String
    }

    @objc(ExtractParams:)
    public class func ExtractParams(_ paramsString: String!) -> NSDictionary! {
        guard let paramsString = paramsString as NSString?, paramsString.length != 0 else {
            return NSDictionary()
        }

        let paramsArray = paramsString.components(separatedBy: "&")
        let params = NSMutableDictionary(capacity: paramsArray.count)

        for param in paramsArray {
            let paramArray = (param as NSString).components(separatedBy: "=")

            let paramName = (paramArray[0] as NSString).replacingOccurrences(of: "+", with: " ")
            guard let name = (paramName as NSString).replacingPercentEscapes(using: String.Encoding.utf8.rawValue),
                  (name as NSString).length != 0 else {
                continue
            }

            let paramValue: Any? = paramArray.count > 1
                ? ((paramArray[1] as NSString).replacingOccurrences(of: "+", with: " ") as NSString).replacingPercentEscapes(using: String.Encoding.utf8.rawValue)
                : NSNull()

            var prevVal = params.object(forKey: name)
            if let previous = prevVal, !(previous is NSMutableArray) {
                let values = NSMutableArray(object: previous)
                params.setObject(values, forKey: name as NSString)
                prevVal = values
            }

            // A value whose escapes do not decode is nil, and raised
            // NSInvalidArgumentException here.
            if let values = prevVal as? NSMutableArray {
                addObject(paramValue, to: values)
            } else {
                setObject(paramValue, forKey: name, in: params)
            }
        }

        return params
    }

    @objc(alive:)
    public func alive(_ sender: Any!) {
        portal?.dicomDatabase?.managedObjectContext.lock() // Can we obtain a lock on the main db?
        portal?.dicomDatabase?.managedObjectContext.unlock()
    }

    public override func httpResponse(forMethod method: String!, uri path: String!) -> (NSObjectProtocol & HTTPResponse)! {
        let url = requestURL()

        // parse the URL to find the parameters (if any)
        let urlComponenents = (url as NSString?)?.components(separatedBy: "?")

        if urlComponenents?.count == 2 {
            self.GETParams = urlComponenents?.last
        } else {
            self.GETParams = nil
        }

        let params = NSMutableDictionary()
        // GET params
        // -addEntriesFromDictionary: of the dictionary itself, so the entries go in
        // in the same order, and the parameters enumerate in the same order.
        params.perform(#selector(NSMutableDictionary.addEntries(from:)), with: WebPortalConnection.ExtractParams(self.GETParams))
        // POST params
        if (method as NSString?)?.isEqual(to: "POST") == true, multipartData?.count == 1 {
            let data = multipartData?.lastObject as? NSData
            let POSTParams = data.flatMap { NSString(bytes: $0.bytes, length: $0.length, encoding: String.Encoding.utf8.rawValue) }
            params.perform(#selector(NSMutableDictionary.addEntries(from:)), with: WebPortalConnection.ExtractParams(POSTParams as String?))
        }
        self.parameters = params
        if let parameters = parameters {
            response?.tokens.setObject(parameters, forKey: "Request" as NSString)
        }

        // find the name of the requested file
        guard let requestedPath = HorosWebRequestPath(urlComponenents?.first) else {
            response?.setStatusCode(404)
            return nil
        }

        self.requestedPath = requestedPath

        // The path as it is now: a plugin or a page may change it.
        func currentPath() -> NSString? {
            return self.requestedPath as NSString?
        }

        let ext = currentPath()?.pathExtension as NSString?
        if ext?.compare("jar", options: [.caseInsensitive, .literal]) == .orderedSame {
            response?.mimeType = "application/java-archive"
        }
        if ext?.compare("swf", options: [.caseInsensitive, .literal]) == .orderedSame {
            response?.mimeType = "application/x-shockwave-flash"
        }
        if ext?.compare("css", options: [.caseInsensitive, .literal]) == .orderedSame {
            response?.mimeType = "text/css"
        }
        if ext?.compare("js", options: [.caseInsensitive, .literal]) == .orderedSame {
            response?.mimeType = "application/javascript"
        }

        //    [response.httpHeaders setObject: @"no-cache" forKey: @"Cache-Control"];

        if currentPath()?.hasPrefix("/weasis/") == true {
            var assigned = false
            for dir in Horos.weasisCustomizationPaths() {
                let path = HorosWebFilePath(dir, currentPath()?.substring(from: 8))
                var isDir: ObjCBool = false
                if let path = path, FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
                    let data = NSData(contentsOfFile: path)
                    response?.data = data as Data?
                    if data != nil {
                        assigned = true
                        break
                    }
                }
            }
            if !assigned {
                // The bundled distribution contains a weasis/ subdirectory.
                let path = HorosWebFilePath(AppController.shared()?.weasisBasePath(), self.requestedPath)
                if let path = path {
                    response?.data = NSData(contentsOfFile: path) as Data?
                }
            }
            if response?.data == nil {
                response?.setStatusCode(404)
            }
        } else if currentPath()?.range(of: ".pvt.").length ?? 0 != 0 {
            response?.setStatusCode(404)
        } else {
            var handledByPlugin = false
            do {
                try HorosObjCException.perform {
                    // Maybe a plugin has an answer ?
                    let selector = NSSelectorFromString("httpResponseForPath:forConnection:")
                    if pluginWithHTTPResponses == nil {
                        let plugins = NSMutableArray()
                        pluginWithHTTPResponses = plugins
                        for case let (key, _) in PluginManager.plugins() ?? NSMutableDictionary() {
                            let plugin = PluginManager.plugins()?.object(forKey: key) as? NSObject

                            if plugin?.responds(to: selector) == true {
                                plugins.add(plugin as Any)
                            }
                        }
                    }

                    for case let plugin as NSObject in pluginWithHTTPResponses ?? [] {
                        let data = plugin.perform(selector, with: self.requestedPath, with: self)?.takeUnretainedValue() as? NSData

                        if let data = data, data.length != 0 {
                            self.response?.data = data as Data
                            handledByPlugin = true
                            break
                        }
                    }
                }
            } catch {
                if let exception = caughtException(error) {
                    _N2LogExceptionImpl(exception, false, "-[WebPortalConnection httpResponseForMethod:URI:]")
                }
            }

            if !handledByPlugin {
                do {
                    try HorosObjCException.perform {
                        self.route(currentPath)

                        if (self.response?.data?.count ?? 0) == 0 && (self.response?.statusCode() ?? 0) == 0 {
                            self.response?.setStatusCode(404)
                        }
                    }
                } catch {
                    response?.setStatusCode(500)
                    NSLog("Error: [WebPortalConnection httpResponseForMethod:URI:] %@", caughtException(error) ?? (error as NSError))
                }
            }
        }

        if let response = response, response.data != nil, response.statusCode() == 0 {
            return response // [[[WebPortalResponse alloc] initWithData:data mime:dataMime sessionId:session.sid] autorelease];*/
        } else {
            return nil
        }
    }

    /// The pages, in the former order; each test reads the path again.
    private func route(_ currentPath: () -> NSString?) {
        func equals(_ s: String) -> Bool { return currentPath()?.isEqual(to: s) == true }
        func prefix(_ s: String) -> Bool { return currentPath()?.hasPrefix(s) == true }
        func suffix(_ s: String) -> Bool { return currentPath()?.hasSuffix(s) == true }

        if equals("/") || prefix("/index") {
            processIndexHtml()
        } else if equals("/main") {
            processMainHtml()
        } else if equals("/logs") {
            processLogsListHtml()
        } else if equals("/studyList") {
            processStudyListHtml()
        } else if equals("/studyList.json") {
            processStudyListJson()
        } else if equals("/study") {
            processStudyHtml()
        } else if equals("/wado") {
            processWado()
        } else if equals("/thumbnail") {
            processThumbnail()
        } else if equals("/series.pdf") {
            processSeriesPdf()
        } else if equals("/series") {
            processSeriesHtml()
        } else if equals("/keyroisimages") {
            processKeyROIsImagesHtml()
        } else if equals("/series.json") {
            processSeriesJson()
        } else if prefix("/report") {
            processReport()
        } else if suffix(".zip") || suffix(".osirixzip") {
            processZip()
        } else if prefix("/image.") {
            processImage()
        } else if prefix("/imageAsScreenCapture.") {
            processImageAsScreenCapture(true)
        } else if equals("/movie.mov") || equals("/movie.m4v") || equals("/movie.mp4") || equals("/movie.swf") {
            processMovie()
        } else if equals("/password_forgotten") {
            processPasswordForgottenHtml()
        } else if equals("/account") {
            processAccountHtml()
        } else if equals("/albums.json") {
            processAlbumsJson()
        } else if equals("/seriesList.json") {
            processSeriesListJson()
        } else if suffix("weasis.jnlp") {
            processWeasisJnlp()
        } else if equals("/weasis.xml") {
            processWeasisXml()
        } else if equals("/admin/") || equals("/admin/index") {
            processAdminIndexHtml()
        } else if equals("/admin/user") {
            processAdminUserHtml()
        } else if equals("/quitOsiriX") && (user?.isAdmin?.boolValue ?? false) {
            exit(0)
        } else if equals("/testdbalive") {
            portal?.dicomDatabase?.managedObjectContext.lock() // Can we obtain a lock on the main db?
            portal?.dicomDatabase?.managedObjectContext.unlock()

            portal?.dicomDatabase?.managedObjectContext.persistentStoreCoordinator?.lock() // Can we obtain a lock on the main db?
            portal?.dicomDatabase?.managedObjectContext.persistentStoreCoordinator?.unlock()

            portal?.database?.managedObjectContext.lock()
            _ = portal?.database?.objects(forEntity: portal?.database?.userEntity(),
                                          predicate: NSPredicate(format: "name == %@", "test" as NSString))
            portal?.database?.managedObjectContext.unlock()

            portal?.database?.managedObjectContext.persistentStoreCoordinator?.lock()
            portal?.database?.managedObjectContext.persistentStoreCoordinator?.unlock()

            performSelector(onMainThread: #selector(alive(_:)), with: self, waitUntilDone: true)

            response?.setDataWith("Test DB Alive succeeded")
            response?.mimeType = "text/html"
        } else {
            response?.data = portal?.data(forPath: self.requestedPath)
        }
    }

    public override func supportsMethod(_ method: String!, atPath relativePath: String!) -> Bool {
        if (method as NSString?)?.isEqual(to: "POST") == true {
            return true
        }
        return super.supportsMethod(method, atPath: relativePath)
    }

    /// Where uploads are written and unzipped: the user's own temporary folder.
    /// They went to /tmp under fixed names, which another user could put in
    /// place first (#769).
    static func uploadFolder() -> String {
        let path = (FileManager.default.tmpDirPath() as NSString).appendingPathComponent("WebPortal Uploads")
        FileManager.default.confirmDirectory(atPath: path)
        return path
    }

    @objc public func resetPOST() {
        dataStartIndex = 0
        multipartData = NSMutableArray()
        postHeaderOK = false

        postBoundary = nil

        POSTfilename = nil

        return
    }

    // Integer arithmetic of the former method: an int compared with and
    // subtracted from NSUInteger lengths, as C converts them.
    @objc(checkEOF:range:)
    public func checkEOF(_ postDataChunk: NSData!, range r: UnsafeMutablePointer<NSRange>!) -> Bool {
        let chunk = postDataChunk
        let length = UInt(chunk?.length ?? 0)
        //	BOOL eof = NO;
        let l = Int32(truncatingIfNeeded: postBoundary?.length ?? 0)

        let CHECKLASTPART = 4096

        // The last 4096 bytes, but not before the file's data: in a short chunk that
        // would find the opening boundary. The former unsigned start, length - 4096,
        // wrapped around for a shorter chunk and the search never ran: an upload
        // that fitted in one chunk never ended (#769).
        var x = max(r.pointee.location, Int(length) - CHECKLASTPART)
        while x < Int(length) - Int(l) {
            let searchRange = NSRange(location: x, length: Int(l))

            if let chunk = chunk, let boundary = postBoundary, chunk.subdata(with: searchRange) == boundary as Data {
                let consumed = (length &- UInt(x)) &+ 2 // -2 = 0x0A0D
                r.pointee.length = Int(bitPattern: UInt(bitPattern: r.pointee.length) &- consumed)
                return true
            }
            x += 1
        }
        return false
    }

    @objc public func closeFileHandleAndClean() {
        var file: String?
        //	NSString *root = [[BrowserController currentBrowser] INCOMINGPATH];
        let filesArray = NSMutableArray()

        (multipartData?.lastObject as? FileHandle)?.closeFile()

        // A folder of this upload's own, in the user's temporary folder: the former
        // /tmp/osirixUnzippedFolder was shared by every upload and could be put in
        // place by another user (#769).
        let unzipFolder = (WebPortalConnection.uploadFolder() as NSString).appendingPathComponent("Unzipped " + UUID().uuidString)

        let fileExtension = (POSTfilename as NSString?)?.pathExtension as NSString?
        if fileExtension?.isEqual(to: "zip") == true || fileExtension?.isEqual(to: "osirixzip") == true {
            let t = Process()

            do {
                try HorosObjCException.perform {
                    t.launchPath = "/usr/bin/unzip"
                    // +arrayWithObjects: ended at a nil file name.
                    var args = ["-o", "-d", unzipFolder]
                    if let name = self.POSTfilename { args.append(name) }
                    t.arguments = args
                    t.launch()
                    while t.isRunning {
                        Thread.sleep(forTimeInterval: 0.1)
                    }

                    //[aTask waitUntilExit];		// <- This is VERY DANGEROUS : the main runloop is continuing...
                }
            } catch {
                NSLog("***** unzipFile exception: %@", caughtException(error) ?? (error as NSError))
            }

            if let name = POSTfilename {
                try? FileManager.default.removeItem(atPath: name)
            }

            let rootDir = unzipFolder as NSString
            var isDirectory: ObjCBool = false

            for file in (try? FileManager.default.subpathsOfDirectory(atPath: rootDir as String)) ?? [] {
                let name = file as NSString
                // The Finder's metadata: the __MACOSX folder and its ._ files (#769).
                if !name.hasSuffix(".DS_Store")
                    && !(name.lastPathComponent as NSString).isEqual(to: "DICOMDIR")
                    && !name.pathComponents.contains("__MACOSX")
                    && !(name.lastPathComponent as NSString).hasPrefix("._")
                    && FileManager.default.fileExists(atPath: rootDir.appendingPathComponent(file), isDirectory: &isDirectory)
                    && !isDirectory.boolValue {
                    filesArray.add(rootDir.appendingPathComponent(file))
                }
            }
        } else {
            addObject(POSTfilename, to: filesArray)
        }

        var previousPatientUID: String?
        var previousStudyInstanceUID: String?

        fillSessionAndUserVariables()

        let idatabase = self.independentDicomDatabase
        let filesAccumulator = NSMutableArray()
        // We want to find this file after db insert: get studyInstanceUID, patientUID and instanceSOPUID
        for case let oFile as String in filesArray {
            let f = DicomFile(oFile, dicomOnly: true)

            if let f = f {
                file = BrowserController.currentBrowser()?.database?.uniquePathForNewDataFile(withExtension: "dcm")

                if let file = file {
                    try? FileManager.default.moveItem(atPath: oFile, toPath: file)
                }

                addObject(file, to: filesAccumulator)

                let studyInstanceUID = f.element(forKey: "studyID") as? String, patientUID = f.element(forKey: "patientUID") as? String

                // -isEqualToString: of nil, or with a nil argument, answered NO.
                var sameStudy = false
                if let studyInstanceUID = studyInstanceUID as NSString?, let previous = previousStudyInstanceUID {
                    sameStudy = studyInstanceUID.isEqual(to: previous)
                }

                if !sameStudy || messageCompare(patientUID, previousPatientUID) != .orderedSame {
                    _ = idatabase?.addFiles(atPaths: filesAccumulator as? [Any], postNotifications: true, dicomOnly: true,
                                            rereadExistingItems: true, generatedByOsiriX: true, importedFiles: true, returnArray: false)

                    filesAccumulator.removeAllObjects()

                    previousStudyInstanceUID = studyInstanceUID
                    previousPatientUID = patientUID

                    if let studyInstanceUID = studyInstanceUID, let patientUID = patientUID {
                        do {
                            try HorosObjCException.perform {
                                self.addUploadedStudy(studyInstanceUID: studyInstanceUID, patientUID: patientUID, database: idatabase)
                            }
                        } catch {
                            WebPortalConnectionLogStackTrace(String(format: "********* WebPortalConnection closeFileHandleAndClean exception : %@",
                                                                    caughtException(error) ?? (error as NSError)))
                        }
                        ///
                    } else {
                        NSLog("****** studyInstanceUID && patientUID == nil upload POST")
                    }
                }
            }
        }

        _ = idatabase?.addFiles(atPaths: filesAccumulator as? [Any], postNotifications: true, dicomOnly: true,
                                rereadExistingItems: true, generatedByOsiriX: true, importedFiles: true, returnArray: false)

        // What was not imported: the unzipped folder, and an upload that is not
        // DICOM, which used to stay in the temporary folder (#769).
        try? FileManager.default.removeItem(atPath: unzipFolder)
        if let name = POSTfilename {
            try? FileManager.default.removeItem(atPath: name)
        }

        multipartData = nil
        postBoundary = nil
        POSTfilename = nil
    }

    /// -compare:options: of the patient UIDs: a message to nil answers
    /// NSOrderedSame, and a nil argument NSOrderedDescending.
    private func messageCompare(_ string: String?, _ other: String?) -> ComparisonResult {
        guard let string = string as NSString? else { return .orderedSame }
        guard let other = other else { return .orderedDescending }
        return string.compare(other, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])
    }

    /// The @try part of -closeFileHandleAndClean for one study just received.
    private func addUploadedStudy(studyInstanceUID: String, patientUID: String, database idatabase: DicomDatabase?) {
        let dbRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Study")
        dbRequest.predicate = NSPredicate(format: "(patientUID BEGINSWITH[cd] %@) AND (studyInstanceUID == %@)", patientUID as NSString, studyInstanceUID as NSString)

        let studies = try? idatabase?.managedObjectContext.fetch(dbRequest)

        if (studies?.count ?? 0) == 0 {
            NSLog("****** [studies count == 0] cannot find the file{s} we just received... upload POST: %@ %@", patientUID as NSString, studyInstanceUID as NSString)
        }

        // Add study to specific study list for this user
        if user?.uploadDICOMAddToSpecificStudies?.boolValue ?? false {
            let studies = idatabase?.objects(forEntity: idatabase?.studyEntity(),
                                             predicate: NSPredicate(format: "(patientUID BEGINSWITH[cd] %@) AND (studyInstanceUID == %@)", patientUID as NSString, studyInstanceUID as NSString))

            if (studies?.count ?? 0) == 0 {
                NSLog("****** [studies count == 0] cannot find the file{s} we just received... upload POST: %@ %@", patientUID as NSString, studyInstanceUID as NSString)
            }

            // Add study to specific study list for this user

            var studiesArrayStudyInstanceUID = ((user?.studies as NSSet?)?.allObjects as NSArray?)?.value(forKey: "studyInstanceUID") as? NSArray
            var studiesArrayPatientUID = ((user?.studies as NSSet?)?.allObjects as NSArray?)?.value(forKey: "patientUID") as? NSArray

            for case var study as NSManagedObject in studies ?? [] {
                if (study.value(forKey: "type") as? NSString)?.isEqual(to: "Series") == true {
                    study = study.value(forKey: "study") as! NSManagedObject
                }

                let studyUID = study.value(forKey: "studyInstanceUID")
                let studyPatientUID = study.value(forKey: "patientUID")
                let uidIndex = studyUID.map { studiesArrayStudyInstanceUID?.index(of: $0) ?? NSNotFound } ?? NSNotFound
                let patientIndex = studiesArrayPatientUID?.indexOfObject(passingTest: { obj, _, _ in
                    guard let obj = obj as? NSString else {
                        (obj as AnyObject as? NSObject)?.doesNotRecognizeSelector(#selector(NSString.compare(_:options:)))
                        return false
                    }
                    return self.messageCompare(obj as String, studyPatientUID as? String) == .orderedSame
                }) ?? NSNotFound
                if uidIndex == NSNotFound || patientIndex == NSNotFound {
                    // +insertNewObjectForEntityForName:inManagedObjectContext: raised on a nil context.
                    let studyLink = (NSEntityDescription.self as AnyObject)
                        .perform(#selector(NSEntityDescription.insertNewObject(forEntityName:into:)), with: "Study", with: user?.managedObjectContext)?
                        .takeUnretainedValue() as! NSManagedObject

                    studyLink.setValue((studyUID as? NSObject)?.copy(), forKey: "studyInstanceUID")
                    studyLink.setValue((studyPatientUID as? NSObject)?.copy(), forKey: "patientUID")
                    studyLink.setValue(Date(timeIntervalSinceReferenceDate: UserDefaults.standard.double(forKey: "lastNotificationsDate")), forKey: "dateAdded")

                    studyLink.setValue(user, forKey: "user")

                    do {
                        try HorosObjCException.perform {
                            try? self.user.managedObjectContext?.save()
                        }
                    } catch {
                        NSLog("*********** [user.managedObjectContext save:NULL]")
                    }

                    studiesArrayStudyInstanceUID = ((user?.studies as NSSet?)?.allObjects as NSArray?)?.value(forKey: "studyInstanceUID") as? NSArray
                    studiesArrayPatientUID = ((user?.studies as NSSet?)?.allObjects as NSArray?)?.value(forKey: "patientUID") as? NSArray

                    portal?.updateLogEntry(forStudy: study, withMessage: "Add Study to User", forUser: user?.name, ip: nil)
                }
            }
        }

        if user?.name != nil && UserDefaults.standard.bool(forKey: "WebServerTagUploadedStudiesWithUsername") {
            for case let study as NSManagedObject in studies ?? [] {
                var comment = study.value(forKey: "comment") as? String

                if comment == nil {
                    comment = String()
                }

                comment = comment! + NSLocalizedString("Uploaded by ", comment: "")
                comment = comment! + user.name

                study.setValue(comment, forKey: "comment")
            }
        }
    }

    // A request body the portal cannot parse must not end the connection thread:
    // only four serve the portal, so four such requests would stop it (#757).
    public override func processDataChunk(_ postDataChunk: Data!) {
        do {
            try HorosObjCException.perform {
                self.processDataChunkUnguarded(postDataChunk)
            }
        } catch {
            if let exception = caughtException(error) {
                _N2LogExceptionImpl(exception, false, "-[WebPortalConnection processDataChunk:]")
            }
            resetPOST()
        }
    }

    private func processDataChunkUnguarded(_ postDataChunk: Data!) {
        // Override me to do something useful with a POST.
        // If the post is small, such as a simple form, you may want to simply append the data to the request.
        // If the post is big, such as a file upload, you may want to store the file to disk.
        //
        // Remember: In order to support LARGE POST uploads, the data is read in chunks.
        // This prevents a 50 MB upload from being stored in RAM.
        // The size of the chunks are limited by the POST_CHUNKSIZE definition.
        // Therefore, this method may be called multiple times for the same POST request.

        //NSLog(@"processPostDataChunk");

        let chunk = postDataChunk as NSData?
        let chunkLength = UInt(chunk?.length ?? 0)

        if !postHeaderOK {
            if multipartData == nil {
                resetPOST()
            }

            var startedUpload = false
            var separatorBytes: UInt16 = 0x0A0D
            let separatorData = NSData(bytes: &separatorBytes, length: 2)

            let l = Int32(truncatingIfNeeded: separatorData.length)

            // Signed: a body shorter than the separator (0 or 1 byte) used to wrap
            // the unsigned difference around and read past the chunk.
            var i: Int32 = 0
            while Int(i) < Int(chunkLength) - Int(l) {
                defer { i = i &+ 1 }
                let searchRange = NSRange(location: Int(i), length: Int(l))

                // If MacOS 10.6 : we should use - (NSRange)rangeOfData:(NSData *)dataToFind options:(NSDataSearchOptions)mask range:(NSRange)searchRange

                if chunk?.subdata(with: searchRange) == separatorData as Data {
                    let newDataRange = NSRange(location: Int(dataStartIndex), length: Int(bitPattern: UInt(bitPattern: Int(i &- dataStartIndex))))
                    if i >= dataStartIndex {
                        dataStartIndex = i &+ l
                        i = i &+ (l &- 1)
                        let newData = chunk?.subdata(with: newDataRange)

                        if let newData = newData, newData.count != 0 {
                            multipartData?.add(newData as NSData)
                        } else {
                            postHeaderOK = true

                            let info = multipartData?.object(at: 1) as? NSData
                            let postInfo = info.flatMap { NSString(bytes: $0.bytes, length: $0.length, encoding: String.Encoding.utf8.rawValue) }

                            postBoundary = (multipartData?.object(at: 0) as? NSData)?.copy() as? NSData
                            startedUpload = true

                            do {
                                try HorosObjCException.perform {
                                    self.createUploadFile(postInfo: postInfo, chunk: chunk, chunkLength: chunkLength)
                                }
                            } catch {
                                NSLog("******* POST processDataChunk : %@", caughtException(error) ?? (error as NSError))
                            }

                            break
                        }
                    }
                }
            }

            // For other POST, like account update. Not for an upload that began in
            // this chunk: replacing the list dropped its file handle (#769).

            if chunkLength < 4096 && !startedUpload {
                multipartData = NSMutableArray()
                multipartData?.add(chunk as Any)
            }
        } else {
            var fileDataRange = NSRange(location: 0, length: Int(chunkLength))

            let eof = checkEOF(chunk, range: &fileDataRange)

            do {
                try HorosObjCException.perform {
                    if let handle = self.multipartData?.lastObject as? FileHandle {
                        if let chunk = chunk {
                            handle.write(chunk.subdata(with: fileDataRange))
                        }
                    } else {
                        NSLog("******* we should not be here - processDataChunk Error")
                        self.resetPOST()
                    }
                }
            } catch {
                NSLog("******* writeData processDataChunk exception: %@", caughtException(error) ?? (error as NSError))
                resetPOST()
            }

            if eof {
                closeFileHandleAndClean()
                resetPOST()
            }
        }
    }

    /// The @try part of -processDataChunk: once the multipart header is read:
    /// the upload's file in /tmp.
    private func createUploadFile(postInfo: NSString?, chunk: NSData?, chunkLength: UInt) {
        // A message to nil answered a zeroed range.
        let filenameRange = postInfo?.range(of: "filename") ?? NSRange(location: 0, length: 0)
        var fileExtension: String?

        if filenameRange.location != NSNotFound {
            let filename = postInfo?.substring(from: filenameRange.location + filenameRange.length) as NSString?

            let components = filename?.components(separatedBy: "\"")

            if (components?.count ?? 0) >= 3 {
                fileExtension = (components![1] as NSString).pathExtension
            }

            let root = WebPortalConnection.uploadFolder() as NSString

            var inc: Int32 = 1

            repeat {
                let path = root.appendingPathComponent(String(format: "WebPortal Upload %d", inc)) as NSString
                inc += 1
                // -stringByAppendingPathExtension: raised NSInvalidArgumentException on a nil extension.
                POSTfilename = path.perform(#selector(NSString.appendingPathExtension(_:)), with: fileExtension)?.takeUnretainedValue() as? String
            } while POSTfilename.map { FileManager.default.fileExists(atPath: $0) } ?? false

            var fileDataRange = NSRange(location: Int(dataStartIndex),
                                        length: Int(bitPattern: chunkLength &- UInt(bitPattern: Int(dataStartIndex))))

            let eof = checkEOF(chunk, range: &fileDataRange)

            let contents = chunk?.subdata(with: fileDataRange)
            if let name = POSTfilename {
                FileManager.default.createFile(atPath: name, contents: contents, attributes: nil)
            }
            let file = POSTfilename.flatMap { FileHandle(forUpdatingAtPath: $0) }

            if let file = file {
                file.seekToEndOfFile()
                multipartData?.add(file)
            } else {
                NSLog("***** Failed to create file - processDataChunk : %@", POSTfilename ?? "(null)")
            }

            if eof {
                // Finished in one short? No multiparts finally...
                closeFileHandleAndClean()
                resetPOST()
            }
        }
    }

    // MARK: Session, custom authentication

    public override func onSocketWillConnect(_ sock: AsyncSocket!) -> Bool {
        resetPOST()

        return super.onSocketWillConnect(sock)
    }

    @objc public func fillSessionAndUserVariables() {
        let method = request().flatMap { CFHTTPMessageCopyRequestMethod($0)?.takeRetainedValue() } as NSString?
        let url = requestURL()
        webPortalConnectionDLog("HTTP %@ %@", method ?? "(null)", url ?? "(null)")

        //	NSDictionary* headers = [(id)CFHTTPMessageCopyAllHeaderFields(request) autorelease];
        //	NSLog(@"HEADERS: %@", headers);

        let cookies = requestHeader("Cookie")?.components(separatedBy: "; ")
        for cookie in cookies ?? [] {
            // cookie = [cookie stringByTrimmingStartAndEnd];
            let cookieBits = (cookie as NSString).components(separatedBy: "=")
            if cookieBits.count == 2 && (cookieBits[0] as NSString).isEqual(to: SessionCookieName) {
                let temp = portal?.session(forId: cookieBits[1])
                if let temp = temp {
                    self.session = temp
                }
            }
        }

        if method?.isEqual(to: "GET") == true { // GET... check for tokens
            let url = requestURL()
            let urlComponenents = (url as NSString?)?.components(separatedBy: "?")
            if let urlComponenents = urlComponenents, urlComponenents.count > 1 {
                let params = WebPortalConnection.ExtractParams(urlComponenents.last)
                let username = params?.object(forKey: "username")
                let token = params?.object(forKey: "token")
                //            NSString* sha1 = [params objectForKey:@"sha1"];

                let sid = params?.object(forKey: "sid")
                if let sid = sid {
                    self.session = sessionForParameter(sid)
                }

                if let username = username, let token = token { // has token, user exists
                    if (url as NSString?)?.hasPrefix("/movie.") == true {
                        self.session = sessionForParameters(username: username, token: token, doConsume: false) //We keep the token valid for video players...iOS uses multiple range GET requests
                    } else {
                        self.session = sessionForParameters(username: username, token: token, doConsume: true)
                    }
                } else if let token = token {
                    let temp = sessionForParameter(messageUppercaseString(token) as Any)
                    if let temp = temp {
                        self.session = temp
                    }
                }
            }
        }

        if method?.isEqual(to: "POST") == true && multipartData?.count == 1 { // POST auth ?
            let data = multipartData?.lastObject as? NSData
            let paramsString = data.flatMap { NSString(bytes: $0.bytes, length: $0.length, encoding: String.Encoding.utf8.rawValue) }
            let params = WebPortalConnection.ExtractParams(paramsString as String?)

            if params?.object(forKey: "login") != nil {
                let username = params?.object(forKey: "username")
                let sha1 = params?.object(forKey: "sha1")

                var authenticatedByPlugin = false

                if UserDefaults.standard.bool(forKey: "AllowPluginAuthenticationForWebPortal") { // Authentication through a plugin? For example, add an LDAP plugin...
                    let selector = NSSelectorFromString("authenticateConnection:parameters:")
                    for case let (key, _) in PluginManager.plugins() ?? NSMutableDictionary() {
                        let plugin = PluginManager.plugins()?.object(forKey: key) as? NSObject

                        if plugin?.responds(to: selector) == true {
                            let u = plugin?.perform(selector, with: self, with: params)?.takeUnretainedValue() as? WebPortalUser

                            if let u = u {
                                authenticatedByPlugin = true

                                self.user = u

                                self.session.setObject(self.user.objectID, forKey: SessionUserIDKey)
                                self.session.setObject(self.user.name, forKey: SessionUsernameKey)
                                self.session.deleteChallenge()
                                portal?.updateLogEntry(forStudy: nil,
                                                       withMessage: String(format: "Successful login (plugin) for user name: %@", self.user.name ?? "(null)"),
                                                       forUser: nil, ip: asyncSocket?.connectedHost())
                            }
                        }
                    }
                }

                if !authenticatedByPlugin && messageLength(username) != 0 && messageLength(sha1) != 0,
                   let username = username as? String, let sha1 = sha1 as? String {
                    let r = NSFetchRequest<NSFetchRequestResult>(entityName: "User")
                    r.predicate = WebPortalUserLookup.predicate(forName: username)
                    let matches = (try? portal?.database?.independentContext()?.fetch(r)) as? [NSManagedObject]
                    self.user = WebPortalUserLookup.user(among: matches ?? [], forName: username) as? WebPortalUser

                    self.user?.convertPasswordToHashIfNeeded()

                    let sha1internal = self.user?.passwordHash as NSString?

                    if (sha1internal?.length ?? 0) > 0,
                       (sha1 as NSString).compare(sha1internal! as String, options: [.literal, .caseInsensitive]) == .orderedSame {
                        self.session.setObject(self.user.objectID, forKey: SessionUserIDKey)
                        self.session.setObject(username, forKey: SessionUsernameKey)
                        self.session.deleteChallenge()
                        portal?.updateLogEntry(forStudy: nil,
                                               withMessage: String(format: "Successful login for user name: %@", username),
                                               forUser: nil, ip: asyncSocket?.connectedHost())
                    } else {
                        Thread.sleep(forTimeInterval: 2) // To avoid brute-force attacks

                        // The digest the browser sends is taken over the name as it was
                        // typed, and the stored one is taken over the name as it is
                        // registered, so a name typed in another case finds the account
                        // and can never match its password. That reads as a wrong
                        // password to everyone; say what it really is, in the log the
                        // administrator reads. The answer to the client stays the same,
                        // so this does not tell an unauthenticated caller whether an
                        // account exists.
                        var entry = String(format: "Unsuccessful login attempt with invalid password for user name: %@", username)
                        if let name = self.user?.name as NSString?, name.length != 0, !name.isEqual(to: username) {
                            entry = String(format: "Unsuccessful login attempt for user name: %@ - the name is registered as \"%@\", and the password is bound to that spelling, so it has to be typed the same way", username, name)
                        }

                        portal?.updateLogEntry(forStudy: nil, withMessage: entry, forUser: nil, ip: asyncSocket?.connectedHost())
                    }
                }

                resetPOST()
            }

            if params?.object(forKey: "logout") != nil {
                self.session.setObject(nil, forKey: SessionUserIDKey)
                self.session.setObject(nil, forKey: SessionUsernameKey)
                self.user = nil

                resetPOST()
            }
        }

        if let session = sessionValue,
           session.object(forKey: SessionUsernameKey) != nil,
           let userID = session.object(forKey: SessionUserIDKey) {
            // -objectWithID: of whatever the session holds, as the former message was.
            self.user = portal?.database?.independentContext()?
                .perform(#selector(NSManagedObjectContext.object(with:)), with: userID)?
                .takeUnretainedValue() as? WebPortalUser

            if let lastActivity = session.object(forKey: SessionLastActivityDateKey) as? Date {
                if Date().timeIntervalSince(lastActivity) > Double(UserDefaults.standard.integer(forKey: "WebServerTimeOut")) {
                    self.session.setObject(nil, forKey: SessionUserIDKey) // logout
                    self.session.setObject(nil, forKey: SessionUsernameKey) // logout
                    self.user = nil

                    resetPOST()
                }
            }

            self.session.setObject(Date(), forKey: SessionLastActivityDateKey)
        } else {
            self.user = nil
        }
    }

    /// -sessionForId: of a parameter value. A value that is not a string
    /// (NSNull, or an array) equalled no session id, and found none.
    private func sessionForParameter(_ sid: Any) -> WebPortalSession? {
        guard let sid = sid as? String else { return nil }
        return portal?.session(forId: sid)
    }

    /// -sessionForUsername:token:(doConsume:) of parameter values. A user name
    /// that is not a string equalled no session's, and a token that is not a
    /// string was no key of a session's tokens: either found no session.
    private func sessionForParameters(username: Any, token: Any, doConsume: Bool) -> WebPortalSession? {
        guard let username = username as? String, let token = token as? String else { return nil }
        if doConsume {
            return portal?.session(forUsername: username, token: token)
        }
        return portal?.session(forUsername: username, token: token, doConsume: false) as? WebPortalSession
    }

    public override func replyToHTTPRequest() {
        // A request the portal cannot parse (invalid UTF-8 in a parameter, a token
        // or username without a value or given twice) used to raise out of here and
        // end the connection thread; four of them stopped the portal (#757). It now
        // gets a generic 400 and the thread goes on serving.
        defer {
            self.response = nil
            self.user = nil
            self.session = nil
        }
        do {
            try HorosObjCException.perform {
                self.replyToHTTPRequestUnguarded()
            }
        } catch {
            if let exception = caughtException(error) {
                _N2LogExceptionImpl(exception, false, "-[WebPortalConnection replyToHTTPRequest]")
            }
            do {
                try HorosObjCException.perform {
                    if self.response == nil {
                        self.response = WebPortalResponse(webPortalConnection: self)
                    }
                    self.response?.data = nil
                    self.response?.setStatusCode(400)
                    self.handleResourceNotFound()
                }
            } catch {
                if let exception = caughtException(error) {
                    _N2LogExceptionImpl(exception, false, "-[WebPortalConnection replyToHTTPRequest]")
                }
                asyncSocket?.disconnect()
            }
        }
    }

    private func replyToHTTPRequestUnguarded() {
        self.response = WebPortalResponse(webPortalConnection: self)

        fillSessionAndUserVariables()

        var webPortalDefaultTitle = UserDefaults.standard.string(forKey: "WebPortalTitle")

        if (webPortalDefaultTitle as NSString?)?.length ?? 0 == 0 {
            webPortalDefaultTitle = NSLocalizedString("Horos Web Portal", comment: "Web Portal, general default title")
        }

        response?.tokens.setObject(webPortalDefaultTitle!, forKey: "PageTitle" as NSString) // the default title
        response?.tokens.setObject(WebPortalProxy.create(with: self, transformer: InfoTransformer.create()) as Any, forKey: "Info" as NSString)
        if let user = user {
            response?.tokens.setObject(WebPortalProxy.create(with: user, transformer: WebPortalUserTransformer.create()) as Any, forKey: "User" as NSString)
        }
        if let session = sessionValue {
            response?.tokens.setObject(session, forKey: "Session" as NSString)
        }
        response?.tokens.setObject(UserDefaults.standard, forKey: "Defaults" as NSString)

        super.replyToHTTPRequest()

        //NSLog(@"User: %X (R: %@)", user, response.httpHeaders);
    }

    public override func isAuthenticated() -> Bool {
        let sessionUser = sessionValue?.object(forKey: SessionUsernameKey)
        if sessionUser != nil {
            if self.user != nil {
                return true
            }
        } else {
            self.user = nil
        }

        return false
    }

    public override func handleAuthenticationFailed() {
        //NSLog(@"handleAuthenticationFailed user %@", user);

        //	HTTPAuthenticationRequest* auth = [[[HTTPAuthenticationRequest alloc] initWithRequest:request] autorelease];
        //	if (auth.username)
        //		[self.portal updateLogEntryForStudy:nil withMessage:[NSString stringWithFormat:@"Wrong password for user %@", auth.username] forUser:NULL ip:asyncSocket.connectedHost];

        processLoginHtml()

        let bodyData = self.response?.data as NSData?
        // Status Code 401 - Unauthorized
        let resp = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 401, nil, kCFHTTPVersion1_1).takeRetainedValue()
        CFHTTPMessageSetHeaderFieldValue(resp, "Content-Length" as CFString,
                                         String(Int32(truncatingIfNeeded: bodyData?.length ?? 0)) as CFString)
        for case let (key, value) in response?.mutableHTTPHeaders ?? NSMutableDictionary() {
            // The former casts to CFStringRef.
            CFHTTPMessageSetHeaderFieldValue(resp, unsafeBitCast(key as AnyObject, to: CFString.self),
                                             unsafeBitCast(value as AnyObject, to: CFString.self))
        }
        if let bodyData = bodyData {
            CFHTTPMessageSetBody(resp, bodyData as CFData)
        }

        asyncSocket?.write(preprocessErrorResponse(resp), withTimeout: WRITE_ERROR_TIMEOUT, tag: HTTP_RESPONSE)
    }

    public override func handleResourceNotFound() { // also other errors, actually
        var status = response?.statusCode() ?? 0
        if status == 0 {
            status = 404
        }

        let resp = CFHTTPMessageCreateResponse(kCFAllocatorDefault, CFIndex(status), nil, kCFHTTPVersion1_1).takeRetainedValue()

        let title = String(format: "HTTP error %d", status)
        let data = response?.data as NSData?
        // -initWithData:encoding: answered nil for bytes that are not UTF-8, which %@ prints as (null).
        let text: String = data.map { NSString(data: $0 as Data, encoding: String.Encoding.utf8.rawValue).map { $0 as String } ?? "(null)" } ?? ""
        let bodyData = String(format: "<html><head><title>%@</title></head><body><h1>%@</h1>%@</body></html>", title, title, text).data(using: .utf8)!

        CFHTTPMessageSetHeaderFieldValue(resp, "Content-Length" as CFString, String(Int32(truncatingIfNeeded: bodyData.count)) as CFString)
        CFHTTPMessageSetBody(resp, bodyData as CFData)

        let responseData = preprocessErrorResponse(resp)
        asyncSocket?.write(responseData, withTimeout: WRITE_ERROR_TIMEOUT, tag: HTTP_RESPONSE)
    }
}
