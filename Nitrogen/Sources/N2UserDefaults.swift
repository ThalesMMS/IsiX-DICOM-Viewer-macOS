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

/// A persistent domain of NSUserDefaults, named by a bundle identifier.
/// Deprecated, as it was.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/N2UserDefaults.h> are those of the former class.
@objc(N2UserDefaults)
public final class N2UserDefaults: NSObject {
    /// Guards `defaultsByIdentifier`: plugins ask for their defaults from any
    /// thread.
    private static let defaultsLock = NSLock()
    // nonisolated(unsafe): read and changed only inside `defaultsLock.withLock`.
    nonisolated(unsafe) private static let defaultsByIdentifier = NSMutableDictionary(capacity: 4)

    private let dictionary: NSMutableDictionary
    private var _autosave = false
    private var needsAutosave = false

    /// Atomic in the former header; set once, in init.
    @objc public let identifier: String?

    @objc public var autosave: Bool {
        get { return _autosave }
        set {
            _autosave = newValue
            if _autosave && needsAutosave {
                save()
            }
            needsAutosave = false
        }
    }

    @available(*, deprecated)
    @objc(defaultsForObject:)
    public static func defaults(forObject o: Any) -> N2UserDefaults {
        return defaults(forClass: type(of: o as AnyObject))
    }

    @available(*, deprecated)
    @objc(defaultsForClass:)
    public static func defaults(forClass c: AnyClass) -> N2UserDefaults {
        return defaults(forIdentifier: Bundle(for: c).bundleIdentifier)
    }

    @available(*, deprecated)
    @objc(defaultsForIdentifier:)
    public static func defaults(forIdentifier identifier: String?) -> N2UserDefaults {
        if let identifier = identifier, let defaults = defaultsLock.withLock({ defaultsByIdentifier.object(forKey: identifier) as? N2UserDefaults }) {
            return defaults
        }

        let defaults = N2UserDefaults(identifier: identifier)
        guard let identifier = identifier else {
            // -[NSMutableDictionary setObject:forKey:] raised for a nil key.
            NSException(name: .invalidArgumentException,
                        reason: "*** -[__NSDictionaryM setObject:forKey:]: key cannot be nil",
                        userInfo: nil).raise()
            return defaults
        }
        return defaultsLock.withLock {
            // Another thread may have made them meanwhile: that one is kept.
            if let existing = defaultsByIdentifier.object(forKey: identifier) as? N2UserDefaults { return existing }
            defaultsByIdentifier.setObject(defaults, forKey: identifier as NSString)
            return defaults
        }
    }

    @available(*, deprecated)
    @objc(initWithIdentifier:)
    public init(identifier: String?) {
        self.identifier = identifier
        if let identifier = identifier, let domain = UserDefaults.standard.persistentDomain(forName: identifier) {
            dictionary = NSMutableDictionary(dictionary: domain)
        } else {
            dictionary = NSMutableDictionary()
        }
        needsAutosave = false
        super.init()
        autosave = true
    }

    /// Not in the header; kept reachable by its selector.
    @objc public func save() {
        guard let identifier = identifier else { return }
        UserDefaults.standard.setPersistentDomain(dictionary as! [String: Any], forName: identifier)
    }

    @available(*, deprecated)
    @objc(objectForKey:)
    public func object(forKey key: String) -> Any? {
        return dictionary.object(forKey: key)
    }

    @available(*, deprecated)
    @objc(hasObjectForKey:)
    public func hasObject(forKey key: String) -> Bool {
        return object(forKey: key) != nil
    }

    @available(*, deprecated)
    @objc(setObject:forKey:)
    public func setObject(_ obj: Any, forKey key: String) {
        dictionary.setObject(obj, forKey: key as NSString)
        if _autosave { save() }
        else { needsAutosave = true }
    }

    @available(*, deprecated)
    @objc(integerForKey:default:)
    public func integer(forKey key: String, default def: Int) -> Int {
        if let value = object(forKey: key) as? NSNumber { return value.intValue }
        return def
    }

    @available(*, deprecated)
    @objc(setInteger:forKey:)
    public func setInteger(_ value: Int, forKey key: String) {
        setObject(NSNumber(value: value), forKey: key)
    }

    @available(*, deprecated)
    @objc(floatForKey:default:)
    public func float(forKey key: String, default def: Float) -> Float {
        if let value = object(forKey: key) as? NSNumber { return value.floatValue }
        return def
    }

    @available(*, deprecated)
    @objc(setFloat:forKey:)
    public func setFloat(_ value: Float, forKey key: String) {
        setObject(NSNumber(value: value), forKey: key)
    }

    @available(*, deprecated)
    @objc(doubleForKey:default:)
    public func double(forKey key: String, default def: Double) -> Double {
        if let value = object(forKey: key) as? NSNumber { return value.doubleValue }
        return def
    }

    @available(*, deprecated)
    @objc(setDouble:forKey:)
    public func setDouble(_ value: Double, forKey key: String) {
        setObject(NSNumber(value: value), forKey: key)
    }

    @available(*, deprecated)
    @objc(boolForKey:default:)
    public func bool(forKey key: String, default def: Bool) -> Bool {
        if let value = object(forKey: key) as? NSNumber { return value.boolValue }
        return def
    }

    @available(*, deprecated)
    @objc(setBool:forKey:)
    public func setBool(_ value: Bool, forKey key: String) {
        setObject(NSNumber(value: value), forKey: key)
    }

    @available(*, deprecated)
    @objc(unarchiveObjectForKey:default:class:)
    public func unarchiveObject(forKey key: String, default def: Any?, class c: AnyClass) -> Any? {
        // NSArchiver data, decoded with only the class asked for (and its
        // superclasses) and the property list classes; the class the value
        // names is no longer instantiated before it is checked.
        if let value = object(forKey: key) as? Data,
           let unarchivedValue = RestrictedUnarchiver.unarchiveObject(with: value, ofClass: c) {
            return unarchivedValue
        }
        return def
    }

    @available(*, deprecated)
    @objc(archiveAndSetObject:forKey:)
    public func archiveAndSetObject(_ value: Any, forKey key: String) {
        // Compatibility: this deprecated SDK API shares a persistent domain with
        // released plugins whose readers accept only typedstreams. Keep its format.
        setObject(NSArchiver.archivedData(withRootObject: value), forKey: key)
    }

    @available(*, deprecated)
    @objc(colorForKey:default:)
    public func color(forKey key: String, default def: NSColor?) -> NSColor? {
        return unarchiveObject(forKey: key, default: def, class: NSColor.self) as? NSColor
    }

    @available(*, deprecated)
    @objc(setColor:forKey:)
    public func setColor(_ value: NSColor, forKey key: String) {
        archiveAndSetObject(value, forKey: key)
    }

    @available(*, deprecated)
    @objc(rectForKey:default:)
    public func rect(forKey key: String, default def: NSRect) -> NSRect {
        if let value = object(forKey: key) as? NSValue { return value.rectValue }
        return def
    }

    @available(*, deprecated)
    @objc(setRect:forKey:)
    public func setRect(_ value: NSRect, forKey key: String) {
        setObject(NSValue(rect: value), forKey: key)
    }
}
