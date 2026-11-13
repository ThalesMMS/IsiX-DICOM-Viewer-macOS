/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit
import IsiXImaging
import IsiXPreferences

/// The saved layout of the 2D viewers ("windows state", or workspace): saved
/// into each study shown, one `ViewerWorkspaceEntry` per viewer written as an
/// XML property list (and archived as a DICOM SR when asked), opened again
/// with the study, and forgotten. Which entries a study keeps is
/// `ViewerWindowsState`.
///
/// Made for one call, from the process graph the viewers share; a viewer is an
/// argument, held for the call only.
@MainActor struct ViewerWorkspaceArchiver {
    let processGraph: ProcessGraph

    /// The preference no pane writes: every save is archived as a DICOM SR too.
    private static let alwaysArchiveAsDICOMSR = PreferenceKey<Bool>("alwaysArchiveWindowsStateAsDICOMSR")

    private var preferences: any PreferenceStore {
        processGraph.preferences
    }

    /// Forgets the saved layout of the studies on screen.
    func reset() {
        for case let study as DicomStudy in ViewerController.getDisplayedStudies() ?? [] {
            study.windowsState = nil
        }
    }

    /// Opens the study of `viewer` again, with its saved layout even when the
    /// layouts are not loaded automatically: the automatic load is on for this
    /// process while the browser opens it (TemporaryPreferenceWork).
    func reopenStudy(of viewer: ViewerController) {
        TemporaryPreferenceWork.during(ViewerPreferences.automaticWorkspaceLoad, at: true) {
            processGraph.currentBrowser?.databaseOpenStudy(viewer.horos_imageView?.seriesObj()?.study)
        }
    }

    /// Asks `viewer` for the name of the layout (its sheet, given today's
    /// date), then archives the layout as a DICOM SR; at once, unnamed, when
    /// the sheet is missing.
    func askNameForDICOMSR(in viewer: ViewerController) {
        viewer.horosLoadViewerPanels()

        viewer.windowsStateName = UserDefaults.formatDateTime(Date())

        if let sheet = viewer.horos_saveWindowsStateWindow {
            viewer.window?.beginSheet(sheet, completionHandler: nil)
        } else {
            save(asDICOMSR: true, name: nil)
        }
    }

    /// The naming sheet ended with `tag`: the layout is archived under the
    /// name given, unless the sheet was cancelled (0).
    func endNaming(in viewer: ViewerController, tag: Int) {
        viewer.horos_saveWindowsStateWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))

        if tag != 0 {
            save(asDICOMSR: true, name: viewer.windowsStateName)
        }
    }

    /// Saves the layout, archived as a DICOM SR when the preference asks for it.
    func save() {
        save(asDICOMSR: preferences[Self.alwaysArchiveAsDICOMSR], name: nil)
    }

    /// Saves the layout of the displayed viewers into each study they show
    /// (only when every one of them can be described), the part of it that
    /// shows the study's own patient.
    ///
    /// The former code wrote one dictionary per viewer, inside a @try that
    /// logged and abandoned the save when a key had no value: the value of
    /// COPYSETTINGS missing, a series without a study, a movie frame without
    /// slices. Those cases still log the exception the dictionary or the array
    /// raised and abandon the save.
    func save(asDICOMSR: Bool, name: String?) {
        let displayedViewers = processGraph.viewerRegistry.displayedViewers
        var state: [ViewerWorkspaceEntry] = []
        var statePatients: [String] = []

        var name = name ?? ""
        if name.isEmpty { name = UserDefaults.formatDateTime(Date()) ?? "" }

        for viewer in displayedViewers {
            guard let view = viewer.imageView() else { continue }
            let series = view.seriesObj()
            guard let studyInstanceUID = viewer.studyInstanceUID(), series?.seriesInstanceUID != nil else { continue }

            switch entry(of: viewer, view: view, name: name, studyInstanceUID: studyInstanceUID) {
            case .success(let entry):
                state.append(entry)
                statePatients.append(series?.study?.patientUID ?? "")
            case .failure(let abandoned):
                return Self.log(NSException(name: abandoned.name, reason: abandoned.reason))
            }
        }

        // The states are saved only if every displayed window can be.
        if displayedViewers.count != state.count { return }

        let windowsState = try? ViewerWorkspaceEntry.propertyList(state)

        var studies: [DicomStudy] = []
        for viewer in displayedViewers {
            guard let view = viewer.imageView() else { continue }
            if view.curDCM?.generated == true { continue }
            guard let series = view.seriesObj(), series.seriesInstanceUID != nil else { continue }
            guard let study = series.study else {
                return Self.log(NSException(name: .invalidArgumentException, reason: "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil"))
            }
            if !studies.contains(where: { $0 === study }) { studies.append(study) }
        }

        for study in studies {
            let own = ViewerWindowsState.entries(of: state, patients: statePatients, patientUID: study.patientUID)
            if own.isEmpty { continue }

            study.windowsState = own.count == state.count ? windowsState : try? ViewerWorkspaceEntry.propertyList(own)

            // The former @try covered the archive: an exception of SRAnnotation
            // or DCMTK is logged and ends the save, as it did.
            if asDICOMSR, let exception = Self.archiveFailure(of: study) {
                return Self.log(exception)
            }
        }
    }

    /// Why a viewer could not be described: the name and reason of the
    /// exception the former dictionary or array raised.
    private struct Abandoned: Error {
        let name: NSExceptionName
        let reason: String
    }

    /// The entry of `viewer`, whose image view is `view`.
    private func entry(of viewer: ViewerController, view: DCMView, name: String, studyInstanceUID: String) -> Result<ViewerWorkspaceEntry, Abandoned> {
        let frame = viewer.window?.frame ?? .zero
        let screen = viewer.window?.screen
        let screenIndex = screen.flatMap { screen in NSScreen.screens.firstIndex { $0 == screen } } ?? NSNotFound

        let first = Int32(viewer.seriesView()?.firstView()?.curImage ?? 0)
        let index: Int32 = view.flippedData ? Int32(viewer.getNumberOfImages()) - 1 - first : first

        // The window of an SUV series is kept in the values of its pixels.
        let pix = view.curDCM
        let suv = pix?.suvConverted ?? false
        let windowLevel = pix?.storedWindowLevel(forCalibratedLevel: suv ? view.curWL / viewer.factorPET2SUV() : view.curWL) ?? 0
        let windowWidth = suv ? view.curWW / viewer.factorPET2SUV() : view.curWW

        var seriesUIDs: [String] = []
        for frameIndex in 0..<Int(viewer.maxMovieIndex()) {
            guard let slices = viewer.pixList(frameIndex) else { continue }
            guard slices.count > 0 else {
                return .failure(Abandoned(name: .rangeException, reason: "*** -[__NSArrayM objectAtIndex:]: index 0 beyond bounds for empty array"))
            }
            if let uid = (slices.object(at: 0) as? DCMPix)?.seriesObj()?.seriesInstanceUID {
                seriesUIDs.append(uid)
            }
        }

        // setObject:nil raised: a missing COPYSETTINGS abandoned the save.
        guard let stored = preferences.object(forKey: ViewerPreferences.copySettings.name),
              let propagateSettings = ViewerWorkspaceEntry.StoredPreference(stored) else {
            return .failure(Abandoned(name: .invalidArgumentException,
                                      reason: "*** -[__NSDictionaryM setObject:forKey:]: object cannot be nil (key: propagateSettings)"))
        }

        let syncSettings: Bool? = switch DCMView.syncro() {
        case Int16(syncroLOC): true
        case Int16(syncroOFF): false
        default: nil
        }
        let betweenStudies = ViewerController.horos_syncButtonBehaviorIsBetweenStudies()

        return .success(ViewerWorkspaceEntry(
            name: name, windowPosition: ViewerWindowsState.windowPosition(frame), screen: NSStringFromRect(AppController.usefullRect(for: screen)),
            screenIndex: UInt(bitPattern: screenIndex), rows: view.rows, columns: view.columns, index: index,
            windowLevel: windowLevel, windowWidth: windowWidth, scale: view.scaleValue, x: Double(view.origin.x), y: Double(view.origin.y),
            rotation: view.rotation, xFlipped: view.xFlipped, yFlipped: view.yFlipped, studyInstanceUID: studyInstanceUID,
            seriesInstanceUID: ViewerWindowsState.seriesInstanceUID(of: seriesUIDs),
            // A series imported from a raster file (TIFF, JPEG...) has no DICOM
            // Series Instance UID: seriesInstanceUID above finds it again, and
            // the restore skips an absent seriesDICOMUID.
            seriesDICOMUID: viewer.currentSeries()?.seriesDICOMUID,
            is4D: viewer.maxMovieIndex() > 1,
            lastWindowsTilingRowsColumns: preferences.object(forKey: ViewerPreferences.lastWindowsTilingRowsColumns.name).flatMap(ViewerWorkspaceEntry.StoredPreference.init),
            propagateSettings: propagateSettings, syncSettings: syncSettings, syncButtonBehaviorIsBetweenStudies: betweenStudies,
            syncSeries: ViewerController.horos_SYNCSERIES(), syncRelativeDiff: betweenStudies ? view.syncRelativeDiff : nil, date: Date()))
    }

    /// Archives the saved layout of `study` as a DICOM SR; the exception of its
    /// failure, or the one SRAnnotation, DCMTK or Core Data raised, nil when
    /// the archive was written.
    private static func archiveFailure(of study: DicomStudy) -> NSException? {
        do {
            try HorosObjCException.throwing(StudyDocumentError.raised) { try study.writeWindowsStateAsDICOMSR() }
            return nil
        } catch {
            return StudyDocumentError.exception(of: error)
        }
    }

    /// The former @catch: the exception logged, with the stack.
    private static func log(_ exception: NSException) {
        _N2LogExceptionImpl(exception, true, "+[ViewerController saveWindowsStateWithDICOMSR:name:]")
    }
}
