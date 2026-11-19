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

/// The short name of a thick slab mode, as the closed pop-up of a toolbar
/// shows it, taken from the name its menu lists.
///
/// A menu names a mode by its abbreviation and what the abbreviation stands
/// for, with a dash between them: «MIP - Max Intensity Projection». The dash
/// is the translator's: a hyphen in most languages, an en dash in German
/// («MIP – Maximumintensitätsprojektion») and an em dash in Russian
/// («minIP — проекция минимальной интенсивности»). The short name is what
/// comes before the first dash that has a space on each side, whichever of
/// them it is, so a hyphen inside a word («3D-MPR») does not end the name. A
/// name with no such dash («Mean») is its own short name.
public enum ThickSlabModeName {
    /// The dashes a translation puts between an abbreviation and its meaning:
    /// the hyphen, the figure dash, the en dash, the em dash, the horizontal
    /// bar and the minus sign.
    public static let separators: Set<Character> = ["-", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}", "\u{2212}"]

    /// «MIP – Maximumintensitätsprojektion» → «MIP»; a name without a dash
    /// between spaces stays whole, less the spaces around it.
    public static func short(of name: String) -> String {
        let whole = name.trimmingCharacters(in: .whitespaces)
        var before: Character?
        var index = whole.startIndex
        while index < whole.endIndex {
            let character = whole[index]
            let next = whole.index(after: index)
            if separators.contains(character), before?.isWhitespace == true, next < whole.endIndex, whole[next].isWhitespace {
                return whole[..<index].trimmingCharacters(in: .whitespaces)
            }
            before = character
            index = next
        }
        return whole
    }
}
