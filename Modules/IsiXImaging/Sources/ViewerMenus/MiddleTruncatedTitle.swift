//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

/// The title a button of a fixed width shows for a name that may not fit it:
/// the name itself when it fits, and otherwise its beginning and its end
/// around an ellipsis, as long as the button holds.
///
/// The pull-down of a window level, colour table, opacity table or filter
/// shows the name of the preset in use, and a preset has the name its author
/// gave it. Cut at its end, «Logarithmic Table» and «Logarithmic Inverse
/// Table» both read «Logarithmic…»; cut in the middle, the second reads
/// «Logarith…se Table», and two presets that differ at either end stay apart.
///
/// The rule measures nothing: whoever draws the title says whether a text
/// fits. A longer text of the same name is taken to need more room than a
/// shorter one.
public enum MiddleTruncatedTitle {
    /// What stands for the part left out.
    public static let ellipsis = "…"

    /// `name` if it fits; else the longest «beginning…end» of it that fits,
    /// the beginning one character longer than the end when they cannot be
    /// equal, and neither with a space beside the ellipsis. A name of which
    /// not even «a…z» fits is shown as that: something of both ends is kept.
    public static func title(of name: String, fits: (String) -> Bool) -> String {
        if fits(name) { return name }
        let characters = Array(name)
        guard characters.count > 2 else { return name }
        // The most characters kept, of the count - 1 a cut can keep, that fit.
        var fitting = 2, cut = characters.count
        while cut - fitting > 1 {
            let middle = (fitting + cut) / 2
            if fits(keeping(middle, of: characters)) { fitting = middle } else { cut = middle }
        }
        return keeping(fitting, of: characters)
    }

    /// The first and the last of `characters`, `kept` of them in all, around
    /// the ellipsis.
    static func keeping(_ kept: Int, of characters: [Character]) -> String {
        let first = (kept + 1) / 2, last = kept / 2
        let beginning = String(characters.prefix(first)).trimmingCharacters(in: .whitespaces)
        let end = String(characters.suffix(last)).trimmingCharacters(in: .whitespaces)
        return beginning + ellipsis + end
    }

    /// Whether `title` is `name` with its middle left out by this rule.
    public static func isCut(_ title: String, of name: String) -> Bool {
        guard title != name, let at = title.range(of: ellipsis) else { return false }
        return name.hasPrefix(title[..<at.lowerBound]) && name.hasSuffix(title[at.upperBound...])
    }
}
