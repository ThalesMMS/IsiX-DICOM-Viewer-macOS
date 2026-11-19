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
import IsiXPreferences

/// The shading presets of the 3D viewers, kept in the shadingsPresets default.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/ShadingArrayController.h> are those of the former class, the array
/// controller of the presets in VR.xib, MPR.xib, CPR.xib and Endoscopy.xib.
@objc(ShadingArrayController)
public final class ShadingArrayController: NSArrayController {
    /// The process's dependencies, made with the controller: the presets are
    /// read from and written to its preferences.
    let processGraph = PreferencesSource.process.processGraph

    /// The former _enableEditing ivar. The xibs bind to enableEditing, and
    /// -setEnableEditing: notifies them as the synthesized KVO did.
    @objc public dynamic var enableEditing: Bool = false

    /// winController of an older header of the former Horos and OsiriX plugin
    /// SDK, exported at this field's offset for the plugins built with it:
    /// the window the controller told to apply the shading it selected. The
    /// 3D windows observe the selection themselves, and no nib connects it:
    /// nothing here reads or writes it, and it is not retained. Typed as any
    /// object: this file names no window controller.
    final unowned(unsafe) var winController: AnyObject?

    public override func add(_ sender: Any?) {
        self.enableEditing = true
        super.add(sender)
    }

    public override func addObject(_ object: Any) {
        let previous = (self.selectedObjects as NSArray).lastObject as AnyObject?
        // [[self content] count], an int; 0 without content, as a message to nil.
        let count = Int32(truncatingIfNeeded: (self.content as? NSArray)?.count ?? 0)
        let item = object as AnyObject

        if count > 0 {
            item.setValue(String(format: "%@ %d", NSLocalizedString("Preset", comment: ""), count + 1), forKey: "name")
            item.setValue(previous?.value(forKey: "ambient"), forKey: "ambient")
            item.setValue(previous?.value(forKey: "diffuse"), forKey: "diffuse")
            item.setValue(previous?.value(forKey: "specular"), forKey: "specular")
            item.setValue(previous?.value(forKey: "specularPower"), forKey: "specularPower")
        } else {
            item.setValue(NSLocalizedString("Default", comment: ""), forKey: "name")
            item.setValue("0.15", forKey: "ambient")
            item.setValue("0.9", forKey: "diffuse")
            item.setValue("0.3", forKey: "specular")
            item.setValue("15", forKey: "specularPower")
        }

        super.addObject(object)
    }

    /// Each preset as it was read, with the dictionary the table edits for it.
    private var readPresets: [(item: AnyObject, preset: ShadingPreset)] = []

    public override func prepareContent() {
        // The table edits each preset in place: one mutable dictionary per
        // preset, with its values within the ranges of the panel's sliders and
        // fields (ShadingPreset.withinRanges).
        let presets: [ShadingPreset] = ImagePresetPreferences.shadingPresets.elements(in: processGraph.preferences)
        let items = presets.map { preset in
            NSMutableDictionary(dictionary: preset.withinRanges.propertyList.object as? [String: Any] ?? [:])
        }
        readPresets = zip(items, presets).map { (item: $0, preset: $1) }
        self.content = NSMutableArray(array: items)
    }

    deinit {
        // What the table did, over the list as it is stored now: another 3D
        // window's table may have written its own changes since this one was
        // read (ShadingPreset.merging). A preset the table did not change
        // counts as it was read, so a value brought within its slider's range
        // changes the user's list only when the user edits that preset.
        // Without content the user's own list goes and the registered one
        // shows again.
        guard let items = self.content as? [Any] else {
            processGraph.preferences.set(nil, for: ImagePresetPreferences.shadingPresets)
            return
        }
        let table: [(read: Int?, preset: ShadingPreset)] = items.compactMap { item in
            PropertyListValue(item).flatMap(ShadingPreset.init(propertyList:)).map { shown in
                let read = readPresets.firstIndex { $0.item === item as AnyObject }
                return (read, read.map { readPresets[$0].preset.stored(after: shown) } ?? shown)
            }
        }
        let stored: [ShadingPreset] = ImagePresetPreferences.shadingPresets.elements(in: processGraph.preferences)
        processGraph.preferences.set(ShadingPreset.merging(read: readPresets.map(\.preset), table: table, into: stored),
                                     for: ImagePresetPreferences.shadingPresets)
    }
}
