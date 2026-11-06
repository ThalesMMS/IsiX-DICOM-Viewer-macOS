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
import IsiXPluginKit
import os
import Synchronization

/// Invert Data on the plugin API version 1: negates the pixels of every
/// slice and phase of the frontmost viewer, in memory, and moves the window
/// level so that the inverted image looks like the original.
///
/// Each image is read as a copy, inverted and committed back; the commit is
/// refused if the viewer changed the image meanwhile, and every call throws
/// `viewerClosed` once the viewer is gone. Source files are never written.
public final class InvertDataPlugin: IsiXPlugin, CustomStringConvertible {
    private let log = Logger(subsystem: "org.isix.pilot.invert-data", category: "pilot")
    /// What the plugin did, one line per run, for whoever checks it.
    private let journal = Mutex<[String]>([])

    public nonisolated var description: String { journal.withLock { $0.joined(separator: "\n") } }

    public init() {}

    public func activate(with context: IsiXPluginContext) throws {
        try context.register(IsiXCommand(id: "invert-data", title: "Invert Data",
                                         placement: .imageFilters, requirement: .viewer)) { [weak self] invocation in
            guard let viewer = invocation.viewer else { throw IsiXPluginError.viewerClosed }
            try self?.invert(viewer)
        }
        note("activated \(context.info.identifier) \(context.info.version)")
    }

    private func note(_ line: String) {
        journal.withLock { $0.append(line) }
        log.notice("InvertData: \(line, privacy: .public)")
    }

    func invert(_ viewer: IsiXViewer) throws {
        let series = try viewer.series()
        let level = try viewer.windowLevel()
        var colour = false
        var images = 0
        do {
            for phase in 0..<series.phaseCount {
                for slice in 0..<series.sliceCount {
                    let image = try viewer.image(slice: slice, phase: phase)
                    if case .rgba8 = image.pixels { colour = true }
                    try viewer.commit(Inversion.inverted(image.pixels), replacing: image)
                    images += 1
                }
            }
        } catch {
            note("stopped after \(images) images: \(error)")
            throw error
        }
        let inverted = Inversion.windowLevel(level, colour: colour)
        try viewer.setWindowLevel(inverted)
        viewer.setNeedsDisplay()
        note(String(format: "inverted %d images (%d slices x %d phases) colour %@ window %.4f/%.4f -> %.4f/%.4f",
                    images, series.sliceCount, series.phaseCount, colour ? "yes" : "no",
                    level.center, level.width, inverted.center, inverted.width))
    }
}
