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
import IsiXHTTPServer
import ObjectiveC

/// DLog of N2Debug.h: NSLog in a DEBUG build, otherwise only while N2Debug is
/// active.
private func debugLog(_ format: StaticString, _ arguments: CVarArg...) {
    #if DEBUG
    unifiedLogv(format, arguments)
    #else
    if N2Debug.isActive() { unifiedLogv(format, arguments) }
    #endif
}

/// Runs `body` and answers the Objective-C exception it raised, if any: the
/// delegate's methods and a subclass may raise, which the connection answers
/// as a fault, as its @try did.
private func raisedException(_ body: () -> Void) -> NSException? {
    do {
        try HorosObjCException.perform(body)
        return nil
    } catch {
        return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
}

/// What the XML-RPC connection asks the object that answers its calls.
@objc(N2XMLRPCConnectionDelegate)
public protocol N2XMLRPCConnectionDelegate: NSObjectProtocol {
    /// The selector that answers a method name, or nil for a name the
    /// delegate does not publish.
    @objc(selectorStringForXMLRPCRequestMethodName:)
    optional func selectorString(forXMLRPCRequestMethodName name: String) -> String?
    /// Whether a selector the delegate does not publish may be called anyway.
    @objc(isSelectorAvailableToXMLRPC:)
    optional func isSelectorAvailable(toXMLRPC selectorString: String) -> Bool
}

/// One connection of the XML-RPC interface: it reads a request from the bytes
/// received so far, calls the delegate's method and writes the answer, then
/// closes after the answer has left or after its 10-second deadline.
///
/// The connection does not touch the network: a subclass carries the bytes
/// (XMLRPCInterfaceConnection, over the interface's listener) and names the
/// peer. Made without one, it runs the calls made in this process, and what
/// it writes goes nowhere.
///
/// The request's HTTP framing, the reading of the method call, the values and
/// the dispatch rules are in IsiXHTTPServer (XMLRPCHTTPRequest,
/// XMLRPCMethodCall, XMLRPCValueCoder, XMLRPCDispatch); this class holds the
/// connection's state and calls the delegate.
@objc(N2XMLRPCConnection)
open class N2XMLRPCConnection: NSObject {
    /// Answers the calls; retained, as the former property was.
    @objc public var delegate: N2XMLRPCConnectionDelegate?
    /// Strings go out without `<string>`, as the interface's clients expect.
    @objc public var dontSpecifyStringType = false
    /// The request document being handled, once its body has been parsed.
    @objc public private(set) var requestDocument: XMLDocument?

    private var executed = false
    private var waitingToClose = false
    /// The deadline's timer; set and cleared under `lock`, as the former
    /// @synchronized blocks did, since close() may come from another thread.
    private var timeout: Timer?
    private let lock = NSLock()

    /// How long a connection may stay open, from open() to its answer.
    static let deadline: TimeInterval = 10

    public override init() {
        super.init()
    }

    /// The peer, for the access rules; nil for a call made in this process.
    @objc open var address: String? {
        nil
    }

    @objc(N2XMLRPCOptions)
    public func xmlrpcOptions() -> UInt {
        dontSpecifyStringType ? XMLRPCFormatOptions.dontSpecifyStringType.rawValue : 0
    }

    private var formatOptions: XMLRPCFormatOptions {
        XMLRPCFormatOptions(rawValue: xmlrpcOptions())
    }

    // MARK: Lifetime

    /// Starts the deadline, on the current thread's run loop.
    @objc dynamic open func open() {
        lock.withLock {
            timeout?.invalidate()
            timeout = Timer.scheduledTimer(timeInterval: Self.deadline, target: self,
                                           selector: #selector(timeoutDidFire(_:)), userInfo: nil, repeats: false)
        }
    }

    @objc dynamic open func close() {
        lock.withLock {
            timeout?.invalidate()
            timeout = nil
        }
    }

    @objc(timeout:)
    private func timeoutDidFire(_ timer: Timer) {
        lock.withLock {
            timeout = nil
        }
        close()
    }

    // MARK: Transport

    /// Sends `data` to the peer. The connection itself has none: a subclass
    /// that carries the bytes overrides it.
    @objc(writeData:)
    dynamic open func write(_ data: Data) {
    }

    /// What was written has left: the connection closes after its answer.
    @objc dynamic open func connectionFinishedSendingData() {
        if waitingToClose {
            close()
        }
    }

    // MARK: Request

    /// Everything received so far, each time more arrives. The request is
    /// handled once: as soon as its header is complete it is judged, and once
    /// the body Content-Length announces is there it is answered.
    @objc(handleData:)
    dynamic open func handle(_ data: NSMutableData) {
        if executed { return }

        guard let request = XMLRPCHTTPRequest(received: data as Data) else { return }

        // Before the body is read, and so before anything in it is parsed or
        // dispatched. A refused request costs one response and nothing else.
        if !shouldHandleRequest(request.message, version: request.version) {
            executed = true
            return
        }

        if !request.isComplete { return }

        executed = true
        handleRequest(request)
    }

    /// Asked once per request, as soon as the headers are complete and before
    /// the body is read. A subclass that authenticates answers the request
    /// itself and returns false; the default accepts everything, which is what
    /// the calls made in this process expect.
    @objc(shouldHandleRequest:version:)
    dynamic open func shouldHandleRequest(_ request: CFHTTPMessage, version: String) -> Bool {
        true
    }

    private func handleRequest(_ request: XMLRPCHTTPRequest) {
        let version = request.version
        let content = request.content

        // NSXMLDocument refused a missing body by raising, which was answered
        // as an unreadable request.
        guard let content else {
            let reason = "*** -[NSXMLDocument initWithData:options:error:]: nil argument"
            NSLog("Warning: [N2XMLRPCConnection handleRequest:] %@", reason)
            writeDocument(XMLRPCRequestContract.fault(forUnparsableRequest: reason).document, version: version)
            return
        }

        let document: XMLDocument
        do {
            document = try XMLDocument(data: content, options: [])
        } catch {
            if !content.isEmpty {
                NSLog("--- incomplete/corrupted XML document: %@", error.localizedDescription)
            }
            // A Content-Length that has been satisfied means the body is all
            // there, so it is malformed rather than incomplete. Saying so beats
            // waiting for the rest of a request that has already arrived and
            // then closing the connection without a word.
            if request.contentLengthField != nil {
                writeDocument(XMLRPCRequestContract.fault(forUnparsableRequest: error.localizedDescription).document, version: version)
            }
            return
        }
        requestDocument = document

        do {
            let methodCall = try XMLRPCMethodCall.element(in: document)
            // A subclass may raise while it answers early; that is an
            // unreadable request too.
            if let raised = raisedException({ self.handleXmlrpcMethodCall([methodCall, version]) }) {
                throw XMLRPCCodingError(name: raised.name.rawValue, reason: raised.reason ?? "(null)")
            }
        } catch {
            let reason = Self.reason(of: error)
            NSLog("Warning: [N2XMLRPCConnection handleRequest:] %@", reason)
            writeDocument(XMLRPCRequestContract.fault(forUnparsableRequest: reason).document, version: version)
        }
    }

    // MARK: Call

    /// Runs one decoded call: `args` holds the method call element and the
    /// HTTP version, and the response is written when it returns. A subclass
    /// that answers before the call runs overrides it and calls super on
    /// another thread.
    @objc(handleXmlrpcMethodCall:)
    dynamic open func handleXmlrpcMethodCall(_ args: [Any]) {
        autoreleasepool {
            let version = (args[1] as? String) ?? XMLRPCHTTPRequest.defaultVersion
            var methodName: String?
            var failure: String?

            let raised = raisedException {
                do {
                    let methodCall = args[0] as! XMLNode
                    methodName = try XMLRPCMethodCall.methodName(of: methodCall)
                    debugLog("XMLRPC call: %@", methodName! as NSString)
                    let params = try XMLRPCMethodCall.parameters(of: methodCall)

                    var error: NSError?
                    let dateBeforeCall = Date()
                    let result = self.methodCall(methodName, params: params, error: &error)

                    if let error {
                        NSLog("Warning: [N2XMLRPCConnection handleRequest:] %@", error.localizedDescription)
                        self.writeDocument(XMLRPCRequestContract.responseDocument(for: error), version: version)
                        return
                    }

                    debugLog("\tXMLRPC done, took %f seconds.", -dateBeforeCall.timeIntervalSinceNow)

                    // A string that is not valid UTF-16 has no UTF-8 form: the
                    // answer is then empty, as it was.
                    let responseData = try XMLRPCValueCoder.response(value: result, options: self.formatOptions)
                        .data(using: String.Encoding.utf8.rawValue) ?? Data()
                    self.writeResponse(XMLRPCHTTPResponse.methodResponse(responseData, version: version))
                } catch {
                    failure = Self.reason(of: error)
                }
            }
            if let raised {
                failure = raised.reason ?? "(null)"
            }
            if let failure {
                NSLog("Warning: [N2XMLRPCConnection handleRequest:] %@", failure)
                writeDocument(XMLRPCRequestContract.fault(forFailedMethodName: methodName, reason: failure).document, version: version)
            }
        }
    }

    /// Calls the method the delegate publishes for `methodName` with `params`
    /// and answers what it returned. A request that cannot be carried out is
    /// reported in `error`, with a fault document as its description, and
    /// answers nil; so does a method that answers nothing.
    @objc(methodCall:params:error:)
    dynamic open func methodCall(_ methodName: String?, params: [Any]?, error: NSErrorPointer) -> Any? {
        guard let delegate else {
            return fail(XMLRPCRequestContract.fault(forUnknownMethodName: methodName ?? ""), error)
        }
        let target = delegate as AnyObject
        let published = delegate.selectorString?(forXMLRPCRequestMethodName: methodName ?? "")
        let (selectorString, isPublished) = XMLRPCDispatch.selector(
            forMethodName: methodName, published: published,
            respondsTo: { delegate.responds(to: NSSelectorFromString($0)) })
        let selector = NSSelectorFromString(selectorString)

        // Only a method the delegate publishes is callable. Dispatching to
        // whatever selector the delegate happened to respond to made every
        // inherited one-argument method reachable from a socket that asks for
        // no credentials: -isEqualTo: answered, -valueForKey: was invoked with
        // a dictionary as its key, and -performSelector: would have been
        // handed one as a SEL. A delegate that wants a name outside its own
        // list dispatched has to say so through -isSelectorAvailableToXMLRPC:.
        var allowed = isPublished
        if !allowed, let available = delegate.isSelectorAvailable?(toXMLRPC: selectorString) {
            allowed = available
        }
        guard allowed, delegate.responds(to: selector),
              let method = class_getInstanceMethod(object_getClass(target), selector),
              let call = XMLRPCMethodInvocation(method: method, selector: selector) else {
            return fail(XMLRPCRequestContract.fault(forUnknownMethodName: methodName ?? ""), error)
        }

        let params = XMLRPCDispatch.parameters(params)

        // One parameter too many used to walk off the end of the method
        // signature: the extra object went into the slot reserved for the
        // NSError**, and the error pointer then went one past the last
        // argument.
        if let fault = XMLRPCRequestContract.fault(forParameters: params, methodName: methodName ?? "",
                                                   acceptedCount: call.acceptedCount) {
            return fail(fault, error)
        }

        return call.invoke(on: target, parameters: params, error: error)
    }

    /// Reports a fault to the caller instead of raising. The in-process
    /// callers - the horos:// URL handler and the AppleScript bridge - pass no
    /// exception handler, so a raise there took the application down over a
    /// mistyped URL.
    private func fail(_ fault: XMLRPCFault, _ error: NSErrorPointer) -> Any? {
        NSLog("Warning: [N2XMLRPCConnection methodCall:] %@", fault.string)
        error?.pointee = NSError(domain: NSCocoaErrorDomain, code: fault.code,
                                 userInfo: [NSLocalizedDescriptionKey: fault.document])
        return nil
    }

    // MARK: Response

    /// A bare status line with the header fields a client needs to act on it,
    /// and no body: used for the responses that are not XML-RPC documents, such
    /// as the 401 that carries the authentication challenge.
    @objc(writeStatus:headers:version:)
    public func writeStatus(_ status: Int, headers: [String: String]?, version: String) {
        writeResponse(XMLRPCHTTPResponse.status(status, headers: headers ?? [:], version: version))
    }

    /// A response an XML-RPC client can read: the document in the body, with
    /// its length, under the 200 the specification asks for even when the
    /// document is a fault.
    private func writeDocument(_ document: String, version: String) {
        writeResponse(XMLRPCHTTPResponse.document(document, version: version))
    }

    /// Sends the response and closes once it has left.
    @objc(writeResponse:)
    dynamic open func writeResponse(_ response: CFHTTPMessage) {
        write(XMLRPCHTTPResponse.serialized(response))
        waitingToClose = true
    }

    private static func reason(of error: Error) -> String {
        if let coding = error as? XMLRPCCodingError {
            return coding.reason
        }
        return error.localizedDescription
    }
}

/// A call of one Objective-C method whose parameters and answer are objects,
/// with the NSError of the call last when its selector ends with `error:`:
/// the methods the XML-RPC interface publishes. A method of any other shape
/// is not called.
private struct XMLRPCMethodInvocation {
    private let implementation: IMP
    private let selector: Selector
    private let takesError: Bool
    private let returnsObject: Bool
    /// Object arguments before the error.
    let acceptedCount: Int

    private static let maximumParameters = 4

    init?(method: Method, selector: Selector) {
        let selectorString = NSStringFromSelector(selector)
        let argumentCount = Int(method_getNumberOfArguments(method))
        takesError = XMLRPCDispatch.takesError(selectorString)
        acceptedCount = XMLRPCDispatch.acceptedParameterCount(argumentCount: argumentCount, selector: selectorString)
        guard acceptedCount <= Self.maximumParameters else { return nil }

        func type(_ copy: UnsafeMutablePointer<CChar>) -> String {
            defer { free(copy) }
            return String(cString: copy)
        }
        // Qualifiers such as `r` (const) or `n` (in) precede the type itself.
        func stripped(_ encoding: String) -> String {
            String(encoding.drop(while: { "rnNoORV".contains($0) }))
        }
        for index in 2..<(2 + acceptedCount) {
            guard stripped(type(method_copyArgumentType(method, UInt32(index))!)).hasPrefix("@") else { return nil }
        }
        if takesError {
            guard stripped(type(method_copyArgumentType(method, UInt32(argumentCount - 1))!)).hasPrefix("^@") else { return nil }
        }
        let returnType = stripped(type(method_copyReturnType(method)))
        guard returnType.hasPrefix("@") || returnType == "v" else { return nil }
        returnsObject = returnType.hasPrefix("@")

        implementation = method_getImplementation(method)
        self.selector = selector
    }

    func invoke(on target: AnyObject, parameters: [Any], error: NSErrorPointer) -> Any? {
        // Missing parameters are nil, as the slots NSInvocation left empty.
        let arguments: [AnyObject?] = (0..<acceptedCount).map { $0 < parameters.count ? parameters[$0] as AnyObject : nil }
        let answer: Unmanaged<AnyObject>?
        switch (acceptedCount, takesError) {
        case (0, false):
            typealias F = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
            answer = unsafeBitCast(implementation, to: F.self)(target, selector)
        case (0, true):
            typealias F = @convention(c) (AnyObject, Selector, NSErrorPointer) -> Unmanaged<AnyObject>?
            answer = unsafeBitCast(implementation, to: F.self)(target, selector, error)
        case (1, false):
            typealias F = @convention(c) (AnyObject, Selector, AnyObject?) -> Unmanaged<AnyObject>?
            answer = unsafeBitCast(implementation, to: F.self)(target, selector, arguments[0])
        case (1, true):
            typealias F = @convention(c) (AnyObject, Selector, AnyObject?, NSErrorPointer) -> Unmanaged<AnyObject>?
            answer = unsafeBitCast(implementation, to: F.self)(target, selector, arguments[0], error)
        case (2, false):
            typealias F = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Unmanaged<AnyObject>?
            answer = unsafeBitCast(implementation, to: F.self)(target, selector, arguments[0], arguments[1])
        case (2, true):
            typealias F = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, NSErrorPointer) -> Unmanaged<AnyObject>?
            answer = unsafeBitCast(implementation, to: F.self)(target, selector, arguments[0], arguments[1], error)
        case (3, false):
            typealias F = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?) -> Unmanaged<AnyObject>?
            answer = unsafeBitCast(implementation, to: F.self)(target, selector, arguments[0], arguments[1], arguments[2])
        case (3, true):
            typealias F = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, NSErrorPointer) -> Unmanaged<AnyObject>?
            answer = unsafeBitCast(implementation, to: F.self)(target, selector, arguments[0], arguments[1], arguments[2], error)
        case (4, false):
            typealias F = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, AnyObject?) -> Unmanaged<AnyObject>?
            answer = unsafeBitCast(implementation, to: F.self)(target, selector, arguments[0], arguments[1], arguments[2], arguments[3])
        default:
            typealias F = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, AnyObject?, NSErrorPointer) -> Unmanaged<AnyObject>?
            answer = unsafeBitCast(implementation, to: F.self)(target, selector, arguments[0], arguments[1], arguments[2], arguments[3], error)
        }
        // A void method leaves the return register as it found it.
        return returnsObject ? answer?.takeUnretainedValue() : nil
    }
}
