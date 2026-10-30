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
import IsiXDICOMNetwork

/// The methods that act on the application, the browser and the viewers:
/// KillOsiriX, SwitchToDefaultDBIfNeeded, OpenDB, CloseAllWindows, the viewer
/// lists and closings, DisplayStudyListByPatientName/Id and PathToFrontDCM.
/// Windows and the main-thread database are read on the main thread, and the
/// caller is answered on its own.
extension XMLRPCInterface {

    /// Method: KillOsiriX
    @objc(KillOsiriX:error:)
    public func killOsiriX(_ params: NSDictionary?, error: NSErrorPointer) {
        error?.pointee = nil
        AppController.shared()?.performSelector(onMainThread: NSSelectorFromString("terminate:"), with: self, waitUntilDone: false)
    }

    /// Method: SwitchToDefaultDBIfNeeded
    ///
    /// Parameters:
    /// No parameters
    ///
    /// Response: {error: "0"}
    @objc(SelectDefaultDatabase:error:)
    public func selectDefaultDatabase(_ paramDict: NSDictionary?, error: NSErrorPointer) -> NSDictionary? {
        BrowserController.currentBrowser()?.performSelector(onMainThread: NSSelectorFromString("setDatabase:"),
                                                            with: DicomDatabase.default(), waitUntilDone: false)
        return Self.answer(0)
    }

    /// Method: OpenDB
    ///
    /// Parameters:
    /// path: path of the folder containing the 'Horos Data' folder
    ///
    /// if path is valid, but not DB is found, OsiriX will create a new one
    ///
    /// Example: {path: "/Users/antoinerosset/Documents/"}
    ///
    /// Response: {error: "0"}
    @objc(OpenDatabase:error:)
    public func openDatabase(_ paramDict: NSDictionary?, error: NSErrorPointer) -> NSDictionary? {
        guard let path = RISRequestRules.nonEmptyText(paramDict?.value(forKey: "path")) else {
            return Self.fail(400, error) // Bad Request
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return Self.answer(-1)
        }
        BrowserController.currentBrowser()?.performSelector(onMainThread: NSSelectorFromString("setDatabase:"),
                                                            with: DicomDatabase(atPath: path), waitUntilDone: false)
        return Self.answer(0)
    }

    /// Method: CloseAllWindows
    ///
    /// Parameters: No Parameters
    ///
    /// Response: {error: "0"}
    @objc(CloseAllWindows:error:)
    public func closeAllWindows(_ paramDict: NSDictionary?, error: NSErrorPointer) -> NSDictionary? {
        performSelector(onMainThread: #selector(closeAllWindowsMainThread(_:)), with: nil, waitUntilDone: false)
        Thread.sleep(forTimeInterval: 0.1)
        return Self.answer(0)
    }

    @objc(closeAllWindowsMainThread:)
    func closeAllWindowsMainThread(_ sender: Any?) {
        ViewerController.closeAllWindows()
    }

    /// Method: GetDisplayed2DViewerSeries
    ///
    /// Parameters: No Parameters
    ///
    /// Response: {error: "0", elements: array of series corresponding to displayed windows}
    @objc(GetDisplayed2DViewerSeries:error:)
    public func getDisplayed2DViewerSeries(_ paramDict: NSDictionary?, error: NSErrorPointer) -> NSDictionary? {
        let elements = displayedViewers(keyPath: "imageView.seriesObj")
        return Self.answer(0, elements, forKey: "elements")
    }

    /// Method: GetDisplayed2DViewerStudies
    ///
    /// Parameters: No Parameters
    ///
    /// Response: {error: "0", elements: array of studies corresponding to displayed windows}
    @objc(GetDisplayed2DViewerStudies:error:)
    public func getDisplayed2DViewerStudies(_ paramDict: NSDictionary?, error: NSErrorPointer) -> NSDictionary? {
        let elements = displayedViewers(keyPath: "imageView.seriesObj.study")
        return Self.answer(0, elements, forKey: "elements")
    }

    /// The attributes of the object at `keyPath` of each displayed 2D viewer,
    /// read on the main thread, which owns the windows and the context.
    private func displayedViewers(keyPath: String) -> Any {
        XMLRPCOwnedThreadRead.onMainAndWait {
            let list = NSMutableArray()
            let objects = (ViewerController.getDisplayed2DViewers() ?? NSMutableArray()).value(forKeyPath: keyPath) as? NSArray ?? []
            for case let object as NSManagedObject in objects {
                list.add(XMLRPCOwnedThreadRead.dictionary(for: object))
            }
            return list
        }
    }

    /// Method: Close2DViewerWithSeriesUID
    ///
    /// Parameters:
    /// uid: series instance uid to close
    ///
    /// Example: {uid: "1.3.12.2.1107.5.1.4.51988.4.0.1164229612882469"}
    ///
    /// Response: {error: "0"}
    @objc(Close2DViewerWithSeriesUID:error:)
    public func close2DViewerWithSeriesUID(_ paramDict: NSDictionary?, error: NSErrorPointer) -> NSDictionary? {
        guard let uid = RISRequestRules.nonEmptyText(paramDict?.object(forKey: "uid")) else {
            return Self.fail(400, error)
        }
        closeViewers(whose: "imageView.seriesObj.seriesDICOMUID", is: uid)
        return Self.answer(0)
    }

    /// Method: Close2DViewerWithStudyUID
    ///
    /// Parameters:
    /// uid: study instance uid to close
    ///
    /// Example: {uid: "1.2.840.113745.101000.1008000.37915.4331.5559218"}
    ///
    /// Response: {error: "0"}
    @objc(Close2DViewerWithStudyUID:error:)
    public func close2DViewerWithStudyUID(_ paramDict: NSDictionary?, error: NSErrorPointer) -> NSDictionary? {
        guard let uid = RISRequestRules.nonEmptyText(paramDict?.object(forKey: "uid")) else {
            return Self.fail(400, error)
        }
        closeViewers(whose: "imageView.seriesObj.study.studyInstanceUID", is: uid)
        return Self.answer(0)
    }

    /// Closes, on the main thread, the displayed 2D viewers whose value at
    /// `keyPath` is `uid`.
    private func closeViewers(whose keyPath: String, is uid: String) {
        _ = XMLRPCOwnedThreadRead.onMainAndWait {
            MainActor.assumeIsolated {
                for case let viewer as ViewerController in ViewerController.getDisplayed2DViewers() ?? [] {
                    if (viewer.value(forKeyPath: keyPath) as? NSString)?.isEqual(to: uid) ?? false {
                        viewer.window?.close()
                    }
                }
            }
            return NSNull()
        }
    }

    /// Method: DisplayStudyListByPatientName
    ///
    /// Parameters:
    /// PatientName: name of the patient
    ///
    /// Example: {PatientName: "DOE^JOHN"}
    ///
    /// Response: {error: "0"}
    @objc(DisplayStudyListByPatientName:error:)
    public func displayStudyListByPatientName(_ paramDict: NSDictionary?, error: NSErrorPointer) -> NSDictionary? {
        guard let patientName = RISRequestRules.nonEmptyText(paramDict?.object(forKey: "PatientName")) else {
            return Self.fail(400, error)
        }
        BrowserController.currentBrowser()?.performSelector(onMainThread: NSSelectorFromString("setSearchString:"),
                                                            with: patientName, waitUntilDone: false)
        return Self.answer(0)
    }

    /// Method: DisplayStudyListByPatientId
    ///
    /// Parameters:
    /// PatientID: patient ID
    ///
    /// Example: {id: "0123456789"}
    ///
    /// Response: {error: "0"}
    @objc(DisplayStudyListByPatientId:error:)
    public func displayStudyListByPatientId(_ paramDict: NSDictionary?, error: NSErrorPointer) -> NSDictionary? {
        guard let patientID = RISRequestRules.nonEmptyText(paramDict?.object(forKey: "PatientID")) else {
            return Self.fail(400, error)
        }
        BrowserController.currentBrowser()?.performSelector(onMainThread: NSSelectorFromString("setSearchString:"),
                                                            with: patientID, waitUntilDone: false)
        return Self.answer(0)
    }

    /// Method: PathToFrontDCM
    ///
    /// Parameters:
    /// onlyfilename: string with value "yes" to activate only filename mode; if absent or not equal to "yes", the full path is returned
    ///
    /// Response: {error: "0", currentDCMPath: "/path/to/file.dcm"}
    ///           {error: "0", currentDCMPath: "file.dcm"} if onlyfilename == "yes"
    ///           {error: "0", currentDCMPath: ""} if no viewer is open
    @objc(PathToFrontDCM:error:)
    public func pathToFrontDCM(_ paramDict: NSDictionary?, error: NSErrorPointer) -> NSDictionary? {
        let onlyFilename = (paramDict?.object(forKey: "onlyfilename") as? NSString)?.isEqual(to: "yes") ?? false

        // The front viewer and its image are read on the main thread. An
        // exception there is raised again here, where the call answers it.
        var raised: NSException?
        let path = XMLRPCOwnedThreadRead.onMainAndWait {
            var path: String?
            raised = HorosObjCException.caught {
                MainActor.assumeIsolated {
                    guard let viewer = ViewerController.frontMostDisplayed2DViewer() else { return }
                    let files = viewer.fileList() ?? NSMutableArray()
                    let image = files.object(at: Int(viewer.imageView()?.curImage ?? 0)) as? NSManagedObject
                    path = BrowserController.currentBrowser()?.getLocalDCMPath(image, 0)
                    if onlyFilename {
                        path = (path as NSString?)?.lastPathComponent
                    }
                }
            }
            return path ?? ""
        }
        if let raised {
            raised.raise()
        }
        return Self.answer(0, path, forKey: "currentDCMPath")
    }
}
