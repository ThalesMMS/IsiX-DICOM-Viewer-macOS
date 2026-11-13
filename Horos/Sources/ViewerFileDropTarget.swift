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
import IsiXDICOMFile

/// Files dropped from another application on a window that shows a series:
/// the 2D viewer and the windows opened from one (MPR, orthogonal MPR, PET-CT,
/// curved reconstruction, volume and surface rendering, endoscopy, ROI
/// volume).
///
/// Image files and PDFs become new series of the study the window shows, as
/// when they are dropped on the row of that study in the database window. One
/// entry for every window: IsiXDICOMFile's ViewerFileDrop decides, and
/// StudyFileImporter converts, into the database of the study, which the
/// database window may not be showing. The window answers every other drop
/// itself, as it did: a drag of this application (an image of a viewer, rows
/// of the database), ROI files, a curved path, and the pictures the 2D viewer
/// lays on its image with Option held.
///
/// The study is that of the window: the 2D viewer's current one, and for the
/// other windows the one of the viewer they were opened from. A study that
/// takes no files (a database that is not local or is read-only, a locked
/// study) refuses the drag while it is still over the window.
@MainActor enum ViewerFileDropTarget {
    /// The list of file names the Finder puts on the pasteboard of a drag.
    static let fileNamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    /// Makes `window` a destination of dragged files, beside what it already takes.
    static func register(_ window: NSWindow?) {
        window?.registerForDraggedTypes([fileNamesType])
    }

    /// The files of a drag that comes from another application; nil for a
    /// drag of this one, whose files are those of its own images, and for a
    /// drag without files.
    static func files(of drag: NSDraggingInfo) -> [String]? {
        guard drag.draggingSource == nil, drag.draggingPasteboard.availableType(from: [fileNamesType]) != nil,
              let paths = drag.draggingPasteboard.propertyList(forType: fileNamesType) as? [String], !paths.isEmpty else { return nil }
        return paths
    }

    private static func kind(of controller: OSIWindowController) -> ViewerFileDrop.Window {
        controller is ViewerController ? .viewer2D : .reconstruction
    }

    /// The study the window shows: its own, or the one of the 2D viewer it
    /// was opened from.
    static func study(of controller: OSIWindowController) -> DicomStudy? {
        controller.currentStudy() ?? (controller as? Window3DController)?.viewer()?.currentStudy()
    }

    /// What the window answers a drag over it; nil when the drag is the
    /// window's own to answer.
    static func operation(for drag: NSDraggingInfo, on controller: OSIWindowController) -> NSDragOperation? {
        guard let paths = files(of: drag) else { return nil }
        let answer = ViewerFileDrop.answer(for: paths, optionPressed: NSEvent.modifierFlags.contains(.option), in: kind(of: controller),
                                           sourceAllowsCopy: drag.draggingSourceOperationMask.contains(.copy),
                                           refusal: StudyFileImporter.refusal(of: study(of: controller)))
        switch answer {
        case .copy: return .copy
        case .refuse: return []
        case .windowsOwn: return nil
        }
    }

    /// Takes the files of a drop that become a series; nil when the drop is
    /// the window's own to perform.
    static func perform(_ drag: NSDraggingInfo, on controller: OSIWindowController) -> Bool? {
        guard let paths = files(of: drag) else { return nil }
        return drop(paths, optionPressed: NSEvent.modifierFlags.contains(.option), on: controller)
    }

    /// The entry of every window: `paths`, dropped on the window of
    /// `controller` with Option held or not, become new series of the study
    /// it shows. Nil when they are the window's own to take; false when the
    /// study takes no files.
    ///
    /// The files are converted once the drop is answered, from the main run
    /// loop: the application the files come from waits for the answer, and
    /// the conversion may end with an alert.
    static func drop(_ paths: [String], optionPressed: Bool, on controller: OSIWindowController) -> Bool? {
        guard ViewerFileDrop.decision(for: paths, optionPressed: optionPressed, in: kind(of: controller)) == .newSeries else { return nil }
        guard let destination = StudyFileImporter.destination(showing: study(of: controller)) else {
            NSSound.beep()
            return false
        }
        let taken = Destination(study: destination.study, database: destination.database)
        onMainRunLoop {
            StudyFileImporter.convert(paths, into: taken.study, database: taken.database)
            showSeries(of: taken.study)
        }
        return true
    }

    /// The study and the database of a drop, which only the main thread
    /// touches, from the drop to the conversion. @unchecked Sendable: neither
    /// class is Sendable, and nothing uses them on the way.
    private struct Destination: @unchecked Sendable {
        let study: DicomStudy
        let database: DicomDatabase
    }

    /// The series lists of the 2D viewers that show `study` take its new
    /// series: the database window refreshes those of the database it shows,
    /// and the study may be of another.
    private static func showSeries(of study: DicomStudy) {
        for case let viewer as ViewerController in ViewerController.getDisplayed2DViewers() ?? [] {
            if viewer.currentStudy()?.objectID == study.objectID, viewer.windowWillClose() == false, viewer.window?.isVisible == true,
               (viewer.imageView()?.mouseDragging ?? false) == false {
                viewer.buildMatrixPreview(false)
            }
        }
    }
}

extension StudyFileImporter {
    /// Why `study` takes no files, in the database it is of.
    static func refusal(of study: DicomStudy?) -> ViewerFileDrop.Refusal? {
        refusal(of: study, in: study.flatMap { DicomDatabase(for: $0.managedObjectContext) })
    }
}

extension OSIWindowController {
    /// Files dropped on the window, with Option held or not, as a drop from
    /// the Finder hands them over: true when they became new series of the
    /// study the window shows. Any other drop is the window's own, and false
    /// here. For what drives the window without a drag.
    @objc(horos_dropFiles:optionPressed:)
    func dropFiles(_ paths: [String], optionPressed: Bool) -> Bool {
        ViewerFileDropTarget.drop(paths, optionPressed: optionPressed, on: self) ?? false
    }
}

extension Window3DController {
    // The windows opened from a 2D viewer took no files, but for the curved
    // path of the curved reconstruction, which overrides these.

    @objc(draggingEntered:)
    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        ViewerFileDropTarget.operation(for: sender, on: self) ?? []
    }

    @objc(draggingUpdated:)
    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        ViewerFileDropTarget.operation(for: sender, on: self) ?? []
    }

    @objc(performDragOperation:)
    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        ViewerFileDropTarget.perform(sender, on: self) ?? false
    }
}
