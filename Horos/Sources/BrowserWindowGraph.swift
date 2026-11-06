//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit

/// The graph of one database window: what the types that act on the browser
/// receive instead of reaching the browser singleton, the browser and the
/// database it shows, together with the graph of the process.
///
/// The application controller makes it from its `browserController` outlet,
/// the browser MainMenu.xib makes, which is the browser the class hands out as
/// the current one. The browser is kept, and the database is read from it when
/// asked: a type that receives this graph follows the database the browser
/// switches to. It lives on the main actor because the browser is an AppKit
/// window controller; code off the main thread reads the browser's database
/// through `processGraph.browserDatabase` instead.
@MainActor final class BrowserWindowGraph {

    /// The graph of the process the window belongs to.
    let processGraph: ProcessGraph

    /// The browser of this window. MainMenu.xib makes it once and keeps it for
    /// the life of the application.
    let browser: BrowserController

    init(browser: BrowserController, processGraph: ProcessGraph) {
        self.browser = browser
        self.processGraph = processGraph
    }

    /// The database the browser shows now; nil while a rebuild has none.
    var database: DicomDatabase? {
        browser.database
    }
}

extension ProcessGraph {
    /// The graph of the database window when `window` is that window; nil for
    /// any other window, for a view not in a window and before the browser
    /// exists. The views and the cells of the database window, which its nib
    /// makes, reach the graph of their window through it.
    @MainActor func browserWindow(of window: NSWindow?) -> BrowserWindowGraph? {
        guard let window, let graph = browserWindow, graph.browser.window === window else { return nil }
        return graph
    }
}
