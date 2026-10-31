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

/// Where the application's preferences are read and written by the objects the process graph does not
/// reach: the Core Data objects of the database, the views a nib makes, and class methods that run without
/// an instance. A type that receives the graph reads `processGraph.preferences` instead.
///
/// It keeps the graph it was made with, which is Sendable, and hands out that graph's preferences, which
/// are thread-safe, so it is read from any thread. UserDefaults is not Sendable, so the graph is what it keeps.
struct PreferencesSource: Sendable {
    let processGraph: ProcessGraph

    init(processGraph: ProcessGraph) {
        self.processGraph = processGraph
    }

    /// The preferences of the graph, read and written through the catalog's keys of IsiXPreferences.
    var preferences: UserDefaults {
        processGraph.preferences
    }

    /// The source of the objects made without a graph.
    static let process = PreferencesSource(processGraph: ProcessGraph.process)
}
