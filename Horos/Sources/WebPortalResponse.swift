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

import Cocoa

// WebPortalResponse, WebPortalProxy, WebPortalProxyObjectTransformer and its
// subclasses, and NSMutableDictionary (WebPortalProxy) are implemented in Swift.
// The Objective-C names, the selectors and <Horos/WebPortalResponse.h>
// are those of the former classes. What stays in Objective-C is in
// WebPortalResponse+CAPI.mm: iPhoneCompatibleNumericalFormat, a C function the
// application exports with its C++ name, and the accessors of the `data`
// instance variable of HTTPDataResponse, which Swift cannot reach and which
// HTTPDataResponse reads when it sends the response.
//
// The template engine works on NSString, NSArray and NSDictionary, as before:
// UTF-16 ranges, literal searches, the dictionaries' own order and the
// exceptions of the Foundation methods (an out-of-range index raises, as
// -objectAtIndex: and -characterAtIndex: did) stay those of the former code.

/// The former `@synchronized(WebPortalResponseLock)`: a recursive lock, as
/// @synchronized was, now a Sendable object of its own.
private let WebPortalResponseLock = NSRecursiveLock()

/// `-[obj class]`, the class Objective-C compared with, which is not always the
/// isa that type(of:) answers.
private func objcClass(of obj: AnyObject) -> AnyClass {
    unsafeBitCast(obj.perform(NSSelectorFromString("class"))!.takeUnretainedValue(), to: AnyClass.self)
}

private func objcIsKind(_ obj: AnyObject?, _ cls: AnyClass) -> Bool {
    guard let obj = obj as? NSObjectProtocol else { return false }
    return obj.isKind(of: cls)
}

/// An `id` as Objective-C held it: an object, or nil.
private func objcObject(_ value: Any?) -> AnyObject? {
    guard let value else { return nil }
    return value as AnyObject
}

/// `[obj boolValue]` of an NSNumber or an NSString; nil answers NO.
private func objcBool(_ value: Any?) -> Bool {
    if let number = value as? NSNumber { return number.boolValue }
    if let string = value as? NSString { return string.boolValue }
    return false
}

/// `(int)value`, as the arm64 conversion does it: NaN is 0, values past the
/// range saturate.
private func cInt(_ value: CGFloat) -> Int32 {
    if value.isNaN { return 0 }
    if value >= CGFloat(Int32.max) { return Int32.max }
    if value <= CGFloat(Int32.min) { return Int32.min }
    return Int32(value)
}

/// `-[NSMutableString appendString:]`, which raises on nil as before.
private func append(_ string: NSString?, to ret: NSMutableString) {
    if let string {
        ret.append(string as String)
    } else {
        ret.perform(#selector(NSMutableString.append(_:)), with: nil)
    }
}

/// `-compare:`, sent to an NSString or an NSNumber with whatever object the
/// template compares it with, as the former code sent it.
@objc private protocol WebPortalComparing {
    @objc(compare:) func compare(_ other: AnyObject?) -> Int
}

/// The members of a study the portal lists among the other studies of a
/// patient, a DicomStudy or a DCMTKStudyQueryNode, sent as messages.
@objc private protocol WebPortalListedStudy {
    @objc(studyInstanceUID) func studyInstanceUID() -> NSString?
    @objc(noFiles) func noFiles() -> NSNumber?
    @objc(rawNoFiles) func rawNoFiles() -> NSNumber?
}

// MARK: - WebPortalResponse

@objc(WebPortalResponse)
public final class WebPortalResponse: HTTPDataResponse {

    /// Weak: the connection owns the response.
    @objc public private(set) weak var wpc: WebPortalConnection?
    /// Kept as the former instance variable; nothing reads it.
    private weak var portal: WebPortal?
    /// The former `httpHeaders` property. HTTPDataResponse's HTTPResponse
    /// conformance gives Swift an -httpHeaders method that answers a copied
    /// dictionary; the -httpHeaders that answers this one, which callers add
    /// headers to, is in WebPortalResponse+CAPI.mm.
    @objc public private(set) var mutableHTTPHeaders: NSMutableDictionary!
    @objc public var templateString: String!
    private var statusCodeValue: Int32 = 0
    private var tokensStorage: NSMutableDictionary?

    @objc(initWithWebPortalConnection:)
    public init(webPortalConnection iwpc: WebPortalConnection!) {
        wpc = iwpc
        portal = iwpc?.portal
        mutableHTTPHeaders = NSMutableDictionary(capacity: 4)
        super.init(data: nil)
    }

    @objc(setSessionId:)
    public func setSessionId(_ sessionId: String!) {
        mutableHTTPHeaders.setObject("\(SessionCookieName)=\(sessionId ?? "(null)"); path=/", forKey: "Set-Cookie" as NSString)
    }

    @objc public var mimeType: String! {
        get { mutableHTTPHeaders.object(forKey: "Content-Type") as? String }
        set {
            guard let newValue else {
                NSException(name: .invalidArgumentException,
                            reason: "*** -[__NSDictionaryM setObject:forKey:]: object cannot be nil (key: Content-Type)",
                            userInfo: nil).raise()
                return
            }
            mutableHTTPHeaders.setObject(newValue, forKey: "Content-Type" as NSString)
        }
    }

    /// The former `statusCode` property, whose getter HTTPDataResponse's
    /// HTTPResponse conformance declares.
    @objc public override func statusCode() -> Int32 {
        statusCodeValue
    }

    @objc(setStatusCode:)
    public func setStatusCode(_ statusCode: Int32) {
        statusCodeValue = statusCode
    }

    @objc(setDataWithString:)
    public func setDataWith(_ str: String!) {
        self.data = (str as NSString?)?.data(using: String.Encoding.utf8.rawValue)
    }

    /// Stored in HTTPDataResponse's `data` instance variable, which it sends.
    @objc public var data: Data! {
        get {
            if webPortalResponseData() == nil, let templateString = self.templateString {
                let ts = NSMutableString(string: templateString)
                WebPortalResponse.mutableString(ts, evaluateTokensWith: self.tokens, context: wpc)
                setDataWith(ts as String)
            }

            if webPortalResponseData() == nil {
                self.data = Data()
                if self.statusCode() == 0 {
                    self.setStatusCode(404)
                }
            }

            return webPortalResponseData()
        }
        set {
            setWebPortalResponseData(newValue)
        }
    }

    @objc public var tokens: NSMutableDictionary! {
        if tokensStorage == nil {
            tokensStorage = NSMutableDictionary()
        }
        return tokensStorage
    }

    // MARK: Template evaluation

    /// Not in the header; kept under its former selector.
    @objc(object:valueForKeyPath:context:)
    class func object(_ o: Any?, valueForKeyPath keyPath: String?, context: Any?) -> Any? {
        // The template engine always passes a key path; a nil one found nothing.
        guard let keyPath else { return nil }
        return value(of: objcObject(o), keyPath: keyPath as NSString, context: context)
    }

    private class func proxy(_ o: AnyObject?, _ transformer: Any?) -> AnyObject {
        WebPortalProxy.create(with: o as? NSObject, transformer: transformer) as AnyObject
    }

    private class func value(of o: AnyObject?, keyPath: NSString, context: Any?) -> AnyObject? {
        let parts = keyPath.components(separatedBy: ".") as NSArray
        var part0 = parts.object(at: 0) as! NSString

        WebPortalResponseLock.lock()
        defer { WebPortalResponseLock.unlock() }

        if objcIsKind(o, NSString.self) {
            return value(of: proxy(o, StringTransformer.create()), keyPath: keyPath, context: context)
        }
        if objcIsKind(o, NSDate.self) {
            return value(of: proxy(o, DateTransformer.create()), keyPath: keyPath, context: context)
        }
        if objcIsKind(o, WebPortalUser.self) {
            return value(of: proxy(o, WebPortalUserTransformer.create()), keyPath: keyPath, context: context)
        }
        if objcIsKind(o, DicomStudy.self) {
            return value(of: proxy(o, DicomStudyTransformer.create()), keyPath: keyPath, context: context)
        }
        if objcIsKind(o, DicomSeries.self) {
            return value(of: proxy(o, DicomSeriesTransformer.create()), keyPath: keyPath, context: context)
        }

        if objcIsKind(o, NSManagedObject.self) {
            return value(of: proxy(o, WebPortalProxyObjectTransformer.create()), keyPath: keyPath, context: context)
        }

        var value: AnyObject?
        var raised: NSException?
        if objcIsKind(o, WebPortalProxy.self) {
            (value, raised) = (o as! WebPortalProxy).valueCatchingException(forKey: part0 as String, context: context)
        } else {
            if objcIsKind(o, NSArray.self) || objcIsKind(o, NSSet.self) {
                part0 = ("@" as NSString).appending(part0 as String) as NSString
            }
            do {
                try HorosObjCException.perform {
                    value = objcObject((o as? NSObject)?.value(forKey: part0 as String))
                }
            } catch {
                raised = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
            }
        }

        if let raised {
            NSLog("***** [WebPortalResponse object:valueForKeyPath:context] %@", raised)
            return nil
        }
        if parts.count > 1 {
            let rest = parts.subarray(with: NSRange(location: 1, length: parts.count - 1)) as NSArray
            return self.value(of: value, keyPath: rest.componentsJoined(by: ".") as NSString, context: context)
        }
        return value
    }

    /// Not in the header; kept under its former selector.
    @objc(evaluateToken:withDictionary:context:mustReevaluate:)
    class func evaluateToken(_ tokenStr: String?, withDictionary dict: NSDictionary?, context: Any?,
                             mustReevaluate: UnsafeMutablePointer<ObjCBool>?) -> String? {
        var must = mustReevaluate?.pointee.boolValue ?? false
        let r = evaluate(token: tokenStr as NSString?, dictionary: dict, context: context, mustReevaluate: &must)
        mustReevaluate?.pointee = ObjCBool(must)
        return r as String?
    }

    private class func evaluate(token tokenStr: NSString?, dictionary dict: NSDictionary?, context: Any?,
                                mustReevaluate: inout Bool) -> NSString? {
        guard let tokenStr else {
            // Every message to a nil token answered nil: the dictionary lookup
            // of a nil key path found nothing.
            return ""
        }
        // # separates the actual token from extra chars that can be used as comments or as marker for otherwise equal tokens
        let tokenStrParts = tokenStr.components(separatedBy: "#") as NSArray
        var token = tokenStrParts.object(at: 0) as! NSString
        let tokenStrExtras: NSString = tokenStrParts.count > 1
            ? NSString(format: "#%@", (tokenStrParts.subarray(with: NSRange(location: 1, length: tokenStrParts.count - 1)) as NSArray).componentsJoined(by: "#"))
            : ""

        let parts = token.components(separatedBy: ":") as NSArray
        let part0 = parts.object(at: 0) as! NSString

        // is it a command?

        if part0.isEqual(to: "FOREACH") {
            // %FOREACH:array:item%; one without its array or its item name
            // raised on the missing part. It lists nothing.
            guard parts.count >= 3 else {
                NSLog("***** WebPortal: syntax error : FOREACH needs an array and an item name: %@", tokenStr)
                return ""
            }
            let arrayName = parts.object(at: 1) as! NSString
            let iName = parts.object(at: 2) as! NSString

            let body = dict?.object(forKey: token.appending(":Body")) as? NSString

            let ret = NSMutableString()

            let idict = dict?.mutableCopy() as? NSMutableDictionary
            var c = 0
            var array = value(of: dict, keyPath: arrayName, context: context)
            if objcIsKind(array, NSSet.self) {
                array = (array as! NSSet).allObjects as NSArray
            }
            if let array {
                guard let enumerable = array as? NSFastEnumeration else {
                    // for (id i in array) raised on what is not a collection
                    // (it does not answer -countByEnumeratingWithState:objects:count:).
                    // It lists nothing.
                    NSLog("***** WebPortal: FOREACH over %@, which is not a collection", arrayName)
                    return ret
                }
                for i in IteratorSequence(NSFastEnumerationIterator(enumerable)) {
                    idict?.setObject(i, forKey: iName)
                    idict?.setObject(NSNumber(value: c), forKey: NSString(format: "%@_Index", iName))
                    idict?.setObject(NSNumber(value: c % 2), forKey: NSString(format: "%@_Index2", iName))

                    // A FOREACH that is not a block has no body: nothing to
                    // append (-appendString: nil raised).
                    guard let istr = body?.mutableCopy() as? NSMutableString else { continue }
                    evaluateTokens(in: istr, dictionary: idict, context: context)
                    append(istr, to: ret)

                    c += 1
                }
            }

            return ret
        }

        if part0.isEqual(to: "IF") {
            // An IF without a condition (%IF%, %IF:%) raised on the missing
            // part or on its first character. An empty condition is not
            // satisfied.
            let condition: NSString = parts.count > 1 ? parts.object(at: 1) as! NSString : ""

            let conditionPartsOr = condition.components(separatedBy: "||")
            var orSatisfied = false
            for condition in conditionPartsOr {
                let conditionPartsAnd = (condition as NSString).components(separatedBy: "&&")
                var andSatisfied = true
                for andCondition in conditionPartsAnd {
                    var condition = andCondition as NSString
                    var negate = false

                    if condition.length != 0 && condition.character(at: 0) == 0x21 /* '!' */ {
                        negate = true
                        condition = condition.substring(from: 1) as NSString
                    }

                    var satisfied = false
                    let conditionPartsOp = condition.components(separatedBy: CharacterSet(charactersIn: "=<>"))
                    let conditionPartsOp2 = NSMutableArray()
                    for s in conditionPartsOp where (s as NSString).length != 0 {
                        conditionPartsOp2.add(s as NSString)
                    }
                    if conditionPartsOp2.count == 2 {
                        let sl = conditionPartsOp2.object(at: 0) as! NSString
                        let sl0 = sl.character(at: 0)
                        var vl: AnyObject?
                        if sl0 == 0x22 /* '"' */ && sl.length >= 2 && sl.character(at: sl.length - 1) == 0x22 {
                            vl = sl.substring(with: NSRange(location: 1, length: sl.length - 2)) as NSString
                        } else if sl0 >= 0x30 /* '0' */ && sl0 <= 0x39 /* '9' */ {
                            vl = NSNumber(value: sl.floatValue)
                        } else {
                            vl = value(of: dict, keyPath: sl, context: context)
                        }

                        let sr = conditionPartsOp2.object(at: 1) as! NSString
                        let sr0 = sr.character(at: 0)
                        var vr: AnyObject?
                        if sr0 == 0x22 /* '"' */ && sr.length >= 2 && sr.character(at: sr.length - 1) == 0x22 {
                            vr = sr.substring(with: NSRange(location: 1, length: sr.length - 2)) as NSString
                        } else if sr0 >= 0x30 /* '0' */ && sr0 <= 0x39 /* '9' */ {
                            vr = NSNumber(value: sr.floatValue)
                        } else {
                            vr = value(of: dict, keyPath: sr, context: context)
                        }

                        if let vl, let vr, objcIsKind(vl, objcClass(of: vr)) || objcIsKind(vr, objcClass(of: vl)) {
                            if objcIsKind(vl, NSString.self) || objcIsKind(vl, NSNumber.self) {
                                let cr = unsafeBitCast(vl, to: WebPortalComparing.self).compare(vr)
                                let op = condition.substring(with: NSRange(location: sl.length, length: condition.length - sl.length - sr.length)) as NSString

                                if op.isEqual(to: "==") {
                                    satisfied = cr == ComparisonResult.orderedSame.rawValue
                                }
                                if op.isEqual(to: "<") {
                                    satisfied = cr == ComparisonResult.orderedAscending.rawValue
                                }
                                if op.isEqual(to: ">") {
                                    satisfied = cr == ComparisonResult.orderedDescending.rawValue
                                }
                                if op.isEqual(to: ">=") {
                                    satisfied = cr != ComparisonResult.orderedAscending.rawValue
                                }
                                if op.isEqual(to: "<=") {
                                    satisfied = cr != ComparisonResult.orderedDescending.rawValue
                                }
                            }
                        }
                    } else {
                        let o = value(of: dict, keyPath: condition, context: context)

                        if objcIsKind(o, NSNumber.self) {
                            satisfied = (o as! NSNumber).boolValue
                        } else if o != nil {
                            satisfied = true
                        }
                    }

                    if negate {
                        satisfied = !satisfied
                    }

                    andSatisfied = andSatisfied && satisfied
                }

                orSatisfied = orSatisfied || andSatisfied
            }

            let body = dict?.object(forKey: token.appending(":Body")) as? NSString
            let bodyYes: NSString?
            let bodyNo: NSString?
            let elseRange = body?.range(of: NSString(format: "%%ELSE:%@%@%%", condition, tokenStrExtras) as String)
                ?? NSRange(location: 0, length: 0)
            if elseRange.length != 0 {
                bodyYes = body!.substring(to: elseRange.location) as NSString
                bodyNo = body!.substring(from: elseRange.location + elseRange.length) as NSString
            } else {
                bodyYes = body
                bodyNo = ""
            }

            mustReevaluate = true
            return orSatisfied ? bodyYes : bodyNo
        }

        if part0.isEqual(to: "URLENC") || part0.isEqual(to: "U") {
            token = (parts.subarray(with: NSRange(location: 1, length: parts.count - 1)) as NSArray).componentsJoined(by: ":") as NSString
            let str = evaluate(token: token, dictionary: dict, context: context, mustReevaluate: &mustReevaluate)
            // U/URLENC represents one template subcomponent: either a query
            // value or a filename segment. It never represents a complete URL.
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            return str?.addingPercentEncoding(withAllowedCharacters: allowed) as NSString?
        }

        if part0.isEqual(to: "XMLENC") || part0.isEqual(to: "X") {
            var from = 1

            var part1: NSString?
            if parts.count >= 3 {
                part1 = parts.object(at: 1) as? NSString
            }

            if part1?.isEqual(to: "ZWS") == true {
                from += 1
            }

            token = (parts.subarray(with: NSRange(location: from, length: parts.count - from)) as NSArray).componentsJoined(by: ":") as NSString
            var evaldToken = evaluate(token: token, dictionary: dict, context: context, mustReevaluate: &mustReevaluate)

            if part1?.isEqual(to: "ZWS") == true {
                evaldToken = evaldToken?.components(withLength: 1).componentsJoined(by: NSString(format: "%C", 0x200b as unichar) as String) as NSString?
            }

            return evaldToken?.xmlEscapedString()
        }

        if part0.isEqual(to: "LOCNUM") {
            token = (parts.subarray(with: NSRange(location: 1, length: parts.count - 1)) as NSArray).componentsJoined(by: ":") as NSString
            if var o = value(of: dict, keyPath: token, context: context) {
                if !objcIsKind(o, NSNumber.self) {
                    o = NSNumber(value: ((o as! NSObjectProtocol).description as NSString).floatValue)
                }

                return NumberFormatter.localizedString(from: o as! NSNumber, number: .decimal) as NSString
            }
        }

        // or is it just a value?
        if let o = value(of: dict, keyPath: token, context: context) {
            if objcIsKind(o, NSString.self) {
                return (o as! NSString)
            }

            return (o as! NSObjectProtocol).description as NSString
        }

        return ""
    }

    @objc(mutableString:evaluateTokensWithDictionary:context:)
    public class func mutableString(_ string: NSMutableString!, evaluateTokensWith localtokens: NSDictionary!, context: Any!) {
        evaluateTokens(in: string, dictionary: localtokens, context: context)
    }

    private class func evaluateTokens(in string: NSMutableString?, dictionary localtokens: NSDictionary?, context: Any?) {
        // A message to a nil string found no token.
        guard let string else { return }

        var range = NSRange(location: 0, length: string.length)
        var occ = NSRange(location: 0, length: 0)
        let whitespace = CharacterSet(charactersIn: " \t\n\r")

        // scan for tokens
        while UInt(bitPattern: range.location) < UInt(bitPattern: string.length &- 1) {
            occ = string.range(of: "%", options: .literal, range: range)
            if occ.length == 0 { break }

            var isToken = true
            // is it a token, or just a random percentage?
            var occ2 = string.range(of: "%", options: .literal, range: NSRange(location: occ.location + 1, length: string.length - occ.location - 1))

            if occ2.length == 0 {
                isToken = false
            } else if occ2.location == occ.location + 1 {
                // %% has nothing between its delimiters: not a token (the
                // empty token raised on its first character).
                isToken = false
            } else if string.rangeOfCharacter(from: whitespace, options: [], range: NSRange(location: occ.location + 1, length: occ2.location - occ.location - 1)).length != 0 {
                isToken = false
            }

            if isToken {
                // we have 2 eventual token delimiters, what's in between?
                var tokenStr = string.substring(with: NSRange(location: occ.location + 1, length: occ2.location - occ.location - 1)) as NSString
                let dict = localtokens?.mutableCopy() as? NSMutableDictionary

                if tokenStr.character(at: 0) == 0x5B /* '[' */ { // opens a block, look for its closing
                    tokenStr = tokenStr.substring(from: 1) as NSString
                    let tokenCloser = NSString(format: "%%]%@%%", tokenStr)
                    let tokenCloserRange = string.range(of: tokenCloser as String, options: .literal, range: NSRange(location: occ2.location + 1, length: string.length - (occ2.location + 1)))
                    if tokenCloserRange.length != 0 {
                        let blockKey = ((tokenStr.components(separatedBy: "#") as NSArray).object(at: 0) as! NSString).appending(":Body")
                        dict?.setObject(string.substring(with: NSRange(location: occ2.location + 1, length: tokenCloserRange.location - (occ2.location + 1))) as NSString, forKey: blockKey as NSString)
                        occ2.location = tokenCloserRange.location + tokenCloserRange.length - 1
                    } else {
                        NSLog("***** WebPortal: syntax error : no closing for: %@", tokenCloser)
                    }
                }

                var mustReevaluate = false
                if let evaldStr = evaluate(token: tokenStr, dictionary: dict, context: context, mustReevaluate: &mustReevaluate) {
                    string.replaceCharacters(in: NSRange(location: occ.location, length: occ2.location - occ.location + 1), with: evaldStr as String)
                    range.location = occ.location
                    if !mustReevaluate {
                        range.location += evaldStr.length
                    }
                    range.length = string.length - range.location
                } else {
                    isToken = false
                }
            }

            if !isToken {
                range.location = occ.location + 1
                range.length = string.length - range.location
            }
        }
    }
}

// MARK: - WebPortalProxy

@objc(WebPortalProxy)
public final class WebPortalProxy: NSObject {

    @objc public private(set) var object: NSObject!
    @objc public private(set) var transformers: [Any]!

    /// Not in the header; kept under its former selector.
    @objc(initWithObject:transformer:)
    init(object o: NSObject?, transformer t: NSObject?) {
        super.init()
        self.object = o

        if objcIsKind(t, NSArray.self) {
            for it in t as! NSArray {
                if !objcIsKind(it as AnyObject, WebPortalProxyObjectTransformer.self) {
                    NSException(name: .invalidArgumentException,
                                reason: "Invalid transformer class: \((it as! NSObject).className)", userInfo: nil).raise()
                }
            }
            self.transformers = (t as! NSArray) as? [Any]
        } else if objcIsKind(t, WebPortalProxyObjectTransformer.self) {
            self.transformers = [t!]
        } else {
            NSException(name: .invalidArgumentException,
                        reason: "Invalid transformer class: \(t?.className ?? "(null)")", userInfo: nil).raise()
        }
    }

    @objc(createWithObject:transformer:)
    public class func create(with o: NSObject!, transformer t: Any!) -> Any! {
        WebPortalProxy(object: o, transformer: objcObject(t) as? NSObject)
    }

    @objc(valueForKey:context:)
    public func value(forKey key: String!, context: Any!) -> Any! {
        let (value, exception) = valueCatchingException(forKey: key, context: context)
        if let exception {
            exception.raise()
        }
        return value
    }

    /// -valueForKey:context:, with the exception the last lookup raised
    /// returned instead of raised, for the template engine, which caught it.
    fileprivate func valueCatchingException(forKey key: String?, context: Any?) -> (AnyObject?, NSException?) {
        WebPortalResponseLock.lock()
        for t in transformers ?? [] {
            var r: AnyObject?
            try? HorosObjCException.perform {
                r = objcObject((t as! WebPortalProxyObjectTransformer).value(forKey: key, object: object, context: context))
            }
            if let r {
                WebPortalResponseLock.unlock()
                return (r, nil)
            }
        }
        WebPortalResponseLock.unlock()

        var value: AnyObject?
        do {
            try HorosObjCException.perform {
                value = objcObject(object?.value(forKey: key ?? ""))
            }
        } catch {
            return (nil, (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException)
        }
        return (value, nil)
    }
}

// MARK: - WebPortalProxyObjectTransformer

@objc(WebPortalProxyObjectTransformer)
public class WebPortalProxyObjectTransformer: NSObject {

    public required override init() {
        super.init()
    }

    @objc public class func create() -> Any! {
        self.init()
    }

    @objc(valueForKey:object:context:)
    public func value(forKey key: String!, object o: NSObject!, context: Any!) -> Any! {
        let wpc = context as? WebPortalConnection

        if objcIsKind(o, NSManagedObject.self) && (key as NSString?)?.isEqual(to: "isSelected") == true {
            let xid = (o as! NSManagedObject).xid()
            let parameters = wpc?.value(forKey: "parameters") as? NSDictionary
            for selectedID in WebPortalConnection.makeArray(parameters?.object(forKey: "selected")) {
                if (selectedID as? NSString)?.isEqual(to: xid) == true {
                    return NSNumber(value: true)
                }
            }
            return NSNumber(value: false)
        }

        return nil
    }
}

// MARK: - InfoTransformer

@objc(InfoTransformer)
public final class InfoTransformer: WebPortalProxyObjectTransformer {

    @objc public override class func create() -> Any! {
        self.init()
    }

    /// `+[WebPortalConnection FormatParams:]` and `+ExtractParams:`, called
    /// with the dictionaries themselves, whose order the parameters follow.
    private static func formatParams(_ dict: NSDictionary?) -> Any? {
        WebPortalConnection.perform(NSSelectorFromString("FormatParams:"), with: dict)?.takeUnretainedValue()
    }

    private static func extractParams(_ params: String?) -> NSDictionary? {
        WebPortalConnection.perform(NSSelectorFromString("ExtractParams:"), with: params as NSString?)?.takeUnretainedValue() as? NSDictionary
    }

    @objc(valueForKey:object:context:)
    public override func value(forKey key: String!, object o: NSObject!, context wpcagain: Any!) -> Any! {
        let wpc = o as? WebPortalConnection
        let key = key as NSString?
        func matches(_ name: String) -> Bool { key?.isEqual(to: name) == true }
        let requestIsIOS = wpc?.requestIsIOS() ?? false
        let authenticationRequired = wpc?.portal?.authenticationRequired ?? false
        let user = wpc?.user
        let connectedHost = wpc?.asyncSocket?.connectedHost() as NSString?

        if matches("isIOS") {
            return NSNumber(value: requestIsIOS)
        }
        if matches("isMacOS") {
            return NSNumber(value: wpc?.requestIsMacOS() ?? false)
        }
        if matches("proposeWeasis") {
            return NSNumber(value: (wpc?.portal?.weasisEnabled ?? false) && !requestIsIOS)
        }
        if matches("proposeFlash") {
            // Flash is gone from every browser, and the portal no longer makes
            // .swf movies. A customized template that still asks gets the video.
            return NSNumber(value: false)
        }
        if matches("authenticationRequired") {
            return NSNumber(value: authenticationRequired && user == nil)
        }
        if matches("newToken") {
            return wpc?.session?.createToken()
        }
        if matches("passwordRestoreAllowed") {
            return NSNumber(value: wpc?.portal?.passwordRestoreAllowed ?? false)
        }
        if matches("baseUrl") {
            return wpc?.portalURL()
        }
        if matches("baseJnlpUrl") {
            // [nil substringFromIndex:] answered nil, and appending nil raised.
            guard let portalURL = wpc?.portalURL() as NSString? else {
                NSException(name: .invalidArgumentException, reason: "*** -[__NSCFConstantString stringByAppendingString:]: nil argument", userInfo: nil).raise()
                return nil
            }
            return ("jnlp" as NSString).appending(portalURL.substring(from: 4))
        }
        if matches("clientAddress") {
            return connectedHost
        }
        if matches("isLAN") {
            if connectedHost?.hasPrefix("10.") == true { return NSNumber(value: true) }
            if connectedHost?.hasPrefix("172.") == true { return NSNumber(value: false) }
            if connectedHost?.hasPrefix("192.") == true { return NSNumber(value: true) }
            if connectedHost?.hasPrefix("127.0.0.1") == true { return NSNumber(value: true) }

            return NSNumber(value: false)
        }
        if matches("dicomCStorePort") {
            return wpc?.dicomCStorePortString()
        }
        if matches("newChallenge") {
            return wpc?.session?.newChallenge()
        }
        if matches("proposeReport") {
            if authenticationRequired && user == nil { return NSNumber(value: false) }
            return NSNumber(value: user == nil || (user?.downloadReport?.boolValue ?? false))
        }
        if matches("proposeDicomUpload") {
            if authenticationRequired && user == nil { return NSNumber(value: false) }
            return NSNumber(value: (user == nil || (user?.uploadDICOM?.boolValue ?? false)) && !requestIsIOS)
        }
        if matches("proposeDicomSend") {
            if authenticationRequired && user == nil { return NSNumber(value: false) }
            return NSNumber(value: user == nil || (user?.sendDICOMtoSelfIP?.boolValue ?? false) || (user?.sendDICOMtoAnyNodes?.boolValue ?? false))
        }
        if matches("proposeWADORetrieve") {
            return NSNumber(value: wpc?.portal?.weasisEnabled ?? false)
        }
        if matches("WADOBaseURL") {
            // NSString *protocol = [[NSUserDefaults standardUserDefaults] boolForKey:@"encryptedWebServer"] ? @"https" : @"http";
            var wadoSubUrl: NSString = "wado" // See Web Server Preferences

            if wadoSubUrl.hasPrefix("/") {
                wadoSubUrl = wadoSubUrl.substring(from: 1) as NSString
            }

            let baseURL = NSString(format: "%@/%@", (wpc?.portalURL() ?? "(null)") as NSString, wadoSubUrl)

            return baseURL
        }

        if matches("proposeZipDownload") {
            if authenticationRequired && user == nil { return NSNumber(value: false) }
            return NSNumber(value: (user == nil || (user?.downloadZIP?.boolValue ?? false)) && !requestIsIOS)
        }
        if matches("proposeDelete") {
            return NSNumber(value: UserDefaults.standard.bool(forKey: "webPortalAdminCanDeleteStudies") && (user?.isAdmin?.boolValue ?? false))
        }
        if matches("federatedSources") {
            return BrowserController.federatedSourceCatalog() as NSArray?
        }
        if matches("federatedPermission") {
            return FederatedSearch.permissionLabel(forPredicate: user?.studyPredicate)
        }
        if matches("hasFederatedSources") {
            let catalog = BrowserController.federatedSourceCatalog() as NSArray?
            for source in catalog ?? [] {
                if objcBool((source as? NSDictionary)?.object(forKey: "included")) {
                    return NSNumber(value: true)
                }
            }
            return NSNumber(value: false)
        }

        if matches("proposeShare") {
            if authenticationRequired && user == nil { return NSNumber(value: false) }

            if user == nil || (user?.shareStudyWithUser?.boolValue ?? false) {
                let idatabase = wpc?.independentWebDatabase

                var result = NSNumber(value: false)
                let context = idatabase?.managedObjectContext
                N2ManagedObjectContextPerformAndWait(context) {
                let req = NSFetchRequest<NSFetchRequestResult>()
                req.entity = idatabase?.entity(forName: "User")
                req.predicate = NSPredicate(value: true)

                do {
                    try HorosObjCException.perform {
                        let count: Int
                        if let context {
                            count = (try? context.count(for: req)) ?? NSNotFound
                        } else {
                            count = 0
                        }
                        result = NSNumber(value: count > (user != nil ? 1 : 0))
                    }
                } catch {
                    if let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                        NSLog("***** [WebPortalResponse object:valueForKeyPath:context] %@", e)
                    }
                }
                }
                return result
            } else {
                return NSNumber(value: false)
            }
        }

        if matches("SID") {
            return wpc?.session?.sid
        }

        if key?.hasPrefix("getParameters") == true || key?.hasPrefix("allParameters") == true {
            var rest = key!.substring(from: 13) as NSString
            if rest.length != 0 && rest.character(at: 0) == 0x28 /* '(' */ && rest.character(at: rest.length - 1) == 0x29 /* ')' */ {
                rest = rest.substring(with: NSRange(location: 1, length: rest.length - 2)) as NSString
                var vars: NSMutableDictionary?
                if key!.hasPrefix("getParameters") {
                    vars = InfoTransformer.extractParams(wpc?.GETParams)?.mutableCopy() as? NSMutableDictionary
                }
                if key!.hasPrefix("allParameters") {
                    vars = (wpc?.value(forKey: "parameters") as? NSDictionary)?.mutableCopy() as? NSMutableDictionary
                }

                for pair in rest.components(separatedBy: ",") {
                    let set = (pair as NSString).components(separatedBy: "=") as NSArray
                    if set.count == 2 {
                        if (set.object(at: 1) as! NSString).length != 0 {
                            vars?.setObject(set.object(at: 1), forKey: set.object(at: 0) as! NSString)
                        } else {
                            vars?.removeObject(forKey: set.object(at: 0))
                        }
                    }
                }

                return InfoTransformer.formatParams(vars)
            }

            if key!.hasPrefix("getParameters") {
                return wpc?.GETParams
            }
            if key!.hasPrefix("allParameters") {
                return InfoTransformer.formatParams(wpc?.value(forKey: "parameters") as? NSDictionary)
            }
        }

        return super.value(forKey: key as String?, object: wpc, context: wpcagain)
    }
}

// MARK: - WebPortalUserTransformer

@objc(WebPortalUserTransformer)
public final class WebPortalUserTransformer: WebPortalProxyObjectTransformer {

    @objc public override class func create() -> Any! {
        self.init()
    }

    @objc(valueForKey:object:context:)
    public override func value(forKey key: String!, object user: NSObject!, context wpc: Any!) -> Any! {
        if (key as NSString?)?.isEqual(to: "originalName") == true {
            return user?.value(forKey: "name")
        }

        return super.value(forKey: key, object: user, context: wpc)
    }
}

// MARK: - StringTransformer

@objc(StringTransformer)
public final class StringTransformer: WebPortalProxyObjectTransformer {

    /// iPhoneCompatibleNumericalFormat, whose exported C function stays in
    /// WebPortalResponse+CAPI.mm. // this is to avoid numbers to be interpreted as phone numbers
    static func iPhoneCompatibleNumericalFormat(_ aString: NSString?) -> NSString {
        let newString = NSMutableString()
        var i = 0
        while i < (aString?.length ?? 0) {
            newString.append("<span>")
            append((aString!.substring(with: NSRange(location: i, length: 1)) as NSString).xmlEscapedString(), to: newString)
            newString.append("</span>")
            i += 1
        }
        return newString
    }

    @objc public override class func create() -> Any! {
        self.init()
    }

    @objc(valueForKey:object:context:)
    public override func value(forKey key: String!, object: NSObject!, context wpc: Any!) -> Any! {
        if (key as NSString?)?.isEqual(to: "Spanned") == true {
            return StringTransformer.iPhoneCompatibleNumericalFormat(object as? NSString)
        }

        return super.value(forKey: key, object: object, context: wpc)
    }
}

// MARK: - DateTransformer

@objc(DateTransformer)
public final class DateTransformer: WebPortalProxyObjectTransformer {

    private static let monthNames: [String] = [NSLocalizedString("January", comment: "Month"), NSLocalizedString("February", comment: "Month"), NSLocalizedString("March", comment: "Month"), NSLocalizedString("April", comment: "Month"), NSLocalizedString("May", comment: "Month"), NSLocalizedString("June", comment: "Month"), NSLocalizedString("July", comment: "Month"), NSLocalizedString("August", comment: "Month"), NSLocalizedString("September", comment: "Month"), NSLocalizedString("October", comment: "Month"), NSLocalizedString("November", comment: "Month"), NSLocalizedString("December", comment: "Month")]

    private static func calendarDate(_ interval: TimeInterval) -> NSObject {
        NSDate(timeIntervalSinceReferenceDate: interval)
    }

    private static func component(_ date: NSObject?, _ name: String) -> Int {
        guard let date = date as? Date else { return 0 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = NSTimeZone.default
        let unit: Calendar.Component
        switch name {
        case "yearOfCommonEra": unit = .year
        case "monthOfYear": unit = .month
        case "dayOfMonth": unit = .day
        default: return 0
        }
        return calendar.component(unit, from: date)
    }

    @objc public override class func create() -> Any! {
        self.init()
    }

    @objc(valueForKey:object:context:)
    public override func value(forKey key: String!, object: NSObject!, context wpc: Any!) -> Any! {
        let key = key as NSString?
        let object = object as? NSDate
        if key?.isEqual(to: "DateTime") == true {
            return object.flatMap { UserDefaults.dateTimeFormatter().string(from: $0 as Date) }
        }

        if key?.isEqual(to: "Date") == true {
            return object.flatMap { UserDefaults.dateFormatter().string(from: $0 as Date) }
        }

        if key?.isEqual(to: "Months") == true {
            let monthNames = DateTransformer.monthNames
            let months = NSMutableArray()
            let calDate = object.map { DateTransformer.calendarDate($0.timeIntervalSinceReferenceDate) }
            if object == nil {
                months.add(["value": NSNumber(value: -1 as Int32), "name": NSLocalizedString("Month", comment: "Month") as NSString, "selected": NSNumber(value: true), "disabled": NSNumber(value: true)] as NSDictionary)
            }
            for i in 0..<12 {
                months.add(["value": NSNumber(value: Int32(i)), "name": monthNames[i], "selected": NSNumber(value: DateTransformer.component(calDate, "monthOfYear") == i + 1)] as NSDictionary)
            }
            return months
        }

        if key?.isEqual(to: "Days") == true {
            let days = NSMutableArray()
            let calDate = object.map { DateTransformer.calendarDate($0.timeIntervalSinceReferenceDate) }
            if object == nil {
                days.add(["value": NSNumber(value: 0 as Int32), "name": NSLocalizedString("Day", comment: "Day") as NSString, "selected": NSNumber(value: true), "disabled": NSNumber(value: true)] as NSDictionary)
            }
            for i in 0..<31 {
                days.add(["value": NSNumber(value: Int32(i + 1)), "name": NSNumber(value: Int32(i + 1)), "selected": NSNumber(value: DateTransformer.component(calDate, "dayOfMonth") == i + 1)] as NSDictionary)
            }
            return days
        }

        let NextYears = 5
        if key?.isEqual(to: "NextYears") == true {
            let years = NSMutableArray()
            let calDate = object.map { DateTransformer.calendarDate($0.timeIntervalSinceReferenceDate) }
            let currDate = DateTransformer.calendarDate(Date.timeIntervalSinceReferenceDate)
            let calYear = DateTransformer.component(calDate, "yearOfCommonEra")
            let currYear = DateTransformer.component(currDate, "yearOfCommonEra")
            if calYear < currYear {
                years.add(["value": NSNumber(value: Int32(truncatingIfNeeded: calYear)), "name": NSNumber(value: Int32(truncatingIfNeeded: calYear)), "selected": NSNumber(value: true)] as NSDictionary)
            }
            for i in currYear..<(currYear + NextYears) {
                years.add(["value": NSNumber(value: Int32(truncatingIfNeeded: i)), "name": NSNumber(value: Int32(truncatingIfNeeded: i)), "selected": NSNumber(value: calYear == i)] as NSDictionary)
            }
            if UInt(bitPattern: calYear) >= UInt(bitPattern: currYear + NextYears) {
                years.add(["value": NSNumber(value: Int32(truncatingIfNeeded: calYear)), "name": NSNumber(value: Int32(truncatingIfNeeded: calYear)), "selected": NSNumber(value: true)] as NSDictionary)
            }
            return years
        }

        return super.value(forKey: key as String?, object: object, context: wpc)
    }
}

// MARK: - DicomStudyTransformer

@objc(DicomStudyTransformer)
public final class DicomStudyTransformer: WebPortalProxyObjectTransformer {

    /// Made once, not lazily by the first connection thread that needed it,
    /// where two threads could each make one.
    // nonisolated(unsafe): every use synchronizes on the dictionary itself
    // (objc_sync_enter/objc_sync_exit), as the former @synchronized did.
    nonisolated(unsafe) private static let otherStudiesForThisPatientCache = NSMutableDictionary()
    private static let CACHETIMEOUT: TimeInterval = -30

    @objc public class func clearOtherStudiesForThisPatientCache() {
        let cache = otherStudiesForThisPatientCache
        objc_sync_enter(cache)
        cache.removeAllObjects()
        objc_sync_exit(cache)
    }

    @objc public override class func create() -> Any! {
        self.init()
    }

    private static var pacsOnDemand: Bool {
        UserDefaults.standard.bool(forKey: "searchForComparativeStudiesOnDICOMNodes") && UserDefaults.standard.bool(forKey: "ActivatePACSOnDemandForWebPortalOtherStudies")
    }

    @objc(valueForKey:object:context:)
    public override func value(forKey key: String!, object: NSObject!, context: Any!) -> Any! {
        let wpc = context as? WebPortalConnection
        let study = object as? DicomStudy
        let key = key as NSString?

        if key?.isEqual(to: "XID") == true || key?.isEqual(to: "federatedOrigin") == true || key?.isEqual(to: "permissionLabel") == true {
            let studyDB = DicomDatabase(for: study?.managedObjectContext)
            let portalDB = wpc?.independentDicomDatabase
            let origin = FederatedSearch.displayOrigin(name: studyDB?.name, path: studyDB?.baseDirPath)
            if key?.isEqual(to: "federatedOrigin") == true {
                return origin
            }
            if key?.isEqual(to: "permissionLabel") == true {
                return FederatedSearch.permissionLabel(forPredicate: wpc?.user?.studyPredicate)
            }
            if let studyDB, let portalDB, FederatedSearch.pathsEqual(studyDB.baseDirPath, portalDB.baseDirPath) == false {
                return FederatedSearch.federatedXID(studyXID: study!.xid(), originPath: studyDB.baseDirPath)
            }
        }
        if key?.isEqual(to: "hasKeyImagesOrROIImages") == true {
            if (study?.keyImages()?.count ?? 0) != 0 {
                return NSNumber(value: true)
            }

            if (study?.roiImages()?.count ?? 0) != 0 {
                return NSNumber(value: true)
            }

            return NSNumber(value: false)
        }

        if key?.isEqual(to: "reportIsLink") == true {
            let reportURL = study?.reportURL as NSString?
            return NSNumber(value: reportURL?.hasPrefix("http://") == true || reportURL?.hasPrefix("https://") == true)
        }

        if key?.isEqual(to: "otherStudiesForThisPatient") == true {
            return otherStudies(for: study, wpc: wpc)
        }

        if key?.isEqual(to: "reportExtension") == true {
            var isDir: ObjCBool = false
            if let reportURL = study?.reportURL {
                FileManager.default.fileExists(atPath: reportURL, isDirectory: &isDir)
            }
            return isDir.boolValue ? "zip" as NSString : (study?.reportURL as NSString?)?.pathExtension as NSString?
        }

        if key?.isEqual(to: "stateText") == true {
            guard let stateText = study?.stateText?.int32Value, stateText != 0 else {
                return nil
            }
            return (BrowserController.statesArray() as NSArray).object(at: Int(stateText))
        }

        return super.value(forKey: key as String?, object: study, context: wpc)
    }

    private func otherStudies(for study: DicomStudy?, wpc: WebPortalConnection?) -> NSMutableArray? {
        var otherStudies: NSMutableArray?
        let patientID = study?.patientID

        // Cache system for comparative studies, if PACS On Demand is activated
        if DicomStudyTransformer.pacsOnDemand {
            let cache = DicomStudyTransformer.otherStudiesForThisPatientCache
            var failure: Error?
            objc_sync_enter(cache)
            do {
                try HorosObjCException.perform {
                    // REMOVE OLD KEYS
                    let keysToRemove = NSMutableArray()
                    for key in cache.allKeys {
                        if (((cache.object(forKey: key) as? NSDictionary)?.object(forKey: "timeStamp") as? NSDate)?.timeIntervalSinceNow ?? 0) < DicomStudyTransformer.CACHETIMEOUT {
                            keysToRemove.add(key)
                        }
                    }
                    if keysToRemove.count != 0 {
                        cache.removeObjects(forKeys: keysToRemove as! [Any])
                    }

                    if let patientID, let d = cache.object(forKey: patientID) as? NSDictionary {
                        let timeStamp = d.object(forKey: "timeStamp") as? NSDate

                        if (timeStamp?.timeIntervalSinceNow ?? 0) > DicomStudyTransformer.CACHETIMEOUT {
                            let db = WebPortal.default()?.threadDicomDatabase()
                            otherStudies = NSMutableArray(array: db?.objects(withIDs: d.object(forKey: "studyIDs") as? [Any]) ?? [])
                        }
                    }
                }
            } catch {
                failure = error
            }
            objc_sync_exit(cache)
            if let e = (failure as NSError?)?.userInfo[HorosObjCExceptionKey] as? NSException {
                _N2LogExceptionImpl(e, true, "-[DicomStudyTransformer valueForKey:object:context:]")
            }
        }

        if otherStudies == nil {
            do {
                try HorosObjCException.perform {
                    // predicateWithFormat: made a nil argument the nil constant.
                    let predicate = patientID.map { NSPredicate(format: "(patientID == %@)", $0) } ?? NSPredicate(format: "(patientID == nil)")
                    otherStudies = (WebPortalUser.studies(for: wpc?.user, predicate: predicate, sortBy: "date") as NSArray?)?.mutableCopy() as? NSMutableArray

                    // PACS On Demand
                    if DicomStudyTransformer.pacsOnDemand {
                        let usePatientID = UserDefaults.standard.bool(forKey: "UsePatientIDForUID")
                        let usePatientBirthDate = UserDefaults.standard.bool(forKey: "UsePatientBirthDateForUID")
                        let usePatientName = UserDefaults.standard.bool(forKey: "UsePatientNameForUID")

                        // Servers
                        let servers = BrowserController.comparativeServers() as NSArray?

                        if (servers?.count ?? 0) != 0 {
                            // Distant studies
                            let distantStudies = QueryController.queryStudies(forPatient: study, usePatientID: usePatientID, usePatientName: usePatientName, usePatientBirthDate: usePatientBirthDate, servers: servers as? [Any], showErrors: false) as NSArray?

                            // Merge local and distant studies
                            for distantStudyObject in distantStudies ?? [] {
                                let distantStudy = unsafeBitCast(distantStudyObject as AnyObject, to: WebPortalListedStudy.self)
                                let studyInstanceUID = distantStudy.studyInstanceUID()
                                let studyInstanceUIDs = otherStudies?.value(forKey: "studyInstanceUID") as? NSArray
                                if !(studyInstanceUID.map { studyInstanceUIDs?.contains($0) == true } ?? false) && (distantStudy.noFiles()?.intValue ?? 0) > 0 {
                                    otherStudies?.add(distantStudyObject)
                                } else if UserDefaults.standard.bool(forKey: "preferStudyWithMoreImages"), let otherStudies {
                                    let index = studyInstanceUID.map { (otherStudies.value(forKey: "studyInstanceUID") as! NSArray).index(of: $0) } ?? NSNotFound

                                    if index != NSNotFound
                                        && (unsafeBitCast(otherStudies.object(at: index) as AnyObject, to: WebPortalListedStudy.self).rawNoFiles()?.int32Value ?? 0) < (distantStudy.noFiles()?.int32Value ?? 0) {
                                        otherStudies.replaceObject(at: index, with: distantStudyObject)
                                    }
                                }
                            }
                        }
                    }
                }
            } catch {
                if let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                    NSLog("***** [WebPortalResponse object:valueForKeyPath:context] %@", e)
                }
            }

            otherStudies?.sort(using: [NSSortDescriptor(key: "date", ascending: false)])
        }
        // Cache system for comparative studies, if PACS On Demand is activated
        if DicomStudyTransformer.pacsOnDemand {
            let cache = DicomStudyTransformer.otherStudiesForThisPatientCache
            var failure: Error?
            objc_sync_enter(cache)
            do {
                try HorosObjCException.perform {
                    let d = NSMutableDictionary()
                    d.setObject(NSDate(), forKey: "timeStamp" as NSString)
                    // dictionaryWithObjectsAndKeys: stopped at a nil value.
                    // The IDs of the local studies and the distant studies
                    // themselves, which have no objectID: -valueForKey:
                    // @"objectID" raised on the first one. -objectsWithIDs:
                    // answers them as they are.
                    if let otherStudies {
                        d.setObject(WebPortalUser.cachedArray(for: otherStudies) as Any, forKey: "studyIDs" as NSString)
                    }
                    // A patient without an ID has no entry (-setObject:forKey:
                    // raised on the nil key).
                    if let patientID {
                        cache.setObject(d.copy(), forKey: patientID as NSString)
                    }
                }
            } catch {
                failure = error
            }
            objc_sync_exit(cache)
            // Caching is an optimisation: a failure to cache the list used to
            // answer nil, and the page showed no other study at all.
            if let e = (failure as NSError?)?.userInfo[HorosObjCExceptionKey] as? NSException {
                _N2LogExceptionImpl(e, true, "-[DicomStudyTransformer valueForKey:object:context:]")
            }
        }

        return otherStudies
    }
}

// MARK: - DicomSeriesTransformer

@objc(DicomSeriesTransformer)
public final class DicomSeriesTransformer: WebPortalProxyObjectTransformer {

    private var size = NSSize(width: -1, height: -1)

    public required init() {
        super.init()
    }

    @objc public override class func create() -> Any! {
        self.init()
    }

    @objc(valueForKey:object:context:)
    public override func value(forKey key: String!, object: NSObject!, context: Any!) -> Any! {
        let wpc = context as? WebPortalConnection
        let series = object as? DicomSeries
        let key = key as NSString?

        if key?.isEqual(to: "seriesExtension") == true {
            if DCMAbstractSyntaxUID.isPDF(series?.seriesSOPClassUID) || DCMAbstractSyntaxUID.isStructuredReport(series?.seriesSOPClassUID) {
                return ".pdf" as NSString
            }
            return "" as NSString
        }

        if key?.isEqual(to: "stateText") == true {
            if let stateText = series?.stateText?.int32Value, stateText != 0 {
                return (BrowserController.statesArray() as NSArray).object(at: Int(stateText))
            }
            return nil
        }

        /*if ([key isEqualToString:@"noFiles"]) {
            return [NSNumber numberWithInt:[[series performSelector:@selector(noFiles)] intValue]];
        }*/

        if key?.isEqual(to: "width") == true || key?.isEqual(to: "height") == true {
            if size.height == -1 {
                let images = (series?.value(forKey: "images") as? NSSet)?.allObjects ?? []
                var width = size.width
                var height = size.height

                if images.count > 1 {
                    if wpc?.requestIsIPhone() ?? false {
                        wpc?.getWidth(&width, height: &height, fromImagesArray: images as NSArray, minSize: NSSize(width: 256, height: 256), maxSize: NSSize(width: 290, height: 290))
                    } else {
                        wpc?.getWidth(&width, height: &height, fromImagesArray: images as NSArray)
                        if !(wpc?.requestIsIOS() ?? false) {
                            height += 15 // controller height (quicktime, flash)
                        }
                    }
                } else {
                    wpc?.getWidth(&width, height: &height, fromImagesArray: images as NSArray)
                }

                size = NSSize(width: width, height: height)
            }
            if key?.isEqual(to: "width") == true {
                return NSNumber(value: cInt(size.width))
            }
            if key?.isEqual(to: "height") == true {
                return NSNumber(value: cInt(size.height))
            }
        }

        return super.value(forKey: key as String?, object: series, context: wpc)
    }
}

// MARK: - NSMutableDictionary (WebPortalProxy)

private let MessagesArrayTokenKey = "Messages"
private let ErrorsArrayTokenKey = "Errors"

public extension NSMutableDictionary {

    @objc func errors() -> NSMutableArray! {
        var errors = object(forKey: ErrorsArrayTokenKey) as AnyObject?
        if !objcIsKind(errors, NSMutableArray.self) {
            errors = NSMutableArray()
            setObject(errors!, forKey: ErrorsArrayTokenKey as NSString)
        }

        return (errors as! NSMutableArray)
    }

    @objc(addError:)
    func addError(_ error: String!) {
        objcAdd(error as NSString?, to: errors())
    }

    @objc(addMessage:)
    func addMessage(_ message: String!) {
        var messages = object(forKey: MessagesArrayTokenKey) as AnyObject?
        if !objcIsKind(messages, NSMutableArray.self) {
            messages = NSMutableArray()
            setObject(messages!, forKey: MessagesArrayTokenKey as NSString)
        }

        objcAdd(message as NSString?, to: messages as! NSMutableArray)
    }
}

/// -[NSMutableArray addObject:], which raises on nil as before.
private func objcAdd(_ object: NSString?, to array: NSMutableArray) {
    if let object {
        array.add(object)
    } else {
        array.perform(#selector(NSMutableArray.add(_:)), with: nil)
    }
}
