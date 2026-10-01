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

/// Window Controller for ROI management
///
/// Implemented in Swift since #714: the Objective-C name, the selectors and
/// <Horos/ROIManagerController.h> are those of the former class.
///
/// As before, the controller owns itself while its window is open: code that
/// makes one does not release it, and -windowWillClose: autoreleases it.
@objc(ROIManagerController)
public final class ROIManagerController: NSWindowController, NSTableViewDataSource {
    /// Not retained, as before. `unowned(unsafe)` and not `weak`: the viewer
    /// is compared by identity with the object of its close notification.
    private unowned(unsafe) var viewer: ViewerController?
    @IBOutlet var tableView: NSTableView!
    private var pixelSpacingZ: Float = 0
    /// YES from -windowWillClose: on, as the flag of OSIWindowController: the
    /// lookups by nib name that reuse this window skip it, since its
    /// -windowWillClose: autoreleased it.
    @objc(windowWillClose) public private(set) var closing = false

    /// Overridden so that -initWithWindowNibName: is inherited, unchanged.
    public override init(window: NSWindow?) {
        super.init(window: window)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// Default initializer
    @objc(initWithViewer:)
    public convenience init(viewer v: ViewerController!) {
        self.init(windowNibName: "ROIManager")
        viewer = nil

        window?.setFrameAutosaveName("ROIManagerWindow")

        // register to notification
        let nc = NotificationCenter.default
        nc.addObserver(self,
                       selector: #selector(CloseViewerNotification(_:)),
                       name: NSNotification.Name.OsirixCloseViewer,
                       object: nil)
        nc.addObserver(self,
                       selector: #selector(roiListModification(_:)),
                       name: NSNotification.Name.OsirixROIChange,
                       object: nil)
        nc.addObserver(self,
                       selector: #selector(fireUpdate(_:)),
                       name: NSNotification.Name.OsirixRemoveROI,
                       object: nil)
        nc.addObserver(self,
                       selector: #selector(roiListModification(_:)),
                       name: NSNotification.Name.OsirixDCMUpdateCurrentImage,
                       object: nil)
        nc.addObserver(self,
                       selector: #selector(roiListModification(_:)),
                       name: NSNotification.Name.OsirixROISelected,
                       object: nil)

        viewer = v
        let curPix = viewer?.pixList()?.object(at: 0) as? DCMPix
        pixelSpacingZ = Float(curPix?.sliceInterval ?? 0)

        fireUpdate(nil)
    }

    /// `[[viewer roiList] objectAtIndex: [[viewer imageView] curImage]]`.
    private func currentROIList() -> NSMutableArray? {
        guard let viewer = viewer, let roiList = viewer.roiList() else { return nil }
        return roiList.object(at: Int(viewer.imageView()?.curImage ?? 0)) as? NSMutableArray
    }

    public func tableView(_ aTableView: NSTableView, setObjectValue anObject: Any?, for aTableColumn: NSTableColumn?, row rowIndex: Int) {
        let curRoiList = currentROIList()
        let editedROI = curRoiList?.object(at: rowIndex) as? ROI

        viewer?.renameSeriesROIwithName(editedROI?.name, newName: anObject as? String)

        tableView?.reloadData()
    }

    public override func keyDown(with event: NSEvent) {
        guard let characters = event.characters, (characters as NSString).length > 0 else { return }

        let c = Int((characters as NSString).character(at: 0))

        if c == NSDeleteFunctionKey || c == NSDeleteCharacter || c == NSBackspaceCharacter || c == NSDeleteCharFunctionKey {
            deleteROI(self)
        }
    }

    /// Delete ROI
    @IBAction @objc(deleteROI:)
    public func deleteROI(_ sender: Any!) {
        let indexSet = (tableView?.selectedRowIndexes ?? IndexSet()) as NSIndexSet
        var index = indexSet.lastIndex

        if index == NSNotFound || index < 0 { return }

        let curRoiList = currentROIList()

        while index != NSNotFound {
            let selectedRoi = curRoiList?.object(at: index) as? ROI

            viewer?.deleteSeriesROIwithName(selectedRoi?.name)

            index = indexSet.indexLessThanIndex(index)
        }

        NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateView, object: nil, userInfo: nil)
    }

    /// Also the action of the timer -fireUpdate: schedules, which passes the
    /// timer: the parameter is not bridged to Notification.
    @objc(roiListModification:)
    public func roiListModification(_ note: NSNotification!) {
        tableView?.reloadData()
    }

    @objc(fireUpdate:)
    public func fireUpdate(_ note: NSNotification!) {
        _ = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(roiListModification(_:)), userInfo: nil, repeats: false)
    }

    // Table view data source methods
    @objc(numberOfRowsInTableView:)
    public func numberOfRows(in tableView: NSTableView) -> Int {
        return currentROIList()?.count ?? 0
    }

    @objc(tableView:objectValueForTableColumn:row:)
    public func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard let viewer = viewer else { return nil }

        guard let curRoiList = currentROIList() else { return nil }

        if curRoiList.count <= row {
            return nil
        }

        let identifier = tableColumn?.identifier.rawValue as NSString?

        if identifier?.isEqual(to: "Index") == true {
            return String(format: "%d", Int32(truncatingIfNeeded: row) &+ 1)
        }

        if identifier?.isEqual(to: "Name") == true {
            return (curRoiList.object(at: row) as? ROI)?.name
        }

        if identifier?.isEqual(to: "area") == true {
            return NSNumber(value: (curRoiList.object(at: row) as? ROI)?.roiArea() ?? 0)
        }

        if identifier?.isEqual(to: "volume") == true {
            let volume = viewer.computeVolume(curRoiList.object(at: row) as? ROI, points: nil, error: nil)

            if volume != 0 {
                if volume < 10 {
                    return String(format: "%2.5f", Double(volume))
                } else {
                    return String(format: "%2.2f", Double(volume))
                }
            } else {
                return NSString(string: NSLocalizedString("n/a", comment: "Abreviation for not available"))
            }
        }

        return nil
    }

    // delegate method setROIMode

    @objc(CloseViewerNotification:)
    func CloseViewerNotification(_ note: NSNotification!) {
        if (note.object as AnyObject?) === viewer {
            viewer = nil

            NSLog("ROIManager CloseViewerNotification")

            window?.close()
        }
    }

    @objc(windowWillClose:)
    public func windowWillClose(_ notification: NSNotification!) {
        closing = true
        window?.acceptsMouseMovedEvents = false

        NotificationCenter.default.removeObserver(self)

        NSLog("ROIManager windowWillClose")

        // [self autorelease]: the reference the code that made it kept.
        _ = Unmanaged.passUnretained(self).autorelease()
    }

    isolated deinit {
        NSLog("ROIManager dealloc")
        tableView?.dataSource = nil
        viewer = nil

        NotificationCenter.default.removeObserver(self)
    }
}
