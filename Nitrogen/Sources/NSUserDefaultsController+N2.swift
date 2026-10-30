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

import AppKit

// NSUserDefaultsController (N2) and NSObject (N2ValuesBinding) are
// implemented in Swift; the selectors and
// <Horos/NSUserDefaultsController+N2.h> are those of the former categories,
// less the NSObject (N2ValuesBinding) members nothing called.
// The accessors read and write the controller's values proxy, as
// [self.values valueForKey:] did, and are nonisolated: the preferences of
// NSUserDefaults (OsiriX) call them on any thread.

@objc(N2) @implementation extension NSUserDefaultsController {
    /// The values proxy, which reads and writes the defaults (or the
    /// controller's buffer when it does not apply changes at once).
    private nonisolated var valuesProxy: AnyObject? {
        value(forKey: "values") as AnyObject?
    }

    private nonisolated func storedValue(_ key: String?) -> Any? {
        guard let key else { return nil }
        return valuesProxy?.value(forKey: key)
    }

    private nonisolated func store(_ value: Any?, _ key: String?) {
        guard let key else { return }
        valuesProxy?.setValue(value, forKey: key)
    }

    // The values of a class: nil for one of another class.

    nonisolated func string(forKey defaultName: String!) -> String! {
        storedValue(defaultName) as? NSString as String?
    }

    nonisolated func array(forKey defaultName: String!) -> [Any]! {
        storedValue(defaultName) as? NSArray as? [Any]
    }

    nonisolated func dictionary(forKey defaultName: String!) -> [AnyHashable: Any]! {
        storedValue(defaultName) as? NSDictionary as? [AnyHashable: Any]
    }

    nonisolated func data(forKey defaultName: String!) -> Data! {
        storedValue(defaultName) as? NSData as Data?
    }

    // The numbers of an NSNumber or an NSString, the values that answer
    // -integerValue, -floatValue, -doubleValue and -boolValue; 0 otherwise.

    nonisolated func integer(forKey defaultName: String!) -> Int {
        switch storedValue(defaultName) {
        case let number as NSNumber: return number.intValue
        case let string as NSString: return string.integerValue
        default: return 0
        }
    }

    nonisolated func float(forKey defaultName: String!) -> Float {
        switch storedValue(defaultName) {
        case let number as NSNumber: return number.floatValue
        case let string as NSString: return string.floatValue
        default: return 0
        }
    }

    nonisolated func double(forKey defaultName: String!) -> Double {
        switch storedValue(defaultName) {
        case let number as NSNumber: return number.doubleValue
        case let string as NSString: return string.doubleValue
        default: return 0
        }
    }

    nonisolated func bool(forKey defaultName: String!) -> Bool {
        switch storedValue(defaultName) {
        case let number as NSNumber: return number.boolValue
        case let string as NSString: return string.boolValue
        default: return false
        }
    }

    // An object of another class, nil included, raises
    // NSInvalidArgumentException, as before.

    nonisolated func setString(_ str: String!, forKey defaultName: String!) {
        guard let str else { raiseInvalidValue("NSString") }
        store(str, defaultName)
    }

    nonisolated func setArray(_ arr: [Any]!, forKey defaultName: String!) {
        guard let arr else { raiseInvalidValue("NSArray") }
        store(arr, defaultName)
    }

    nonisolated func setDictionary(_ dic: [AnyHashable: Any]!, forKey defaultName: String!) {
        guard let dic else { raiseInvalidValue("NSDictionary") }
        store(dic, defaultName)
    }

    nonisolated func setData(_ dat: Data!, forKey defaultName: String!) {
        guard let dat else { raiseInvalidValue("NSData") }
        store(dat, defaultName)
    }

    nonisolated func setInteger(_ i: Int, forKey defaultName: String!) {
        store(NSNumber(value: i), defaultName)
    }

    nonisolated func setFloat(_ f: Float, forKey defaultName: String!) {
        store(NSNumber(value: f), defaultName)
    }

    nonisolated func setDouble(_ d: Double, forKey defaultName: String!) {
        store(NSNumber(value: d), defaultName)
    }

    nonisolated func setBool(_ flag: Bool, forKey defaultName: String!) {
        store(NSNumber(value: flag), defaultName)
    }
}

/// `[NSException raise:NSInvalidArgumentException format:@"Value must be of class …"]`.
private func raiseInvalidValue(_ className: String) -> Never {
    NSException(name: .invalidArgumentException, reason: "Value must be of class \(className)", userInfo: nil).raise()
    fatalError("NSException.raise() returned")
}

/// "values." and the key: the key path of a preference through
/// NSUserDefaultsController's values proxy.
@_cdecl("valuesKeyPath") @implementation
func valuesKeyPath(_ key: String!) -> String! {
    "values." + (key ?? "")
}

/// The observation of a preference through NSUserDefaultsController's values
/// proxy. Swift only: no Objective-C file observes through it.
extension NSObject {
    @objc(addObserver:forValuesKey:options:context:)
    func addObserver(_ observer: NSObject, forValuesKey key: String, options: NSKeyValueObservingOptions,
                     context: UnsafeMutableRawPointer?) {
        addObserver(observer, forKeyPath: valuesKeyPath(key), options: options, context: context)
    }

    /// Removing an observer that is not registered raises; the exception is
    /// logged, as before.
    @objc(removeObserver:forValuesKey:)
    func removeObserver(_ observer: NSObject, forValuesKey key: String) {
        do {
            try HorosObjCException.perform {
                self.removeObserver(observer, forKeyPath: valuesKeyPath(key))
            }
        } catch {
            _N2LogExceptionImpl((error as NSError).userInfo[HorosObjCExceptionKey] as? NSException, false,
                                "-[NSObject(N2ValuesBinding) removeObserver:forValuesKey:]")
        }
    }
}
