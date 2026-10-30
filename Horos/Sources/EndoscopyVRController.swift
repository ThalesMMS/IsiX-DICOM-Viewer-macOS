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
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/EndoscopyVRController.h> are those of the former class, the
/// controller object of Endoscopy.xib, which the nib makes empty and the
/// endoscopy viewer then gives its volume (-horosReinitWithPix:...).
@objc(EndoscopyVRController)
public final class EndoscopyVRController: VRController {

    /// The volume of the endoscopy viewer, given to the controller its nib
    /// made: what -initWithPix::::: did when the viewer sent it again to
    /// that controller. NO when it failed (no slice interval or thickness,
    /// images of different sizes, no 3D engine): the controller, which the
    /// nib and the viewer still hold, gives back what it took and stays as
    /// it was, and the viewer does not open.
    @objc(horosReinitWithPix:files:volume:blendingController:viewer:)
    public func horosReinit(pix: NSMutableArray?, files f: NSArray?, volume vData: NSData?,
                            blendingController bC: ViewerController?, viewer vC: ViewerController?) -> Bool {
        for i in 0..<undodata.count { undodata[i] = nil }
        curMovieIndexStorage = 0
        maxMovieIndex = 1
        fileListStorage = f
        pixLists[0] = pix
        volumeData[0] = vData

        guard let firstObject = pix?.object(at: 0) as? DCMPix else {
            abandonReinit()
            return false
        }
        var sliceThickness = abs(firstObject.sliceInterval)

        // Find Minimum Value
        if !firstObject.isRGB { computeMinMax() } else { minimumValueStorage = 0 }

        if sliceThickness == 0 {
            sliceThickness = firstObject.sliceThickness
            if sliceThickness > 0 {
                HorosAlertPanel.runCritical(title: NSLocalizedString("Slice interval", comment: ""),
                                            message: NSLocalizedString("I'm not able to find the slice interval. Slice interval will be equal to slice thickness.", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            } else {
                HorosAlertPanel.runCritical(title: NSLocalizedString("Slice interval/thickness", comment: ""),
                                            message: NSLocalizedString("Problems with slice thickness/interval to do a 3D reconstruction.", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                abandonReinit()
                return false
            }
        }

        // CHECK IMAGE SIZE
        for case let other as DCMPix in pix ?? NSMutableArray()
        where other.pwidth != firstObject.pwidth || other.pheight != firstObject.pheight {
            _ = other
            HorosAlertPanel.runCritical(title: NSLocalizedString("Images size", comment: ""),
                                        message: NSLocalizedString("These images don't have the same height and width to allow a 3D reconstruction...", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            abandonReinit()
            return false
        }

        vrView?.setViewportResizable(false)
        let err = vrView?.setPixSource(pix, vData.map { UnsafeMutablePointer(mutating: $0.bytes.assumingMemoryBound(to: Float.self)) }) ?? 0
        if err != 0 {
            abandonReinit()
            return false
        }

        blendingControllerStorage = bC
        horos_curWLWWMenu = NSLocalizedString("Other", comment: "")

        roi2DPointsArray = NSMutableArray()
        sliceNumber2DPointsArray = NSMutableArray()
        x2DPointsArray = NSMutableArray()
        y2DPointsArray = NSMutableArray()
        z2DPointsArray = NSMutableArray()

        viewer2DStorage = vC
        collect2DPoints(withColour: false)

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(remove3DPoint(_:)), name: .OsirixRemoveROI, object: nil)
        nc.addObserver(self, selector: #selector(add3DPoint(_:)), name: .OsirixROISelected, object: nil)
        nc.addObserver(self, selector: #selector(updateWLWWMenu(_:)), name: .OsirixUpdateWLWWMenu, object: nil)
        nc.addObserver(self, selector: #selector(updateVolumeData(_:)), name: .OsirixUpdateVolumeData, object: nil)
        nc.post(name: .OsirixUpdateWLWWMenu, object: horos_curWLWWMenu, userInfo: nil)

        horos_curCLUTMenu = NSLocalizedString("No CLUT", comment: "")
        nc.addObserver(self, selector: #selector(updateCLUTMenu(_:)), name: .OsirixUpdateCLUTMenu, object: nil)
        nc.post(name: .OsirixUpdateCLUTMenu, object: horos_curCLUTMenu, userInfo: nil)

        horos_curOpacityMenu = NSLocalizedString("Linear Table", comment: "")
        nc.addObserver(self, selector: #selector(updateOpacityMenu(_:)), name: .OsirixUpdateOpacityMenu, object: nil)
        nc.post(name: .OsirixUpdateOpacityMenu, object: horos_curOpacityMenu, userInfo: nil)

        nc.addObserver(self, selector: #selector(clutChanged(_:)), name: .OsirixCLUTChanged, object: nil)

        window?.performZoom(self)

        movieRateSlider?.isEnabled = false
        moviePosSlider?.isEnabled = false
        moviePlayStop?.isEnabled = false

        // The superclass's initializer, which observes the shading presets'
        // selection, is not the one this controller runs: its shading panel's
        // popup applies the chosen preset only through that observer.
        horosObserveShadingSelection()
        return true
    }

    /// What a failed -horosReinit... took, given back: the file list, the
    /// pixel list and the volume. deinit then finds nothing of them, and
    /// -save3DState, without a file list, writes no state.
    private func abandonReinit() {
        pixLists[0] = nil
        volumeData[0] = nil
        fileListStorage = nil
    }

    public override func save3DState() {
        // Without a file list, the volume was never given: the view never had
        // a volume, and its state is not the series'.
        guard let files = horosFileList(), files.count > 0 else { return }
        let str = endoscopyStatePath(files)

        let dict = volumeView?.get3DStateDictionary()
        setObject(dict, horos_curCLUTMenu, "CLUTName")
        setObject(dict, horos_curOpacityMenu, "OpacityName")
        //	[dict setObject:[[shadingsPresetsController selection] valueForKey:@"name"]  forKey:@"shading"]; // crash if 1) flythru panel open & 2) shading panel not opened...

        if (viewer2D()?.postprocessed() ?? false) == false {
            if let str = str {
                dict?.write(toFile: str, atomically: true)
            }
        }
    }

    public override func load3DState() {
        NSLog("Load Endoscopy 3d State")
        let str = endoscopyStatePath(horosFileList())

        var dict: NSDictionary? = str.flatMap { NSDictionary(contentsOfFile: $0) }

        if viewer2D()?.postprocessed() ?? false { dict = nil }

        let view = volumeView
        view?.set3DStateDictionary(dict as? [AnyHashable: Any])
        NSLog("3d Dict: %@", dict ?? ("(null)" as NSString))
        if dict == nil {
            applyWLWW(for: "VR - Endoscopy")
        }

        if let clut = dict?.object(forKey: "CLUTName") { applyCLUTString(clut as? String) }
        else { applyCLUTString("Endoscopy") }

        if let opacity = dict?.object(forKey: "OpacityName") { applyOpacityString(opacity as? String) }
        else { applyOpacityString("Logarithmic Table") }

        var shadingName = dict?.object(forKey: "shading") as? String
        if shadingName == nil {
            shadingName = "Endoscopy"
        }

        let presets = shadingsPresetsController
        for shading in (presets?.arrangedObjects as? NSArray) ?? NSArray() {
            if ((shading as AnyObject).value(forKey: "name") as? String) == shadingName {
                presets?.setSelectedObjects([shading])
                applyShading(nil)
            }
        }

        if (view?.shading() ?? 0) != 0 { shadingCheck?.state = .on }
        else { shadingCheck?.state = .off }

        var ambient: Float = 0.12
        var diffuse: Float = 0.62
        var specular: Float = 0.73
        var specularpower: Float = 1.0
        //[view setShadingValues:0.12 :0.62 :0.73 :50.0];
        view?.getShadingValues(&ambient, &diffuse, &specular, &specularpower)
        let values = String(format: NSLocalizedString("Ambient: %2.1f\nDiffuse: %2.1f\nSpecular :%2.1f-%2.1f", comment: ""), ambient, diffuse, specular, specularpower)
        NSLog("%@", values)
        shadingValues?.stringValue = values
    }

    @IBAction public override func flyThruControllerInit(_ sender: Any!) {
        //Only open 1 fly through controller
        if flyThruController() != nil { return }

        // FTAdapter = [[VRFlyThruAdapter alloc] initWithVRController: self], then
        // [FTAdapter release] once the fly-thru controller retained it: the ivar
        // keeps the adapter without a retain of its own.
        let adapter = VRFlyThruAdapter(vrController: self)
        FTAdapter = adapter
        let flyThruController = FlyThruController(flyThruAdapter: adapter)
        // [[FlyThruController alloc] init...]: never released here, as before.
        _ = Unmanaged.passRetained(flyThruController)
        flyThruController.loadWindow()
        flyThruController.window?.makeKeyAndOrderFront(sender)
        flyThruController.setWindow3DController(self)
    }
}
