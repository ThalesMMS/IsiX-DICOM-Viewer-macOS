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

// What the database, album and search extensions of BrowserController need
// from Objective-C that Swift does not write the same way: @try, @synchronized
// and the variadic logging functions of N2Debug.h.
enum BrowserObjC {

    /// Runs `body` as an @try block: the NSException it raises is returned.
    static func attempt(_ body: () -> Void) -> NSException? {
        do {
            try HorosObjCException.perform(body)
        } catch {
            return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
        }
        return nil
    }

    /// `@synchronized (object) { … }`: the same recursive lock, taken on
    /// nothing when the object is nil, and left before an exception raised
    /// inside goes on.
    static func synchronized<T>(_ object: AnyObject?, _ body: () -> T) -> T {
        guard let object else { return body() }
        objc_sync_enter(object)
        var result: T?
        let raised = attempt { result = body() }
        objc_sync_exit(object)
        if let raised { raised.raise() }
        return result!
    }

    /// N2LogException(e) and N2LogExceptionWithStackTrace(e), naming the
    /// former Objective-C method.
    static func log(_ exception: NSException, stack: Bool = false, _ function: String) {
        _N2LogExceptionImpl(exception, stack, function)
    }

    /// N2LogStackTrace(message): the message with the stack of an exception
    /// raised for the purpose.
    static func logStackTrace(_ message: String) {
        if let exception = attempt({ NSException(name: .genericException, reason: "", userInfo: nil).raise() }) {
            NSLog("%@", message)
            _N2LogExceptionImpl(exception, true, "")
        }
    }

    /// N2LogError(message) in the former Objective-C method.
    static func logError(_ message: String, _ function: String, file: String = #file, line: Int = #line) {
        DicomDatabaseLogError(function, file, Int32(line), message)
    }

    /// `[NSDictionary dictionaryWithObjectsAndKeys: …, nil]`: the list ends at
    /// the first nil.
    static func dictionary(_ pairs: Any?...) -> NSDictionary {
        let dictionary = NSMutableDictionary()
        var index = 0
        while index + 1 < pairs.count {
            guard let object = pairs[index], let key = pairs[index + 1] as? NSCopying else { break }
            dictionary.setObject(object, forKey: key)
            index += 2
        }
        return dictionary
    }

    /// `[value intValue]` of a number or a string; 0 for nil and the rest.
    static func intValue(_ value: Any?) -> Int32 {
        if let number = value as? NSNumber { return number.int32Value }
        if let string = value as? NSString { return string.intValue }
        return 0
    }

    /// `[a isEqualToString: b]`: code unit by code unit, and never for nil.
    static func literallyEqual(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a.utf16.elementsEqual(b.utf16)
    }

    /// N2LocalizedSingularPluralCount(count, singular, plural).
    static func singularPlural(_ count: Int, _ singular: String, _ plural: String) -> String {
        return String(format: "%@ %@", NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal),
                      count == 1 ? singular : plural)
    }
}
