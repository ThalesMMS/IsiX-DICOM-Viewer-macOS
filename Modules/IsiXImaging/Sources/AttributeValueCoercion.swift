/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, �version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. �See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. �If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: � OsiriX
 �Copyright (c) OsiriX Team
 �All rights reserved.
 �Distributed under GNU - LGPL
 �
 �See http://www.osirix-viewer.com/copyright.html for details.
 � � This software is distributed WITHOUT ANY WARRANTY; without even
 � � the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 � � PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

/// The guards that stand between a parsed value and a typed field.
///
/// A metadata value is whatever class the parser chose for the value
/// representation the file declared. A file that declares OB where the standard
/// says DS hands back NSData, and asking NSData for floatValue is an
/// unrecognised selector: the process dies without naming the attribute that
/// did it. Measured through the framework itself, on an object whose window
/// centre and width are stored as OB:
///
///     WindowCenter    NSConcreteMutableData   floatValue=NO
///
/// A value that cannot answer for a number is not turned into one. It is named,
/// and the attribute is treated as absent.
enum AttributeValueCoercion {
    static func fileName(_ file: String?) -> String {
        guard let file else { return "(null)" }
        return (file as NSString).lastPathComponent
    }

    private static func className(_ object: AnyObject) -> String {
        NSStringFromClass(type(of: object))
    }

    /// The value, when it can answer for a number; nil otherwise, with the
    /// attribute named.
    static func numberValue(_ source: DICOMAttributeSource, _ name: String, file: String?) -> AnyObject? {
        guard let value = ParsedValue.object(source.attributeValue(withName: name)) else { return nil }
        if let object = value as? NSObject, object.responds(to: #selector(getter: NSNumber.floatValue)) {
            return value
        }
        NSLog("---- %@: %@ is stored as %@, which is not a number; the attribute is ignored",
              fileName(file), name, className(value))
        return nil
    }

    /// The same promise, for the attributes held as text. A value parsed as
    /// NSData assigned to one of them is a lie that surfaces later, where it is
    /// interpolated into a string or sent -floatValue: the reports carry
    /// -[NSMutableData floatValue] and -[NSString initWithString:nil] from
    /// exactly that. A number is text a person can read, so it is turned into
    /// text; bytes this cannot name are refused, with the tag named.
    static func stringValue(_ source: DICOMAttributeSource, _ name: String, file: String?) -> String? {
        guard let value = ParsedValue.object(source.attributeValue(withName: name)) else { return nil }
        if let string = value as? NSString { return string as String }
        if let number = value as? NSNumber { return number.stringValue }
        NSLog("---- %@: %@ is stored as %@, which is not text; the attribute is ignored",
              fileName(file), name, className(value))
        return nil
    }

    /// And for the attributes held as numbers.
    static func numberObject(_ source: DICOMAttributeSource, _ name: String, file: String?) -> NSNumber? {
        guard let value = numberValue(source, name, file: file) else { return nil }
        if let number = value as? NSNumber { return number }
        return NSNumber(value: (try? ParsedValue.double(value)) ?? 0)
    }

    /// The same for an attribute that carries several numbers: an element of
    /// the array is whatever class the value representation produced, so a
    /// position stored as OB gives three NSData where three numbers are wanted.
    static func number(in values: [Any], at index: Int, name: String, file: String?) -> Double {
        guard index < values.count else { return 0 }
        let value = values[index] as AnyObject
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? NSString { return string.doubleValue }
        NSLog("---- %@: %@ is stored as %@, which is not a number; the attribute is ignored",
              fileName(file), name, className(value))
        return 0
    }

    /// The number a guarded value holds, read as the field's type reads it.
    static func float(_ value: AnyObject?) -> Float { (try? ParsedValue.float(value)) ?? 0 }
    static func double(_ value: AnyObject?) -> Double { (try? ParsedValue.double(value)) ?? 0 }
    static func int(_ value: AnyObject?) -> Int32 { (try? ParsedValue.int(value)) ?? 0 }
}

/// The guards, for Objective-C code that reads a parsed object itself.
@objc(IsiXDICOMAttributeValues)
public final class DICOMAttributeValues: NSObject {
    /// The value, when it can answer for a number; nil otherwise, logged with
    /// the attribute and the file named.
    @objc(numberValueOf:name:file:)
    public static func numberValue(of source: DICOMAttributeSource, name: String, file: String?) -> Any? {
        AttributeValueCoercion.numberValue(source, name, file: file)
    }

    /// The value as text: a string as it is, a number as its digits, and nil,
    /// logged, for anything else.
    @objc(stringValueOf:name:file:)
    public static func stringValue(of source: DICOMAttributeSource, name: String, file: String?) -> String? {
        AttributeValueCoercion.stringValue(source, name, file: file)
    }

    /// The value as a number object, or nil, logged, when it cannot be one.
    @objc(numberObjectOf:name:file:)
    public static func numberObject(of source: DICOMAttributeSource, name: String, file: String?) -> NSNumber? {
        AttributeValueCoercion.numberObject(source, name, file: file)
    }

    /// One number of a multi-valued attribute; zero, logged, when it is not one.
    @objc(numberInArray:index:name:file:)
    public static func number(inArray values: [Any], index: Int, name: String, file: String?) -> Double {
        AttributeValueCoercion.number(in: values, at: index, name: name, file: file)
    }
}
