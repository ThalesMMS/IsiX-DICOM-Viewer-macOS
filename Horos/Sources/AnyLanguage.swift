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
import IsiXPreferences
import Synchronization

/// A name that is stored as it was shown: a default album in a database, the
/// linear opacity table in the state of a 3D window. It was written in the
/// language the application ran in then, which need not be the language it
/// runs in now, so what is stored is recognised in every language the
/// application has.
enum AnyLanguage {
    private static let known = Mutex<[String: Set<String>]>([:])

    /// The texts of `key` in each language of the application, with the key
    /// itself and what the catalogs once wrote for it.
    static func texts(of key: String) -> Set<String> {
        if let texts = known.withLock({ $0[key] }) { return texts }
        var texts = StoredTableNames.formerTexts(of: key)
        for language in Bundle.main.localizations {
            guard let path = Bundle.main.path(forResource: language, ofType: "lproj"), let bundle = Bundle(path: path) else { continue }
            texts.insert(bundle.localizedString(forKey: key, value: key, table: nil))
        }
        known.withLock { $0[key] = texts }
        return texts
    }

    /// Whether `text` is `key` as some language of the application writes it.
    static func says(_ text: String?, _ key: String) -> Bool {
        guard let text else { return false }
        return texts(of: key).contains(text)
    }

    /// A stored table name as the application writes it now: a name that was
    /// saved in a language's words comes back as English writes it
    /// (`StoredTableNames`), read against the catalogs of the application. A
    /// state that names the opacity table of volume rendering in a language's
    /// words was saved by a window that had asked for that table and, finding
    /// no preset of that name, drew the linear one under its title: read
    /// again, it gets the table it names.
    static func tableName(stored text: String?) -> String? {
        StoredTableNames.name(stored: text, texts: texts(of:))
    }
}
