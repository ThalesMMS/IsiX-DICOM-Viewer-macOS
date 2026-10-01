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

/// -[VRView ...] as VRView.h declares them, which the controller sends its view
/// (VRView.h is C++). The protocol names the selectors, it is not checked.
@objc private protocol EndoscopyVRViewStateMessages: NSObjectProtocol {
    @objc(get3DStateDictionary) func get3DStateDictionary() -> NSMutableDictionary?
    @objc(set3DStateDictionary:) func set3DStateDictionary(_ dict: NSDictionary?)
    @objc(shading) func shading() -> Int
    @objc(getShadingValues::::) func getShadingValues(_ ambient: UnsafeMutablePointer<Float>!, _ diffuse: UnsafeMutablePointer<Float>!, _ specular: UnsafeMutablePointer<Float>!, _ specularpower: UnsafeMutablePointer<Float>!)
}

/// [view ...]: the controller's VRView, as the messages it answers.
private func stateView(_ view: Any?) -> EndoscopyVRViewStateMessages? {
    return unsafeBitCast(view as AnyObject?, to: EndoscopyVRViewStateMessages?.self)
}

/// [dict setObject: object forKey: key], which raises for nil as the former
/// code did.
private func setObject(_ dict: NSMutableDictionary?, _ object: Any?, _ key: String) {
    _ = dict?.perform(#selector(NSMutableDictionary.setObject(_:forKey:)), with: object, with: key)
}

/// [NSString stringWithFormat:@"VRENDOSCOPY-%@", [[fileList objectAtIndex:0] valueForKey:@"uniqueFilename"]],
/// in the directory of the database's 3D states, which is created if missing.
@MainActor private func endoscopyStatePath(_ fileList: NSArray?) -> String? {
    let path = BrowserController.currentBrowser()?.database?.statesDirPath()
    var isDir: ObjCBool = true

    if !FileManager.default.fileExists(atPath: path ?? "", isDirectory: &isDir) && isDir.boolValue {
        try? FileManager.default.createDirectory(atPath: path ?? "", withIntermediateDirectories: true, attributes: nil)
    }
    let unique = (fileList?.object(at: 0) as AnyObject?)?.value(forKey: "uniqueFilename")
    let name = NSString(format: "VRENDOSCOPY-%@", (unique as? NSObject) ?? ("(null)" as NSString))
    return (path as NSString?)?.appendingPathComponent(name as String)
}

/// The VRController of the endoscopy window: its 3D view looks from the camera
/// the MPR views show, and its state is saved apart from the VR viewer's.
///
/// Implemented in Swift since #827: the Objective-C name, the selectors and
/// <Horos/EndoscopyVRController.h> are those of the former class, the
/// controller object of Endoscopy.xib. Its superclass, VRController, stays in
/// Objective-C; the ivars it reads of it go through VRController+SwiftIvars.h.
/// Its initializer stays in Objective-C, in EndoscopyVRController+CAPI.m.
@objc(EndoscopyVRController)
public final class EndoscopyVRController: VRController {
    // -initWithPix::::: is a method of the category in
    // EndoscopyVRController+CAPI.m. The former -dealloc only sent [super dealloc].

    @objc(save3DState)
    private dynamic func save3DState() {
        // Without a file list, -initWithPix::::: failed: the view never had a
        // volume, and its state is not the series'.
        guard let files = self.fileList() as NSArray?, files.count > 0 else { return }
        let str = endoscopyStatePath(files)

        let dict = stateView(self.view())?.get3DStateDictionary()
        setObject(dict, self.horos_curCLUTMenu, "CLUTName")
        setObject(dict, self.horos_curOpacityMenu, "OpacityName")
        //	[dict setObject:[[shadingsPresetsController selection] valueForKey:@"name"]  forKey:@"shading"]; // crash if 1) flythru panel open & 2) shading panel not opened...

        if (self.viewer2D()?.postprocessed() ?? false) == false {
            if let str = str {
                dict?.write(toFile: str, atomically: true)
            }
        }
    }

    public override dynamic func load3DState() {
        NSLog("Load Endoscopy 3d State")
        let str = endoscopyStatePath(self.fileList() as NSArray?)

        var dict: NSDictionary? = str.flatMap { NSDictionary(contentsOfFile: $0) }

        if self.viewer2D()?.postprocessed() ?? false { dict = nil }

        let view = stateView(self.view())
        view?.set3DStateDictionary(dict)
        NSLog("3d Dict: %@", dict ?? ("(null)" as NSString))
        if dict == nil {
            self.applyWLWW(for: "VR - Endoscopy")
        }

        if let clut = dict?.object(forKey: "CLUTName") { self.applyCLUTString(clut as? String) }
        else { self.applyCLUTString("Endoscopy") }

        if let opacity = dict?.object(forKey: "OpacityName") { self.applyOpacityString(opacity as? String) }
        else { self.applyOpacityString("Logarithmic Table") }

        var shadingName = dict?.object(forKey: "shading") as? String
        if shadingName == nil {
            shadingName = "Endoscopy"
        }

        let presets = self.horos_shadingsPresetsController
        for shading in (presets?.arrangedObjects as? NSArray) ?? NSArray() {
            if ((shading as AnyObject).value(forKey: "name") as? String) == shadingName {
                presets?.setSelectedObjects([shading])
                self.applyShading(nil)
            }
        }

        if (view?.shading() ?? 0) != 0 { self.horos_shadingCheck?.state = .on }
        else { self.horos_shadingCheck?.state = .off }

        var ambient: Float = 0.12
        var diffuse: Float = 0.62
        var specular: Float = 0.73
        var specularpower: Float = 1.0
        //[view setShadingValues:0.12 :0.62 :0.73 :50.0];
        view?.getShadingValues(&ambient, &diffuse, &specular, &specularpower)
        let values = String(format: NSLocalizedString("Ambient: %2.1f\nDiffuse: %2.1f\nSpecular :%2.1f-%2.1f", comment: ""), ambient, diffuse, specular, specularpower)
        NSLog("%@", values)
        self.horos_shadingValues?.stringValue = values
    }

    @IBAction public override dynamic func flyThruControllerInit(_ sender: Any!) {
        //Only open 1 fly through controller
        if self.flyThruController() != nil { return }

        // FTAdapter = [[VRFlyThruAdapter alloc] initWithVRController: self], then
        // [FTAdapter release] once the fly-thru controller retained it: the ivar
        // keeps the adapter without a retain of its own.
        let adapter = VRFlyThruAdapter(vrController: self)
        self.horos_FTAdapter = adapter
        let flyThruController = FlyThruController(flyThruAdapter: adapter)
        // [[FlyThruController alloc] init...]: never released here, as before.
        _ = Unmanaged.passRetained(flyThruController)
        flyThruController.loadWindow()
        flyThruController.window?.makeKeyAndOrderFront(sender)
        flyThruController.setWindow3DController(self)
    }
}
