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

import Cocoa

/// Window Controller for managing ROIVolume collection.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/ROIVolumeManagerController.h> are those of the former class, the
/// File's Owner of ROIVolumeManager.xib, whose object controller binds to
/// roiVolumes. The ROIVolume messages go through ROIVolumeHostBridge, because
/// ROIVolume.h is C++.
@objc(ROIVolumeManagerController)
public final class ROIVolumeManagerController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    /// The 3D window controller, which was not retained: weak.
    private weak var viewer: Window3DController?
    @IBOutlet private var tableView: NSTableView?
    @IBOutlet private var columnDisplay: NSTableColumn?
    @IBOutlet private var columnName: NSTableColumn?
    @IBOutlet private var columnVolume: NSTableColumn?
    @IBOutlet private var columnRed: NSTableColumn?
    @IBOutlet private var columnGreen: NSTableColumn?
    @IBOutlet private var columnBlue: NSTableColumn?
    @IBOutlet private var columnOpacity: NSTableColumn?
    private var roiVolumesStorage: NSMutableArray?//, *displayRoiVolumes;
    @IBOutlet private var roiVolumesController: NSArrayController?
    @IBOutlet private var controllerAlias: NSObjectController?

    /// -initWithWindowNibName:@"ROIVolumeManager", through the Objective-C
    /// initializer.
    @objc(initWithViewer:)
    public convenience init(viewer v: Window3DController?) {
        self.init(windowNibName: "ROIVolumeManager")

        roiVolumesStorage = NSMutableArray(capacity: 0)
        roiVolumesStorage?.setArray((v?.roiVolumes() as NSArray?) as? [Any] ?? [])

        viewer = v

//	[self setRoiVolumes:[v roiVolumes]];

        //[[self window] setFrameAutosaveName:@"ROIVolumeManagerWindow"];

        // register to notification
        let nc = NotificationCenter.default
        nc.addObserver(self,
                       selector: #selector(Window3DClose(_:)),
                       name: .OsirixWindow3dClose,
                       object: nil)
        tableView?.dataSource = self
        //[tableView setDelegate:self];
    }

    public override func windowDidLoad() {
        super.windowDidLoad()
        tableView?.delegate = self
        tableView?.rowHeight = 26.0
        for column in tableView?.tableColumns ?? [] {
            let key = column.identifier.rawValue == "display" ? "visible" : column.identifier.rawValue
            column.sortDescriptorPrototype = NSSortDescriptor(key: "properties." + key, ascending: true)
        }
    }

    /// The ROIVolume of a row, or nil.
    @objc(volumeAtRow:)
    public func volume(atRow row: Int) -> Any? {
        let volumes = (roiVolumesController?.arrangedObjects as? NSArray) ?? NSArray()
        return row >= 0 && row < volumes.count ? volumes.object(at: row) : nil
    }

    /// [volume properties]
    private func properties(of volume: Any?) -> NSMutableDictionary? {
        return ROIVolumeHostBridge.properties(ofVolume: volume)
    }

    @objc(numberOfRowsInTableView:)
    public func numberOfRows(in aTableView: NSTableView) -> Int {
        return (roiVolumesController?.arrangedObjects as? NSArray)?.count ?? 0
    }

    @objc(tableView:viewForTableColumn:row:)
    public func tableView(_ aTableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let volume = self.volume(atRow: row) else { return nil }

        let identifier = column?.identifier.rawValue ?? ""
        let checkbox = identifier == "display" || identifier == "texture"
        let slider = identifier == "red" || identifier == "green" ||
                     identifier == "blue" || identifier == "opacity"
        var cell = aTableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(identifier), owner: self) as? NSTableCellView
        var control = cell?.viewWithTag(1) as? NSControl
        if cell == nil {
            let newCell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: column?.width ?? 0, height: aTableView.rowHeight))
            newCell.identifier = NSUserInterfaceItemIdentifier(identifier)
            let newControl: NSControl
            if slider {
                // A cell-only slider uses the entire NSTableView as its controlView.
                // Give each slider its own view so drawing and tracking share bounds.
                let valueSlider = NSSlider(value: 0, minValue: 0, maxValue: 1,
                                           target: self, action: #selector(changeROIVolume(_:)))
                valueSlider.isContinuous = true
                newControl = valueSlider
            } else if checkbox {
                newControl = NSButton(checkboxWithTitle: "", target: self, action: #selector(changeROIVolume(_:)))
            } else {
                let text = NSTextField(frame: .zero)
                text.isBordered = false
                text.drawsBackground = false
                text.isEditable = (column?.dataCell as? NSCell)?.isEditable ?? false
                text.isSelectable = true
                text.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
                text.lineBreakMode = .byTruncatingTail
                newCell.textField = text
                newControl = text
            }
            newControl.tag = 1
            newControl.controlSize = .small
            newControl.target = self
            newControl.action = #selector(changeROIVolume(_:))
            newControl.translatesAutoresizingMaskIntoConstraints = false
            newCell.addSubview(newControl)
            NSLayoutConstraint.activate([
                newControl.centerYAnchor.constraint(equalTo: newCell.centerYAnchor),
                newControl.heightAnchor.constraint(equalToConstant: 20.0)
            ])
            if checkbox {
                NSLayoutConstraint.activate([
                    newControl.centerXAnchor.constraint(equalTo: newCell.centerXAnchor)
                ])
            } else {
                NSLayoutConstraint.activate([
                    newControl.leadingAnchor.constraint(equalTo: newCell.leadingAnchor, constant: 4.0),
                    newControl.trailingAnchor.constraint(equalTo: newCell.trailingAnchor, constant: -4.0)
                ])
            }
            cell = newCell
            control = newControl
        }
        let key = identifier == "display" ? "visible" : identifier
        let properties = self.properties(of: volume)
        control?.objectValue = properties?.object(forKey: key)
        var label = column?.headerCell.stringValue ?? ""
        if (label as NSString).length == 0 { label = NSLocalizedString("Visible", comment: "") }
        let name = (properties?.object(forKey: "name") as? NSObject) ?? ("(null)" as NSString)
        control?.setAccessibilityLabel(String(format: "%@, %@", label, name))
        return cell
    }

    @objc(changeROIVolume:)
    public func changeROIVolume(_ sender: NSControl?) {
        guard let tableView = tableView, let sender = sender else { return }
        let row = tableView.row(for: sender)
        let column = tableView.column(for: sender)
        if row < 0 || column < 0 { return }
        self.tableView(tableView, setObjectValue: sender.objectValue,
                       for: tableView.tableColumns[column], row: row)
    }

    @objc(tableView:setObjectValue:forTableColumn:row:)
    public func tableView(_ aTableView: NSTableView, setObjectValue value: Any?, for column: NSTableColumn?, row: Int) {
        guard let volume = self.volume(atRow: row) else { return }
        let identifier = column?.identifier.rawValue ?? ""
        let object = value as AnyObject?
        let boolValue = object?.boolValue ?? false
        let floatValue = object?.floatValue ?? 0
        if identifier == "display" {
            ROIVolumeHostBridge.setVisible(boolValue, ofVolume: volume)
            if boolValue {
                ROIVolumeHostBridge.displayROIVolume(volume, inViewer: viewer)
            } else {
                ROIVolumeHostBridge.hideROIVolume(volume, inViewer: viewer)
            }
        } else if identifier == "red" {
            ROIVolumeHostBridge.setRed(floatValue, ofVolume: volume)
        } else if identifier == "green" {
            ROIVolumeHostBridge.setGreen(floatValue, ofVolume: volume)
        } else if identifier == "blue" {
            ROIVolumeHostBridge.setBlue(floatValue, ofVolume: volume)
        } else if identifier == "opacity" {
            ROIVolumeHostBridge.setOpacity(floatValue, ofVolume: volume)
        } else if identifier == "texture" {
            ROIVolumeHostBridge.setTexture(boolValue, ofVolume: volume)
        } else {
            // Preserve the name/volume fields' former properties-dictionary bindings.
            self.properties(of: volume)?.setValue(value, forKey: identifier)
            return
        }
        (viewer?.view() as? NSView)?.display()
        // Reloading here would replace a continuous slider while it is tracking.
    }

    @objc(tableView:sortDescriptorsDidChange:)
    public func tableView(_ aTableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        let selected = self.volume(atRow: aTableView.selectedRow)
        roiVolumesController?.sortDescriptors = aTableView.sortDescriptors
        aTableView.reloadData()
        let arranged = (roiVolumesController?.arrangedObjects as? NSArray) ?? NSArray()
        let row = selected.map { arranged.indexOfObjectIdentical(to: $0) } ?? NSNotFound
        if row != NSNotFound {
            aTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    // delegate method

    @objc(Window3DClose:)
    public func Window3DClose(_ note: Notification?) {
        if (note?.object as AnyObject?) === viewer {
            NSLog("ROIVolumeManager Window3DClose")
            self.window?.close()
        }
    }

    @objc(windowWillClose:)
    public func windowWillClose(_ notification: Notification?) {
        self.window?.acceptsMouseMovedEvents = false

        NotificationCenter.default.removeObserver(self)
        NSLog("ROIVolumeManager windowWillClose")
        tableView?.delegate = nil
        tableView?.dataSource = nil
        controllerAlias?.content = nil // To allow the dealloc of MPRController ! otherwise memory leak

        // Balances the alloc of the caller, which never releases the window controller.
        _ = Unmanaged.passUnretained(self).autorelease()
    }

    deinit {
        NSLog("ROIVolumeManager dealloc")
        NotificationCenter.default.removeObserver(self)
    }

    @objc(setRoiVolumes:)
    public func setRoiVolumes(_ volumes: NSMutableArray?) {
//	NSLog(@"setRoiVolumes : [volumes count] : %d", [volumes count]);
        roiVolumesStorage?.setArray((volumes as? [Any]) ?? [])
//	NSLog(@"setRoiVolumes : [roiVolumes count] : %d", [roiVolumes count]);
//	NSLog(@"setRoiVolumes : [[self roiVolumes] count] : %d", [[self roiVolumes] count]);
    }

    @objc public func roiVolumes() -> NSMutableArray? {
        return roiVolumesStorage
    }
}
