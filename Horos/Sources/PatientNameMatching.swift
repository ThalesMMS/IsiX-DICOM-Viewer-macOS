//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

/// Finding a patient by name whatever the case and the diacritics typed.
///
/// A diacritic-insensitive comparison only folds letters that decompose into a
/// base letter and a mark: Ż and ó do, but Ł, Ø, Đ and ı are letters of their
/// own, so "zolw" never found "Żółw" in the database. And a PACS compares the
/// name it is sent as it is: one that keeps names in capitals, without
/// diacritics, as many do, found "ZOLW" and nothing for "Żółw" or "zolw".
@objc(HorosPatientNameMatching)
public final class PatientNameMatching: NSObject {

    /// Letters without a decomposition, under the letter they stand for.
    static let undecomposed: [Character: String] = ["l": "ł", "o": "ø", "d": "đ", "i": "ı"]

    /// What the letters without a decomposition become when a name is folded.
    static let foldings: [Character: String] = [
        "ł": "l", "Ł": "L", "ø": "o", "Ø": "O", "đ": "d", "Đ": "D", "ı": "i",
        "ß": "ss", "æ": "ae", "Æ": "AE", "œ": "oe", "Œ": "OE", "þ": "th", "Þ": "TH",
    ]

    /// A pattern for `MATCHES[cd]` that also lets each of l, o, d and i stand
    /// for its undecomposed counterpart; `nil` when the component has none of
    /// them, and a case- and diacritic-insensitive comparison already finds
    /// every spelling. `anchored`: the component starts the name.
    @objc(undecomposedPatternForComponent:anchored:)
    public static func undecomposedPattern(component: String, anchored: Bool) -> String? {
        var body = ""
        var found = false
        for character in component {
            let base = Character(String(character).lowercased())
            if let other = undecomposed[base] {
                body += "[" + String(base) + other + "]"
                found = true
            } else if let folded = foldings[character], folded.count == 1, let other = undecomposed[Character(folded.lowercased())] {
                body += "[" + folded.lowercased() + other + "]"
                found = true
            } else {
                body += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        guard found else { return nil }
        return (anchored ? "" : ".*") + body + ".*"
    }

    /// `name` without diacritics, its undecomposed letters folded too.
    @objc(foldedName:)
    public static func folded(_ name: String) -> String {
        let spelled = name.map { foldings[$0] ?? String($0) }.joined()
        return spelled.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// The forms to send again when a remote search for the name `term` found
    /// nothing: in capitals, then in capitals without diacritics. Only forms
    /// other than `term` that `encoding` can carry.
    @objc(alternativeRemoteTermsFor:encoding:)
    public static func alternativeRemoteTerms(for term: String, encoding: UInt) -> [String] {
        var terms: [String] = []
        for candidate in [term.uppercased(), folded(term).uppercased()]
        where candidate != term && !terms.contains(candidate)
            && (candidate as NSString).canBeConverted(to: encoding) {
            terms.append(candidate)
        }
        return terms
    }

    /// The database's condition for the patient name `name`, which the
    /// browser's search and the listener's C-FIND use.
    ///
    /// Each name component narrows the match: the first from the start of the
    /// name, the others anywhere in it. A component that is only `*` narrows
    /// nothing, so `*` alone, like an empty value, matches every name, as
    /// universal matching does in a C-FIND (PS3.4 C.2.2.2.3); a component with
    /// `*` or `?` inside is matched as a wildcard pattern (C.2.2.2.4).
    /// `soundex`: the Soundex code of a component, to match the names that
    /// sound alike too; nil: the letters only. It reads no state, so any
    /// thread may call it.
    public static func namePredicate(_ name: String?, soundex: ((String) -> String?)?) -> NSPredicate {
        var s = name as NSString?
        s = s?.replacingOccurrences(of: "^", with: " ") as NSString?
        s = s?.replacingOccurrences(of: ", ", with: " ") as NSString?
        s = s?.replacingOccurrences(of: ",", with: " ") as NSString?

        var predicates: [NSPredicate] = []
        var firstComponent = true
        for name in s?.components(separatedBy: " ") ?? [] {
            var component = name as NSString
            var p: NSPredicate? = nil

            while component.hasPrefix("*") {
                component = component.substring(from: 1) as NSString
                firstComponent = false
            }

            while component.hasSuffix("*") {
                component = component.substring(to: component.length - 1) as NSString
            }

            if component.length == 0 {
                // "*", or an empty component between separators: no condition.
                // A CONTAINS/BEGINSWITH of "" never matches in the store.
                firstComponent = false
                continue
            }

            if component.contains("*") || component.contains("?") {
                p = objcPredicate("name LIKE[cd] %@", (firstComponent ? "" : "*") + (component as String) + "*")
            } else if firstComponent == false {
                if let soundex, component.length >= 2 {
                    p = objcPredicate("(soundex CONTAINS[cd] %@) OR (name CONTAINS[cd] %@)", soundex(component as String), component)
                } else {
                    p = objcPredicate("name CONTAINS[cd] %@", component)
                }
            } else {
                if let soundex, component.length >= 2 {
                    p = objcPredicate("(soundex BEGINSWITH[cd] %@) OR (name BEGINSWITH[cd] %@)", soundex(component as String), component)
                } else {
                    p = objcPredicate("name BEGINSWITH[cd] %@", component)
                }
            }

            // [cd] does not fold Ł, Ø, Đ or ı: "zolw" also finds "Żółw".
            if let plain = p, !component.contains("*"), !component.contains("?"),
               let pattern = undecomposedPattern(component: component as String, anchored: firstComponent) {
                p = NSCompoundPredicate(orPredicateWithSubpredicates: [plain, objcPredicate("name MATCHES[cd] %@", pattern)])
            }

            if let p {
                predicates.append(p)
            }

            firstComponent = false
        }

        return NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    }
}

/// A nil `%@` argument for a format taking a C variable argument list.
private struct ObjCNilArgument: CVarArg {
    var _cVarArgEncoding: [Int] { [0] }
}

/// `[NSPredicate predicateWithFormat: format, …]` with object arguments, a nil
/// one passed as nil.
private func objcPredicate(_ format: String, _ arguments: Any?...) -> NSPredicate {
    let list: [CVarArg] = arguments.map { argument -> CVarArg in
        guard let argument else { return ObjCNilArgument() }
        return ((argument as AnyObject) as? NSObject) ?? ObjCNilArgument()
    }
    return withVaList(list) { NSPredicate(format: format, arguments: $0) }
}
