//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CryptoKit
import Foundation

/// The study and series identifiers of a file that has none of its own: a UI
/// derived from what the importer groups the file on, so that the same file
/// imported twice lands in the same series. The application and the Decompress
/// helper both use it; Objective-C names it HorosDerivedUID (HorosDerivedUID.h).
@objc(IsiXDerivedUID)
public final class DerivedUID: NSObject {
    @objc public static func studyRoot() -> String { "1.2.276.0.7230010.3.1.2" }
    @objc public static func seriesRoot() -> String { "1.2.276.0.7230010.3.1.3" }

    /// `root`, a dot, and the first sixteen bytes of the SHA-256 of `key` in
    /// base ten: their last digits when the UI would pass 64 characters, and a
    /// leading zero replaced by 1 rather than dropped, which keeps two keys apart.
    @objc(uidForKey:root:)
    public static func uid(forKey key: String?, root: String) -> String {
        let digest = SHA256.hash(data: Data((key ?? "").utf8))
        var value = Array(digest.prefix(16))
        // Long division, so no integer type has to hold a 128 bit number.
        var digits = ""
        var any = true
        while any {
            var remainder = 0
            any = false
            for index in value.indices {
                let current = remainder * 256 + Int(value[index])
                value[index] = UInt8(current / 10)
                remainder = current % 10
                if value[index] != 0 { any = true }
            }
            digits.insert(Character(String(remainder)), at: digits.startIndex)
        }
        if digits.isEmpty { digits = "0" }

        let room = 64 - (root as NSString).length - 1
        if room < 1 { return root }
        if digits.count > room { digits = String(digits.suffix(room)) }
        if digits.hasPrefix("0") { digits.replaceSubrange(digits.startIndex...digits.startIndex, with: "1") }
        return root + "." + digits
    }

    @objc(seriesUIDForKey:)
    public static func seriesUID(forKey key: String?) -> String {
        uid(forKey: key, root: seriesRoot())
    }

    @objc(studyUIDForKey:)
    public static func studyUID(forKey key: String?) -> String {
        uid(forKey: key, root: studyRoot())
    }

    /// At most 64 characters of components of digits, none empty and none with
    /// a leading zero (a lone 0 is a component).
    @objc(isConformantUID:)
    public static func isConformantUID(_ value: String?) -> Bool {
        guard let value else { return false }
        let length = (value as NSString).length
        if length == 0 || length > 64 { return false }
        for component in value.components(separatedBy: ".") {
            if component.isEmpty { return false }
            if (component as NSString).rangeOfCharacter(from: CharacterSet.decimalDigits.inverted).location != NSNotFound {
                return false
            }
            if component.count > 1 && component.hasPrefix("0") { return false }
        }
        return true
    }
}
