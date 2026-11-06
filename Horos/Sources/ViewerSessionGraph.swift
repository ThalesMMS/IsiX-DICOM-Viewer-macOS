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
import IsiXPreferences

/// The graph of one 2D viewer: what the viewer and the types that work for it
/// receive instead of reaching the singletons, the process graph, the
/// preferences and the register of the viewers, together with the viewer itself.
///
/// The viewer makes it in its initializer, the path every viewer takes,
/// including the ones plugins open themselves through -initWithPix:withFiles:withVolume:
/// and +newWindow:::. It runs the viewer's life: its set-up
/// (ViewerSessionGraph+ViewerLife.swift) and its window's
/// (ViewerSessionGraph+WindowLife.swift). It lives on the main actor because
/// it keeps the viewer, an AppKit window controller.
@MainActor final class ViewerSessionGraph {

    /// The graph of the process the viewer belongs to.
    let processGraph: ProcessGraph

    /// The viewer, which owns this graph; nil once it is being freed. What
    /// runs while it is freed receives it as an argument.
    private(set) weak var viewer: ViewerController?

    /// The window level of the viewer: its presets, its "Set WL/WW" sheet and
    /// the conversion of its PET series to SUV.
    let windowLevel: ViewerWindowLevel

    /// The colour tables, opacity tables and convolution filters of the viewer.
    let colourTables: ViewerColourTables

    init(viewer: ViewerController, processGraph: ProcessGraph) {
        self.viewer = viewer
        self.processGraph = processGraph
        windowLevel = ViewerWindowLevel(viewer: viewer, preferences: processGraph.preferences, menus: processGraph.presetMenuCache)
        colourTables = ViewerColourTables(preferences: processGraph.preferences, menus: processGraph.presetMenuCache,
                                          cache: processGraph.colourTableCache)
    }

    /// The application's preferences, read and written through the typed keys
    /// of IsiXPreferences.
    var preferences: any PreferenceStore {
        processGraph.preferences
    }

    /// The register of the process's 2D viewers.
    var registry: ViewerRegistry {
        processGraph.viewerRegistry
    }
}
