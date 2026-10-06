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
import Synchronization

/// DLog of N2Debug.h: NSLog in a DEBUG build, otherwise only while N2Debug is
/// active.
fileprivate func n2WebServiceClientDLog(_ format: String, _ arguments: CVarArg...) {
    #if DEBUG
    withVaList(arguments) { NSLogv(format, $0) }
    #else
    if N2Debug.isActive() { withVaList(arguments) { NSLogv(format, $0) } }
    #endif
}

/// A synchronous HTTP client of one URL. Failures raise an NSException, as
/// before: Objective-C callers catch it, and N2RedundantWebServiceClient tries
/// its next URL.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/N2WebServiceClient.h> are those of the former class. The HTTPMethod
/// enum stays in the header.
@objc(N2WebServiceClient)
open class N2WebServiceClient: NSObject {
    /// Atomic in the former header; an object reference is read and written
    /// as one word.
    @objc open var url: URL?

    @objc public override init() {
        super.init()
    }

    @objc(initWithURL:)
    public init(url: URL?) {
        super.init()
        self.url = url
    }

    /// Not in the header; kept reachable by its selector. The parameters are
    /// joined in the dictionary's own order, as "&key=value" with percent
    /// escapes, or nil for none.
    @objc(parametersToString:)
    public class func parametersToString(_ params: NSDictionary?) -> String? {
        if let params = params, params.count != 0 {
            let paramsString = NSMutableString(capacity: 512)

            for (key, value) in params {
                // Sent by message, as before: an object that is not a string
                // raises the same exception.
                guard let keyString = key as? String, let valueString = value as? String else {
                    let invalid = key is NSString ? value : key
                    (invalid as AnyObject).doesNotRecognizeSelector(#selector(NSString.addingPercentEncoding(withAllowedCharacters:)))
                    return nil
                }
                // Query/form components: in particular a literal '+' must not
                // become a form space, and '&'/'=' must not delimit new fields.
                let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
                let escapedKey = keyString.addingPercentEncoding(withAllowedCharacters: allowed)
                let escapedValue = valueString.addingPercentEncoding(withAllowedCharacters: allowed)
                paramsString.append("&\(escapedKey ?? "(null)")=\(escapedValue ?? "(null)")")
            }

            return paramsString as String
        }

        return nil
    }

    @objc(requestWithURL:method:content:headers:context:)
    @discardableResult
    open func request(with url: URL?, method: HTTPMethod, content: Data?, headers: NSDictionary?, context: Any?) -> Data? {
        var url = url
        var content = content
        if method == HTTPGet, let body = content {
            // A nil string printed as "(null)" in the format, as before.
            let contentString = NSString(data: body, encoding: String.Encoding.utf8.rawValue)
            if let original = url, var components = URLComponents(url: original, resolvingAgainstBaseURL: false) {
                // Parameters replace the prior query, as before. They are
                // already encoded by parametersToString; encode no second time.
                let query = contentString?.substring(from: 1) ?? "(null)"
                // Public request callers can supply an unescaped query body.
                // Normalize invalid characters while preserving existing escapes;
                // percentEncodedQuery itself requires a valid encoded string.
                components.percentEncodedQuery = URLComponents(string: "?" + query)?.percentEncodedQuery
                url = components.url
            }
            content = nil
        }

        let processed = processUrl(url, context: context)
        let request: NSMutableURLRequest
        if let processed = processed {
            request = NSMutableURLRequest(url: processed, cachePolicy: .reloadIgnoringCacheData, timeoutInterval: 5)
        } else {
            request = NSMutableURLRequest()
            request.cachePolicy = .reloadIgnoringCacheData
            request.timeoutInterval = 5
        }
        request.httpMethod = method == HTTPGet ? "GET" : "POST"

        if let content = content { request.httpBody = content }
        request.setValue(content.map { String(format: "%u", Int32(truncatingIfNeeded: $0.count)) }, forHTTPHeaderField: "Content-Length")
        request.setValue("text/xml", forHTTPHeaderField: "Content-Type")
        if let headers = headers {
            for (key, value) in headers {
                request.setValue(value as? String, forHTTPHeaderField: key as! String)
            }
        }

        request.timeoutInterval = 10

        n2WebServiceClientDLog("Sending %@ request to %@: %@", request.httpMethod as NSString,
                               (request.url as NSURL?) ?? ("(null)" as NSString),
                               content.flatMap { NSString(data: $0, encoding: String.Encoding.utf8.rawValue) } ?? ("(null)" as NSString))

        var response: URLResponse? = nil
        let result: Data?
        do {
            (result, response) = try N2WebServiceClient.sendSynchronously(request as URLRequest)
        } catch {
            NSException.raise(.genericException,
                              format: "[N2WebServiceClient requestWithURL:method:parameters:content:headers:] failed with error: %@",
                              arguments: getVaList([(error as NSError).description as NSString]))
            return nil
        }

        if let http = response as? HTTPURLResponse, http.statusCode / 100 != 2 { // HTTP status code ≠ (200 to 299)
            NSException.raise(.genericException,
                              format: "[N2WebServiceClient requestWithURL:method:parameters:content:headers:] failed with status %d",
                              arguments: getVaList([Int32(truncatingIfNeeded: http.statusCode)]))
        }

        if !validateResult(result) {
            let text: NSString = result.flatMap { NSString(data: $0, encoding: String.Encoding.utf8.rawValue) } ?? "(null)"
            NSException.raise(.genericException,
                              format: "[N2WebServiceClient requestWithURL:method:parameters:content:headers:] received invalid result: %@",
                              arguments: getVaList([text]))
        }

//        NSLog(@"\tResult: %@", [[[NSString alloc] initWithData:result encoding:NSUTF8StringEncoding]autorelease]);

        return result
    }

    /// What the former connection API's sendSynchronousRequest did, over URLSession: the
    /// calling thread waits, and the answer is delivered on the session's own
    /// queue, never on the caller's, so a call made on the main thread does not
    /// wait for work queued behind itself. An HTTP status is not an error here,
    /// as it was not there; the caller reads it off the response.
    static func sendSynchronously(_ request: URLRequest) throws -> (Data?, URLResponse?) {
        let done = DispatchSemaphore(value: 0)
        let reply = SynchronousReply()
        let task = URLSession.shared.dataTask(with: request) { answer, response, error in
            reply.outcome.withLock { $0 = (answer, response, error) }
            done.signal()
        }
        task.resume()
        done.wait()
        let (data, response, failure) = reply.outcome.withLock { $0 } ?? (nil, nil, nil)
        if let failure {
            throw failure
        }
        return (data ?? Data(), response)
    }

    /// What the session's queue hands to the waiting caller: written once
    /// before the semaphore is signalled, read once after the wait.
    private final class SynchronousReply: Sendable {
        let outcome = Mutex<(Data?, URLResponse?, (any Error)?)?>(nil)
    }

    @objc(requestWithMethod:content:headers:context:)
    @discardableResult
    open func request(with method: HTTPMethod, content: Data?, headers: NSDictionary?, context: Any?) -> Data? {
        return request(with: url, method: method, content: content, headers: headers, context: context)
    }

    @objc(requestWithMethod:content:headers:)
    @discardableResult
    open func request(with method: HTTPMethod, content: Data?, headers: NSDictionary?) -> Data? {
        return request(with: method, content: content, headers: headers, context: nil)
    }

    @objc(getWithParameters:)
    @discardableResult
    open func get(withParameters params: NSDictionary?) -> Data? {
        return request(with: HTTPGet, content: N2WebServiceClient.parametersToString(params)?.data(using: .utf8), headers: nil, context: nil)
    }

    @objc(postWithContent:)
    @discardableResult
    open func post(withContent content: Data?) -> Data? {
        return request(with: HTTPPost, content: content, headers: nil, context: nil)
    }

    @objc(postWithParameters:)
    @discardableResult
    open func post(withParameters params: NSDictionary?) -> Data? {
        return post(withContent: N2WebServiceClient.parametersToString(params)?.data(using: .utf8))
    }

    @objc(processUrl:context:)
    open func processUrl(_ url: URL?, context: Any?) -> URL? {
        return url
    }

    @objc(validateResult:)
    open func validateResult(_ result: Data?) -> Bool {
        return true
    }
}
