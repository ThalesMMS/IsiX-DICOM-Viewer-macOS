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

// The saved layout of the 2D viewers ("windows state"): saved into each
// study shown, as an XML property list of one dictionary per viewer (and
// archived as a DICOM SR when asked), restored when the study opens, and
// reset. The keys and values of the property list are those of the former
// Objective-C; which entries a study keeps is IsiXImaging's
// ViewerWindowsState. The selectors are those of the former Objective-C
// methods.

public extension ViewerController {

    /// Forgets the saved layout of the studies on screen.
    @objc(resetWindowsState:)
    func resetWindowsState(_ sender: Any!) {
        for case let study as NSObject in (ViewerController.getDisplayedStudies() ?? []) {
            study.setValue(nil, forKey: "windowsState")
        }
    }

    /// Opens this viewer's study again with its saved layout.
    @objc(loadWindowsState:)
    func loadWindowsState(_ sender: Any!) {
        let defaults = UserDefaults.standard
        let automatic = defaults.bool(forKey: "automaticWorkspaceLoad")
        if !automatic { defaults.set(true, forKey: "automaticWorkspaceLoad") }

        BrowserController.currentBrowser()?.databaseOpenStudy((horos_imageView?.seriesObj() as NSObject?)?.value(forKey: "study") as? DicomStudy)

        if !automatic { defaults.set(automatic, forKey: "automaticWorkspaceLoad") }
    }

    @objc(saveWindowsState:)
    func saveWindowsState(_ sender: Any!) {
        ViewerController.saveWindowsState()
    }

    /// Asks for the name of the layout, then archives it as a DICOM SR.
    @objc(saveWindowsStateAsDICOMSR:)
    func saveWindowsStateAsDICOMSR(_ sender: Any!) {
        horosLoadViewerPanels()

        windowsStateName = UserDefaults.formatDateTime(Date())

        if let sheet = horos_saveWindowsStateWindow {
            window?.beginSheet(sheet, completionHandler: nil)
        } else {
            ViewerController.saveWindowsState(withDICOMSR: true, name: nil)
        }
    }

    @objc(endSaveWindowsStateAsDICOMSR:)
    func endSaveWindowsStateAsDICOMSR(_ sender: Any!) {
        let tag = ViewerSender.tag(sender)
        horos_saveWindowsStateWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))

        if tag != 0 {
            ViewerController.saveWindowsState(withDICOMSR: true, name: windowsStateName)
        }
    }

    /// Saves the layout, archived as a DICOM SR when the preference asks for it.
    @objc(saveWindowsState)
    class func saveWindowsState() {
        saveWindowsState(withDICOMSR: UserDefaults.standard.bool(forKey: "alwaysArchiveWindowsStateAsDICOMSR"), name: nil)
    }

    /// Saves the layout of the displayed viewers into each study they show
    /// (only when every one of them can be described), the part of it that
    /// shows the study's own patient.
    @objc(saveWindowsStateWithDICOMSR:name:)
    class func saveWindowsState(withDICOMSR DICOMSR: Bool, name: String?) {
        let displayedViewers = (getDisplayed2DViewers() as NSArray? ?? []) as! [ViewerController]
        var state: [NSDictionary] = []
        var statePatients: [String] = []
        let defaults = UserDefaults.standard

        var name = name
        if (name ?? "").isEmpty {
            name = UserDefaults.formatDateTime(Date())
        }

        // The former @try/@catch: an exception logged, the save abandoned.
        func abandon(_ exception: NSException) {
            _N2LogExceptionImpl(exception, true, "+[ViewerController saveWindowsStateWithDICOMSR:name:]")
        }

        do { try HorosObjCException.perform {
            for win in displayedViewers {
                guard let view = win.imageView() else { continue }
                let series = view.seriesObj() as NSObject?

                guard win.studyInstanceUID() != nil, series?.value(forKey: "seriesInstanceUID") != nil else { continue }

                let dict = NSMutableDictionary()
                let frame = win.window?.frame ?? .zero
                dict.setObject(name as Any, forKey: "name" as NSString)
                dict.setObject(ViewerWindowsState.windowPosition(frame), forKey: "window position" as NSString)
                dict.setObject(NSStringFromRect(AppController.usefullRect(for: win.window?.screen)), forKey: "screen" as NSString)
                dict.setObject(NSNumber(value: UInt(bitPattern: (NSScreen.screens as NSArray).index(of: win.window?.screen as Any))), forKey: "screenIndex" as NSString)
                dict.setObject(NSNumber(value: view.rows), forKey: "rows" as NSString)
                dict.setObject(NSNumber(value: view.columns), forKey: "columns" as NSString)

                let first = Int32(win.seriesView()?.firstView()?.curImage ?? 0)
                let indexImage: Int32 = view.flippedData ? Int32(win.getNumberOfImages()) - 1 - first : first
                dict.setObject(NSNumber(value: indexImage), forKey: "index" as NSString)

                let pix = view.curDCM
                if !(pix?.suvConverted ?? false) {
                    dict.setObject(NSNumber(value: pix?.storedWindowLevel(forCalibratedLevel: view.curWL) ?? 0), forKey: "wl" as NSString)
                    dict.setObject(NSNumber(value: view.curWW), forKey: "ww" as NSString)
                } else {
                    dict.setObject(NSNumber(value: pix?.storedWindowLevel(forCalibratedLevel: view.curWL / win.factorPET2SUV()) ?? 0), forKey: "wl" as NSString)
                    dict.setObject(NSNumber(value: view.curWW / win.factorPET2SUV()), forKey: "ww" as NSString)
                }
                dict.setObject(NSNumber(value: view.scaleValue), forKey: "scale" as NSString)
                dict.setObject(NSNumber(value: Double(view.origin.x)), forKey: "x" as NSString)
                dict.setObject(NSNumber(value: Double(view.origin.y)), forKey: "y" as NSString)
                dict.setObject(NSNumber(value: view.rotation), forKey: "rotation" as NSString)
                dict.setObject(NSNumber(value: view.xFlipped), forKey: "xFlipped" as NSString)
                dict.setObject(NSNumber(value: view.yFlipped), forKey: "yFlipped" as NSString)

                dict.setObject(win.studyInstanceUID() as Any, forKey: "studyInstanceUID" as NSString)

                var seriesUIDs: [String] = []
                for x in 0..<Int(win.maxMovieIndex()) {
                    if let pix = win.pixList(x)?.object(at: 0) as? DCMPix, let frameSeries = pix.seriesObj() as NSObject?,
                       let uid = frameSeries.value(forKey: "seriesInstanceUID") as? String {
                        seriesUIDs.append(uid)
                    }
                }
                if let uid = ViewerWindowsState.seriesInstanceUID(of: seriesUIDs) {
                    dict.setObject(uid, forKey: "seriesInstanceUID" as NSString)
                }

                // A series imported from a raster file (TIFF, JPEG...) has no
                // DICOM Series Instance UID: seriesInstanceUID above finds it
                // again, and the restore skips an absent seriesDICOMUID.
                if let seriesDICOMUID = (win.currentSeries() as NSObject?)?.value(forKey: "seriesDICOMUID") {
                    dict.setObject(seriesDICOMUID, forKey: "seriesDICOMUID" as NSString)
                }

                dict.setObject(NSNumber(value: win.maxMovieIndex() > 1), forKey: "4DData" as NSString)

                if let tiling = defaults.object(forKey: "LastWindowsTilingRowsColumns") {
                    dict.setObject(tiling, forKey: "LastWindowsTilingRowsColumns" as NSString)
                }

                // setObject:nil raised: a missing COPYSETTINGS abandoned the save.
                guard let propagate = defaults.object(forKey: "COPYSETTINGS") else {
                    abandon(NSException(name: .invalidArgumentException, reason: "*** -[__NSDictionaryM setObject:forKey:]: object cannot be nil (key: propagateSettings)"))
                    return
                }
                dict.setObject(propagate, forKey: "propagateSettings" as NSString)

                if DCMView.syncro() == Int16(syncroLOC) {
                    dict.setObject(NSNumber(value: true), forKey: "syncSettings" as NSString)
                } else if DCMView.syncro() == Int16(syncroOFF) {
                    dict.setObject(NSNumber(value: false), forKey: "syncSettings" as NSString)
                }

                let betweenStudies = SyncButtonBehaviorIsBetweenStudies.boolValue
                dict.setObject(NSNumber(value: betweenStudies), forKey: "SyncButtonBehaviorIsBetweenStudies" as NSString)
                dict.setObject(NSNumber(value: ViewerController.horos_SYNCSERIES()), forKey: "SYNCSERIES" as NSString)
                if betweenStudies {
                    dict.setObject(NSNumber(value: view.syncRelativeDiff), forKey: "syncRelativeDiff" as NSString)
                }

                dict.setObject(Date(), forKey: "date" as NSString)

                state.append(dict)
                statePatients.append((series?.value(forKeyPath: "study.patientUID") as? String) ?? "")
            }

            // The states are saved only if every displayed window can be.
            if displayedViewers.count != state.count { return }

            let windowsState = try? PropertyListSerialization.data(fromPropertyList: state, format: .xml, options: 0)

            var studies: [NSObject] = []
            for win in displayedViewers {
                guard let view = win.imageView() else { continue }
                if view.curDCM?.generated == true { continue }
                guard let series = view.seriesObj() as NSObject?, series.value(forKey: "seriesInstanceUID") != nil else { continue }
                // addObject:nil raised: a series without a study abandoned the save.
                guard let study = series.value(forKey: "study") as? NSObject else {
                    abandon(NSException(name: .invalidArgumentException, reason: "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil"))
                    return
                }
                if !studies.contains(study) { studies.append(study) }
            }

            for study in studies {
                let own = ViewerWindowsState.entries(of: state, patients: statePatients, patientUID: study.value(forKey: "patientUID") as? String)
                if own.isEmpty { continue }

                let studyState = own.count == state.count ? windowsState : try? PropertyListSerialization.data(fromPropertyList: own, format: .xml, options: 0)
                study.setValue(studyState, forKey: "windowsState")

                if DICOMSR {
                    (study as? DicomStudy)?.archiveWindowsStateAsDICOMSR()
                }
            }
        } } catch {
            if let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException { abandon(e) }
        }
    }
}
