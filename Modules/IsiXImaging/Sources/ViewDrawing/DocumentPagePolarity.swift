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

/// How a document page is shown: a PDF page or the rendering of a structured
/// report, which the image holds as black ink on white paper. A view shows the
/// page inverted, light text on a dark page, while the application is in Dark
/// Mode, unless the Viewers settings turn that off
/// (InvertsDocumentPagesInDarkMode). Around the page the view stays black, as
/// around any image: no white background is asked for.
///
/// Only the screen changes. The inversion is a table laid over the colour bytes
/// of the view's planar snapshot as the view draws it, the path the B/W Inverse
/// colour table takes over a colour image; the image's samples and its 8-bit
/// picture stay the page's, and so does every snapshot a capture reads, so an
/// export, a print, a copy or a plugin gets the original page.
public enum DocumentPagePolarity {

    /// Whether a view shows a page inverted: a document page, in Dark Mode,
    /// with the inversion turned on. The appearance and the preference are
    /// only read for a document page.
    public static func inverts(isDocumentPage: Bool, darkAppearance: @autoclosure () -> Bool,
                               invertsInDarkMode: @autoclosure () -> Bool) -> Bool {
        return isDocumentPage && darkAppearance() && invertsInDarkMode()
    }

    /// The table a colour image's bytes are looked up in (alpha, red, green
    /// and blue, 256 bytes each) that shows them inverted: `table`, the one
    /// the view lays over them already, with each colour entry turned around,
    /// its alpha kept; without one, the identity turned around, opaque. Nil
    /// for a table that is not 1024 bytes long.
    public static func invertedColourTable(over table: [UInt8]?) -> [UInt8]? {
        if let table, table.count != 1024 { return nil }
        var inverted = [UInt8](repeating: 0xFF, count: 1024)
        for entry in 0..<256 {
            inverted[entry] = table?[entry] ?? 0xFF
            for channel in 1...3 {
                let index = channel * 256 + entry
                inverted[index] = 255 - (table?[index] ?? UInt8(entry))
            }
        }
        return inverted
    }

    /// The planar snapshot `snapshot` as the screen shows it: with `inverted`,
    /// its colour bytes looked up in the inverted table (the table it carries
    /// turned around, or the identity's); otherwise, and for a picture that is
    /// not colour bytes a table may be laid over (floats, or the bytes of the
    /// 12-bit LUT mode, which carry their own alpha), the snapshot itself.
    /// The snapshot given is never changed: what is inverted is a copy of it.
    public static func shown(_ snapshot: NSDictionary, inverted: Bool) -> NSDictionary {
        guard inverted, (snapshot["isColor"] as? NSNumber)?.boolValue == true, snapshot["hostBytes"] is Data,
              (snapshot["bytesCarryAlpha"] as? NSNumber)?.boolValue != true else { return snapshot }
        var laid: [UInt8]?
        if let table = snapshot["colourTable"] {
            guard let bytes = table as? Data else { return snapshot }
            laid = [UInt8](bytes)
        }
        guard let table = invertedColourTable(over: laid) else { return snapshot }
        let shown = NSMutableDictionary(dictionary: snapshot)
        shown["colourTable"] = Data(table)
        return shown
    }
}
