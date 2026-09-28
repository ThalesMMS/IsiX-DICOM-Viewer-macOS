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

/// -setString: as the former code sent it: a nil string reaches Foundation,
/// which raises as it did.
private func psSetString(_ string: NSMutableString, _ value: NSMutableString?) {
    if let value = value {
        string.setString(value as String)
    } else {
        _ = string.perform(#selector(NSMutableString.setString(_:)), with: nil)
    }
}

/// Password generator.
///
/// Implemented in Swift since #717: the Objective-C name, the selectors and
/// <Horos/PSGenerator.h> are those of the former class. The C function
/// randomNumberBetween() stays in PSGenerator+CAPI.m, and the generator draws
/// from it: arc4random_uniform since #758, no longer random() seeded with the
/// time.
@objc(PSGenerator)
public final class PSGenerator: NSObject {
    // Parameters
    private var formatString: NSMutableString?
    private var sourceStringsDict: NSMutableDictionary?
    private var minLengthValue: CUnsignedInt = 0
    private var maxLengthValue: CUnsignedInt = 0
    private var alternativeNumValue: CUnsignedInt = 0
    private var shouldMix = false

    // Temporary Variables
    private var tempFormatString: NSMutableString?
    private var thisLength: CUnsignedInt = 0
    private var tempAltNum: CUnsignedInt = 0

    /// -init of NSObject, which the former class inherited.
    public override init() {
        super.init()
    }

    // Initialization with all parameters. Currently not used.
    @objc(initWithFormatString:sourceStrings:minLength:maxLength:)
    public init(formatString str: NSMutableString!, sourceStrings stringDict: NSMutableDictionary!, minLength min: CUnsignedInt, maxLength max: CUnsignedInt) {
        super.init()
        self.setFormatString(str)
        self.setSourceStrings(stringDict)
        self.minLength = min
        self.maxLength = max
        self.alternativeNum = 0
    }

    // Initialization without format String. Normal case.
    @objc(initWithSourceString:minLength:maxLength:)
    public init(sourceString str: String!, minLength min: CUnsignedInt, maxLength max: CUnsignedInt) {
        super.init()

        // Setting standard format string "000000...."
        self.setStandardFormatString()

        // Creating string dictionary with standard key "0" and object str
        self.setSourceStrings(NSMutableDictionary(capacity: 2))
        self.addString(toDict: str, withKey: "0")

        // Other variables
        self.minLength = min
        self.maxLength = max
        self.alternativeNum = 0
    }

    // MARK: Accessor Methods

    @objc(setFormatString:)
    public func setFormatString(_ str: NSMutableString!) {
        formatString = str
    }

    @objc public func setStandardFormatString() {
        let tempString = NSMutableString(capacity: Int(maxLengthValue))
        var i: CUnsignedInt = 1
        while i <= maxLengthValue {
            tempString.append("0")
            i &+= 1
        }
        self.setFormatString(tempString)
    }

    @objc(setSourceStrings:)
    public func setSourceStrings(_ stringDict: NSMutableDictionary!) {
        sourceStringsDict = stringDict
    }

    /// -minLength and -setMinLength:.
    @objc public var minLength: CUnsignedInt {
        get { return minLengthValue }
        set { minLengthValue = newValue }
    }

    /// -maxLength and -setMaxLength:.
    @objc public var maxLength: CUnsignedInt {
        get { return maxLengthValue }
        set { maxLengthValue = newValue }
    }

    /// -alternativeNum and -setAlternativeNum:.
    @objc public var alternativeNum: CUnsignedInt {
        get { return alternativeNumValue }
        set { alternativeNumValue = newValue }
    }

    @objc(addStringToDict:withKey:)
    public func addString(toDict str: String!, withKey key: String!) {
        if let str = str {
            sourceStringsDict?.setObject(str, forKey: key as NSString)
        }
    }

    @objc public func mainCharacterString() -> String! {
        return sourceStringsDict?.object(forKey: "0") as? String
    }

    @objc public func altCharacterString() -> String! {
        return sourceStringsDict?.object(forKey: "1") as? String
    }


    // MARK: The Password Generator

    @objc(generate:)
    public func generate(_ numPasswords: CUnsignedInt) -> NSArray! {
        let tempArray = NSMutableArray(capacity: Int(numPasswords))

        self.setStandardFormatString() // Ensure that Format string is of correct length

        var i: Int32 = 0
        while UInt32(bitPattern: i) < numPasswords {
            // From the shortest to the longest length, both included.
            thisLength = CUnsignedInt(bitPattern: randomNumberBetween(Int32(bitPattern: minLengthValue), Int32(bitPattern: maxLengthValue) &+ 1))
            let tempString = NSMutableString(capacity: Int(thisLength))

            // If we want alternative characters or format string permutations (those are only planned...)
            // The former condition assigned YES to shouldMix, so it always holds.
            shouldMix = true
            if alternativeNumValue != 0 || shouldMix {
                self.prepareFormatString() // creates randomly built tempFormatString
            } else {
                let copy = NSMutableString(capacity: Int(maxLengthValue))
                tempFormatString = copy
                psSetString(copy, formatString)
            }

            var j: Int32 = 0
            while UInt32(bitPattern: j) < thisLength { // In every loop, one character of the password is created
                // First we determine the appropriate sourceString for the format String character at position j
                let tempKey = tempFormatString?.substring(with: NSMakeRange(Int(j), 1))
                let sourceString = tempKey.flatMap { sourceStringsDict?.object(forKey: $0) } as? NSString
                // Then, a character is chosen by random from the sourceString
                let randCharPos = CUnsignedInt(bitPattern: randomNumberBetween(0, Int32(truncatingIfNeeded: sourceString?.length ?? 0)))
                // Finally, we append the new character to our password
                if let character = sourceString?.substring(with: NSMakeRange(Int(randCharPos), 1)) {
                    tempString.append(character)
                } else {
                    // -appendString: with nil raises, as it did.
                    _ = tempString.perform(#selector(NSMutableString.append(_:)), with: nil)
                }
                j += 1
            }
            // ... and package all passwords in the array we want to return
            tempArray.add(tempString)
            i += 1
        }
        return tempArray
    }

    @objc public func prepareFormatString() { // Permutation not yet implemented
        let tempFormatString = NSMutableString(capacity: Int(maxLengthValue))
        self.tempFormatString = tempFormatString
        psSetString(tempFormatString, formatString)

        // We need to check that desired number of alternatve characters isn't longer than the password we construct
        if alternativeNumValue < thisLength {
            tempAltNum = alternativeNumValue
        } else {
            tempAltNum = thisLength
        }

        // This loop is highly inefficient - no one knows when it ends...
        var x: Int32 = 1
        while UInt32(bitPattern: x) <= tempAltNum {
            let y = randomNumberBetween(0, Int32(bitPattern: thisLength))
            if tempFormatString.substring(with: NSMakeRange(Int(y), 1)) == "0" {
                tempFormatString.replaceCharacters(in: NSMakeRange(Int(y), 1), with: "1")
                x += 1
            }
        }
    }
}
