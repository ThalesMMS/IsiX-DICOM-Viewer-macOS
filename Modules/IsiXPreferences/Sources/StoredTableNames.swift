//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

/// The names of colour and opacity tables that were saved as a language wrote
/// them, and the rule that reads such a name back.
///
/// What the catalogs wrote, while they translated them, for the names of a
/// table that were saved in a language's words: the absence of an opacity
/// table and of a colour table, the 16-bit colour table, and the opacity
/// table volume rendering opens with, which the window asked for under its
/// translated name, kept as its current table and saved. Every language now
/// leaves these names as English writes them, and a 3D state, a 3D preset or
/// a preference saved before still holds the text of its day. The other names
/// the catalogs translated were never saved so: a colour table, a window
/// level preset and a filter are saved under the name the preferences list
/// them by, which is the English one.
public enum StoredTableNames {
    /// For each name, as English writes it, the texts a catalog once wrote.
    public static let formerTexts: [String: Set<String>] = [
        "Linear Table": ["Lineare Tabelle", "Tableau linéaire", "रैखिक तालिका", "Tabella lineare", "선형 테이블", "Tabela linear",
                         "Линейная таблица", "Линейный стол", "线性映射表", "线性表格"],
        "No CLUT": ["بدون CLUT", "Keine CLUT", "Aucune CLUT", "कोई CLUT नहीं", "CLUT 없음", "클루트 없음", "Sem CLUT", "Без CLUT", "无 CLUT"],
        "16-bit CLUT": ["16 bits CLUT", "16-बिट CLUT", "16ビット CLUT", "16비트 CLUT", "16-битный CLUT", "16位CLUT"],
        "Logarithmic Inverse Table": ["Invers-logarithmische Tabelle", "Tableau inverse logarithmique", "लघुगणक व्युत्क्रम तालिका",
                                      "Tabella inversa logaritmica", "로그 역 테이블", "Tabela logarítmica inversa",
                                      "Логарифмическая обратная таблица", "对数反向表格"],
    ]

    /// The name itself and what the catalogs once wrote for it.
    public static func formerTexts(of name: String) -> Set<String> {
        formerTexts[name, default: []].union([name])
    }

    /// A stored table name as the application writes it now. `texts` gives,
    /// for a name, every text the application knows for it: its former texts
    /// and what the catalogs of the running application write. One of the
    /// names of `formerTexts` found in a language's words comes back as
    /// English writes it, which is how every menu lists it and how the
    /// opacity table is found among the presets; any other name is a
    /// preset's and comes back as it is.
    public static func name(stored text: String?, texts: (String) -> Set<String>) -> String? {
        guard let text else { return nil }
        return formerTexts.keys.sorted().first { texts($0).contains(text) } ?? text
    }
}
