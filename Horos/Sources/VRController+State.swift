/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork


import Cocoa

/// The VR window's state in the database's folder of 3D states: the view's
/// camera and settings, the colour table and the opacity (or the 16-bit CLUT)
/// of the series in this rendering mode, written when the window goes and
/// read when it opens. The scissors' state has a file of its own per series.
extension VRController {

    /// The folder of the 3D states, made if missing.
    final func statesDirectory() -> String {
        let path = BrowserController.currentBrowser()?.database?.statesDirPath() ?? ""
        var isDir: ObjCBool = true
        if !FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
        }
        return path
    }

    /// The file of the series' scissors state, for a series or one of its images.
    @objc(getUniqueFilenameScissorStateFor:)
    public static func getUniqueFilenameScissorState(for obj: NSManagedObject!) -> String! {
        let path = BrowserController.currentBrowser()?.database?.statesDirPath() ?? ""
        var isDir: ObjCBool = true
        if !FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
        }
        var series: DicomSeries?
        if let s = obj as? DicomSeries {
            series = s
        } else if obj is DicomImage {
            series = obj.value(forKey: "series") as? DicomSeries
        } else {
            NSLog("******** UNKNOWN class for getUniqueFilenameScissorStateFor")
        }
        let name = String(format: "VR3DScissor-%@", (series?.uniqueFilename() ?? "(null)") as NSString)
        return (path as NSString).appendingPathComponent(name)
    }

    /// The state's file: VRMIP-<mode>-<the first file's unique name>; none
    /// for the hidden renderer of the MPR and the CPR.
    final func stateFile(in path: String) -> String? {
        if styleName == "noNib" { return nil }
        let unique = (fileListStorage?.firstObject as AnyObject?)?.value(forKey: "uniqueFilename")
        let name = NSString(format: "VRMIP-%d-%@", Int32(truncatingIfNeeded: vrView?.mode() ?? 0),
                            (unique as? NSObject) ?? ("(null)" as NSString))
        return (path as NSString).appendingPathComponent(name as String)
    }

    @objc(save3DState)
    public func save3DState() {
        let path = statesDirectory()
        guard let str = stateFile(in: path), let dict = vrView?.get3DStateDictionary() else { return }
        if let clut = horos_curCLUTMenu { dict.setObject(clut, forKey: "CLUTName" as NSString) }
        dict.setObject(NSNumber(value: vrView?.advancedCLUT() ?? false), forKey: "isAdvancedCLUT" as NSString)
        if vrView?.advancedCLUT() != true, let opacity = horos_curOpacityMenu {
            dict.setObject(opacity, forKey: "OpacityName" as NSString)
        }
        if horos_curCLUTMenu == NSLocalizedString("16-bit CLUT", comment: "") || horos_curCLUTMenu == "16-bit CLUT" {
            if let curves = clutOpacityView?.convertCurvesForPlist() { dict.setObject(curves, forKey: "16bitClutCurves" as NSString) }
            if let colors = clutOpacityView?.convertPointColorsForPlist() { dict.setObject(colors, forKey: "16bitClutColors" as NSString) }
        }
        if viewer2DStorage?.postprocessed() != true {
            dict.write(toFile: str, atomically: true)
        }
    }

    /// A saved state that raises an Objective-C exception (an old or damaged
    /// plist whose values are not of the type the view reads) is logged and
    /// what was left of it skipped, as the former @try did.
    public override func load3DState() {
        if let e = HorosObjCException.caught({ applySavedState() }) {
            _N2LogExceptionImpl(e, false, "-[VRController load3DState]")
        }
    }

    private func applySavedState() {
        let path = statesDirectory()
        let str = stateFile(in: path)
        var dict: NSDictionary? = str.flatMap { NSDictionary(contentsOfFile: $0) }
        if viewer2DStorage?.postprocessed() == true { dict = nil }

        vrView?.set3DStateDictionary(dict as? [AnyHashable: Any])

        var has16bitCLUT = false
        // The 16-bit CLUT a state holds, checked whole: a malformed one (a
        // state from another machine) leaves the default CLUT and opacity.
        var clutName = dict?.object(forKey: "CLUTName") as? String
        var saved16bitCLUT: NSDictionary?
        var refused16bitCLUT = false
        let isAdvancedCLUT = (dict?.object(forKey: "isAdvancedCLUT") as? NSNumber)?.boolValue ?? false
        if let name = clutName, isAdvancedCLUT, name == NSLocalizedString("16-bit CLUT", comment: "") || name == "16-bit CLUT" {
            saved16bitCLUT = RestrictedUnarchiver.plistCLUT(curves: dict?.object(forKey: "16bitClutCurves"),
                                                       colors: dict?.object(forKey: "16bitClutColors"),
                                                       source: ((str ?? "") as NSString).lastPathComponent)
            if saved16bitCLUT == nil {
                clutName = nil
                refused16bitCLUT = true
            }
        } else if let name = clutName, isAdvancedCLUT, CLUTOpacityView.presetFromFile(withName: name) == nil {
            // A CLUT file that is gone or refused: the default too, not a
            // title over an empty editor.
            clutName = nil
            refused16bitCLUT = true
        }

        let first = pixLists[0]?.object(at: 0) as? DCMPix
        if let clutName {
            if isAdvancedCLUT {
                clutPopup()?.menu?.item(at: 0)?.title = clutName
                setCurCLUTMenu(clutName)
                if let saved = saved16bitCLUT {
                    let curves = saved.object(forKey: "curves") as? NSMutableArray
                    let colors = saved.object(forKey: "colors") as? NSMutableArray
                    let clut = NSMutableDictionary(capacity: 2)
                    if let curves { clut.setObject(curves, forKey: "curves" as NSString) }
                    if let colors { clut.setObject(colors, forKey: "colors" as NSString) }
                    if let curves { clutOpacityView?.setCurves(curves) }
                    if let colors { clutOpacityView?.setPointColors(colors) }
                    vrView?.setAdvancedCLUT(clut, lowResolution: false)
                } else {
                    loadAdvancedCLUTOpacity(clutPopup())
                }
                has16bitCLUT = true
            } else {
                applyCLUTString(clutName)
            }
        } else if vrView?.mode() == 0 && first?.isRGB == false {
            applyCLUTString("VR Muscles-Bones") // For VR mode only
        }

        if !has16bitCLUT {
            if let opacity = dict?.object(forKey: "OpacityName") as? String, !refused16bitCLUT {
                applyOpacityString(opacity)
            } else if vrView?.mode() == 0 && first?.isRGB == false {
                applyOpacityString(NSLocalizedString("Logarithmic Inverse Table", comment: "")) // For VR mode only
            }
        }

        shadingCheck?.state = (vrView?.shading() ?? 0) != 0 ? .on : .off

        var ambient: Float = 0, diffuse: Float = 0, specular: Float = 0, specularpower: Float = 0
        vrView?.getShadingValues(&ambient, &diffuse, &specular, &specularpower)
        shadingValues?.stringValue = String(format: NSLocalizedString("Ambient: %2.1f\nDiffuse: %2.1f\nSpecular :%2.1f-%2.1f", comment: ""),
                                            ambient, diffuse, specular, specularpower)
    }
}
