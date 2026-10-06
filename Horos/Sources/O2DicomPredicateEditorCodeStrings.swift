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

/// A mutable dictionary that enumerates its keys in the order they were
/// (last) set. O2DicomPredicateEditorView numbers the code strings of a CS tag
/// by this order, and the number picks the value the smart album predicate
/// stores, so the order is that of the former class.
@objc(O2DicomPredicateEditorOrderedMutableDictionary)
public final class O2DicomPredicateEditorOrderedMutableDictionary: NSMutableDictionary {
    private let sortedKeys = NSMutableArray()
    private let content = NSMutableDictionary()

    public override init() {
        super.init()
    }

    public override init(capacity numItems: Int) {
        super.init()
    }

    // -initWithObjects:forKeys:, which the former class overrode to keep the
    // keys in the order given, is not called; NSMutableDictionary's
    // convenience initializers end in -initWithCapacity: and -setObject:forKey:.

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override var count: Int {
        return content.count
    }

    public override func object(forKey aKey: Any) -> Any? {
        return content.object(forKey: aKey)
    }

    public override func keyEnumerator() -> NSEnumerator {
        return sortedKeys.objectEnumerator()
    }

    public override func setObject(_ anObject: Any, forKey aKey: NSCopying) {
        content.setObject(anObject, forKey: aKey)
        if sortedKeys.contains(aKey) {
            sortedKeys.remove(aKey)
        }
        sortedKeys.add(aKey)
    }

    public override func removeObject(forKey aKey: Any) {
        content.removeObject(forKey: aKey)
        sortedKeys.remove(aKey)
    }
}

/// The values of the CS (code string) tags, read from the dicom3tools and
/// OsiriX .tpl resources, and the OsiriX study states.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/O2DicomPredicateEditorCodeStrings.h> are those of the former class.
@objc(O2DicomPredicateEditorCodeStrings)
public final class O2DicomPredicateEditorCodeStrings: NSObject {
    // nonisolated(unsafe): the lazy initializer of a global `let` runs once,
    // whichever thread asks first, and nothing changes the dictionary
    // afterwards: `base()` hands it out as an NSDictionary, only to be read.
    nonisolated(unsafe) private static let baseDictionary: NSMutableDictionary = {
        let base = NSMutableDictionary()

        let wsnlcs = CharacterSet.whitespacesAndNewlines

        for tpl in ["dicom3tools-libsrc-standard-strval-base", "osirix-complementary"] {
            // NSString throughout, so that "\r", "\r\n" and the scanner offsets
            // are handled in UTF-16 units, as before.
            guard let path = Bundle(for: O2DicomPredicateEditorCodeStrings.self).path(forResource: tpl, ofType: "tpl"),
                  var str = try? NSString(contentsOfFile: path, encoding: String.Encoding.utf8.rawValue) else {
                continue
            }
            str = str.replacingOccurrences(of: "\r", with: "\n") as NSString
            str = str.replacingOccurrences(of: "  ", with: " ") as NSString
            str = str.replacingOccurrences(of: ", \n", with: ",\n") as NSString
            str = str.replacingOccurrences(of: "\n\n", with: "\n") as NSString

            let s = Scanner(string: str as String)
            while !s.isAtEnd {
                _ = s.scanUpToString("StringValues")
                if s.isAtEnd {
                    break
                }

                _ = s.scanUpToString("=")
                _ = s.scanUpToString("\"")
                s.o2_advanceScanLocation()

                let cs = s.scanUpToString("\"")

                _ = s.scanUpToString("{")
                s.o2_advanceScanLocation()

                let vps = s.scanUpToString("}")

                let b = O2DicomPredicateEditorOrderedMutableDictionary()

                for vp in (vps as NSString?)?.components(separatedBy: ",\n") ?? [] {
                    let vpc = (vp as NSString).components(separatedBy: "=")
                    if vpc.count == 1 {
                        b.setObject((vpc[0] as NSString).trimmingCharacters(in: wsnlcs), forKey: (vpc[0] as NSString).trimmingCharacters(in: wsnlcs) as NSString)
                    } else if vpc.count >= 2 {
                        b.setObject((vpc[1...].joined(separator: "=") as NSString).trimmingCharacters(in: wsnlcs), forKey: (vpc[0] as NSString).trimmingCharacters(in: wsnlcs) as NSString)
                    }
                }

                // The former -setObject:forKey: raised for a nil key; the
                // bundled files always name their values.
                if let cs = cs {
                    base.setObject(b, forKey: cs as NSString)
                }
            }
        }

        let b = O2DicomPredicateEditorOrderedMutableDictionary()
        b.setObject(NSLocalizedString("empty", comment: ""), forKey: NSNumber(value: Int32(0)))
        b.setObject(NSLocalizedString("unread", comment: ""), forKey: NSNumber(value: Int32(1)))
        b.setObject(NSLocalizedString("reviewed", comment: ""), forKey: NSNumber(value: Int32(2)))
        b.setObject(NSLocalizedString("dictated", comment: ""), forKey: NSNumber(value: Int32(3)))
        b.setObject(NSLocalizedString("validated", comment: ""), forKey: NSNumber(value: Int32(4)))
        base.setObject(b, forKey: "OsiriX StudyStatus" as NSString)

        return base
    }()

    @objc(base)
    class func base() -> NSDictionary {
        return baseDictionary
    }

    /// The code strings of a CS tag, keyed by value, in the order of the
    /// resource: an NSDictionary, not bridged, so that the order is kept.
    @objc(codeStringsForTag:)
    public class func codeStrings(for tag: DCMAttributeTag!) -> NSDictionary! {
        guard let tag = tag, tag.vr == "CS" else {
            return nil
        }

        var k: String? = tag.name
        if let tag = tag as? O2DicomPredicateEditorDCMAttributeTag, let k2 = tag.cskey() {
            k = k2
        }

        guard let key = k else {
            return nil
        }
        return base().object(forKey: key) as? NSDictionary
    }
}

private extension Scanner {
    /// `s.scanLocation = s.scanLocation+1`: one UTF-16 unit further.
    func o2_advanceScanLocation() {
        currentIndex = string.utf16.index(after: currentIndex)
    }
}
