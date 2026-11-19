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
import IsiXImaging
import IsiXPreferences

/// The VR window's state in the database's folder of 3D states: the view's
/// camera and settings, the colour table and the opacity (or the 16-bit CLUT)
/// of the series in this rendering mode, written when the window goes and
/// read when it opens, when the window holds the series (horosStateIsSeries).
/// The scissors' state has a file of its own per series. Without a saved
/// state, the window shows the presentation of a first opening
/// (VolumeRenderingOpening), which Revert Series restores.
extension VRController {

    // MARK: - State kept in the layout of the former plugin SDK

    /// The window's style: "standard", "panel" or "noNib".
    nonisolated final var styleName: String? {
        get { _style as String? }
        set { _style = newValue as NSString? }
    }

    /// "VR" or "MIP", as the window was opened or as its mode was last chosen.
    final var renderingModeStorage: String? {
        get { _renderingMode as String? }
        set { _renderingMode = newValue as NSString? }
    }

    /// The images, the volume and the ROI volumes of each time of the series,
    /// and the copy of each volume that Undo puts back: the arrays inside the
    /// window, where a plugin of the former SDK reads and writes them.
    nonisolated final var pixLists: VRControllerFrameObjects<NSMutableArray> {
        VRControllerFrameObjects(fieldAt: VRControllerArrayOffsets.pixList, of: self)
    }
    nonisolated final var volumeData: VRControllerFrameObjects<NSData> {
        VRControllerFrameObjects(fieldAt: VRControllerArrayOffsets.volumeData, of: self)
    }
    nonisolated final var roiVolumeLists: VRControllerFrameObjects<NSMutableArray> {
        VRControllerFrameObjects(fieldAt: VRControllerArrayOffsets.roiVolumes, of: self)
    }
    final var undodata: VRControllerUndoVolumes {
        VRControllerUndoVolumes(fieldAt: VRControllerArrayOffsets.undodata, of: self)
    }

    // MARK: - Saved state

    /// The folder of the 3D states, made if missing.
    final func statesDirectory() -> String {
        let path = browserWindowGraph?.database?.statesDirPath() ?? ""
        var isDir: ObjCBool = true
        if !FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
        }
        return path
    }

    /// The file of the series' scissors state, for a series or one of its images.
    /// Nonisolated: deleting a series asks for it on the thread of the context
    /// that saves, which is the cleaning thread or the import's.
    @objc(getUniqueFilenameScissorStateFor:)
    public nonisolated static func getUniqueFilenameScissorState(for obj: NSManagedObject!) -> String! {
        let path = BrowserDatabaseSource.process.browserDatabase?.statesDirPath() ?? ""
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

    /// Whether the window's state is the series' own: the window opened on
    /// the series as its files have it, its 2D viewer (when it has one) not
    /// post-processed then. A change of plane afterwards gives the 2D viewer
    /// other slices and makes it post-processed, but leaves this window the
    /// slices it opened on, whose state it still writes and reads. A window
    /// opened on a resliced or resampled series holds another volume under
    /// the name of the series' first file (a resliced slice's file is the
    /// first slice's): it neither writes nor reads a state.
    final func horosStateIsSeries() -> Bool {
        viewer2DStorage == nil || horosSlicesFromFiles
    }

    @objc(save3DState)
    public func save3DState() {
        guard horosStateIsSeries() else { return }
        let path = statesDirectory()
        guard let str = stateFile(in: path), let dict = vrView?.get3DStateDictionary() else { return }
        if let clut = horos_curCLUTMenu { dict.setObject(clut, forKey: "CLUTName" as NSString) }
        dict.setObject(NSNumber(value: vrView?.advancedCLUT() ?? false), forKey: "isAdvancedCLUT" as NSString)
        if vrView?.advancedCLUT() != true, let opacity = horos_curOpacityMenu {
            dict.setObject(opacity, forKey: "OpacityName" as NSString)
        }
        if AnyLanguage.says(horos_curCLUTMenu, "16-bit CLUT") {
            if let curves = clutOpacityView?.convertCurvesForPlist() { dict.setObject(curves, forKey: "16bitClutCurves" as NSString) }
            if let colors = clutOpacityView?.convertPointColorsForPlist() { dict.setObject(colors, forKey: "16bitClutColors" as NSString) }
        }
        dict.write(toFile: str, atomically: true)
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
        let dict: NSDictionary? = horosStateIsSeries() ? str.flatMap { NSDictionary(contentsOfFile: $0) } : nil

        vrView?.set3DStateDictionary(dict as? [AnyHashable: Any])

        var has16bitCLUT = false
        // The 16-bit CLUT a state holds, checked whole: a malformed one (a
        // state from another machine) leaves the default CLUT and opacity.
        // The 16-bit colour table and the absence of one, as the state of
        // another day wrote them, are the menu's of today.
        var clutName = AnyLanguage.tableName(stored: dict?.object(forKey: "CLUTName") as? String)
        var saved16bitCLUT: NSDictionary?
        var refused16bitCLUT = false
        let isAdvancedCLUT = (dict?.object(forKey: "isAdvancedCLUT") as? NSNumber)?.boolValue ?? false
        if let name = clutName, isAdvancedCLUT, AnyLanguage.says(name, "16-bit CLUT") {
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
        let volumeRendering = vrView?.mode() == 0, isRGB = first?.isRGB ?? true
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
        } else if let modeTable = VolumeRenderingOpening.modeColourTable(volumeRendering: volumeRendering, isRGB: isRGB) {
            applyCLUTString(modeTable)
        }

        if !has16bitCLUT {
            if let opacity = dict?.object(forKey: "OpacityName") as? String, !refused16bitCLUT {
                applyOpacityString(opacity)
            } else if let modeTable = VolumeRenderingOpening.modeOpacityTable(volumeRendering: volumeRendering, isRGB: isRGB) {
                applyOpacityString(opacityName(modeTable))
            }
        }

        horosShowShading()
    }

    /// The name of an opacity table of the opening, as its menu and the
    /// presets name it: the presets keep their English names in every
    /// language, and only "Linear Table", which is not a preset, is compared
    /// translated (-applyOpacityString:). A translated preset name would be
    /// taken as the current table without changing the volume.
    private func opacityName(_ table: VolumeRenderingOpening.OpacityTable) -> String {
        switch table {
        case .linear: return NSLocalizedString("Linear Table", comment: "")
        case .logarithmic: return "Logarithmic Table"
        case .logarithmicInverse: return "Logarithmic Inverse Table"
        }
    }

    /// The shading check box and the shading values as the view has them.
    private func horosShowShading() {
        shadingCheck?.state = (vrView?.shading() ?? 0) != 0 ? .on : .off

        var ambient: Float = 0, diffuse: Float = 0, specular: Float = 0, specularpower: Float = 0
        vrView?.getShadingValues(&ambient, &diffuse, &specular, &specularpower)
        horosShowShadingValues(.init(ambient: ambient, diffuse: diffuse, specular: specular, specularPower: specularpower))
    }

    /// Revert Series: the presentation of a first opening of the window on its
    /// series, as if no 3D state were saved, from the 2D viewer as it is now
    /// (VolumeRenderingOpening): its colour table and window level, the
    /// defaults of the rendering mode, the shading the window is made with.
    /// The floating 3D panel gets its own opening instead: the colour table it
    /// is made with, or the PET tables and window of a PET series. The 8-bit
    /// colour table empties the 16-bit CLUT editor and its undo history, and
    /// closes it. The camera, the crop box and the clipping range stay, as do
    /// the fused series' tables: they are Reset to Initial View's and the
    /// fusion's.
    final func restoreOpeningPresentation() {
        let opening = openingPresentation()

        applyCLUTString(opening.colourTable)
        applyOpacityString(opacityName(opening.opacityTable))
        // The window level last: the view lays the colour and opacity tables
        // over it again.
        setWLWW(opening.windowLevel, opening.windowWidth)
        applyWLWW(for: NSLocalizedString("Other", comment: ""))

        if let shading = opening.shading { vrView?.activateShading(shading) }
        let values = VolumeRenderingOpening.shadingValues
        vrView?.setShadingValues(values.ambient, values.diffuse, values.specular, values.specularPower)
        horosShowShading()
        // The shading presets panel, if open, selects the preset of these values.
        findShadingPreset(self)
        vrView?.needsDisplay = true
    }

    /// What a first opening of this window shows, read from the 2D viewer and
    /// the preferences as the opening reads them (ThreeDViewerLauncher).
    private func openingPresentation() -> VolumeRenderingOpening {
        let first = pixLists[0]?.object(at: 0) as? DCMPix
        var level: Float = 0, width: Float = 0
        if let imageView = viewer2DStorage?.imageView() {
            imageView.getWLWW(&level, &width)
        } else {
            getWLWW(&level, &width)
        }
        let preferences = processGraph.preferences
        let volumeRendering = vrView?.mode() == 0, isRGB = first?.isRGB ?? true
        let isPET = viewerIsEqualToString(viewer2DStorage?.modality(), "PT")
        let noColourTable = NSLocalizedString("No CLUT", comment: "")
        let defaultShading = preferences[VolumeRenderingPreferences.defaultShading]
        if styleName == "panel" {
            let shown = pixLists[Int(curMovieIndexStorage)]?.object(at: 0) as? DCMPix
            return .panel(volumeRendering: volumeRendering, isRGB: isRGB, isPET: isPET, noColourTable: noColourTable,
                          petColourTable: VolumeRenderingOpening.petColourTable(clutMode: preferences[ViewerPreferences.petCLUTMode],
                                                                                defaultTable: preferences[ViewerPreferences.petDefaultCLUT]),
                          suvConverted: viewer2DStorage?.imageView()?.curDCM?.suvConverted ?? false,
                          maximumValue: shown?.maxValueOfSeries ?? 0,
                          viewerWindowLevel: level, viewerWindowWidth: width, defaultShading: defaultShading)
        }
        let viewerColourTable = viewer2DStorage.flatMap { $0.horos_backCurCLUTMenu ?? $0.horos_curCLUTMenu }
        return VolumeRenderingOpening(volumeRendering: volumeRendering, isRGB: isRGB, isPET: isPET,
                                      viewerColourTable: viewerColourTable ?? noColourTable,
                                      viewerWindowLevel: level, viewerWindowWidth: width, defaultShading: defaultShading)
    }
}

/// Where the C arrays of the former plugin SDK are inside a VRController. The
/// arrays are fields of the window, at the offsets the application exports to
/// plugins; the code that uses them needs their address, which is the
/// window's plus the field's offset as the runtime has it.
enum VRControllerArrayOffsets {
    static let pixList = offset("_pixList"), volumeData = offset("_volumeData")
    static let roiVolumes = offset("_roiVolumes"), undodata = offset("_undodata")

    private static func offset(_ field: String) -> Int {
        guard let variable = class_getInstanceVariable(VRController.self, field) else {
            preconditionFailure("VRController keeps no field named \(field)")
        }
        return ivar_getOffset(variable)
    }
}

/// An array of one object per time of a 4D series that is a field of a
/// VRController, used in place: the slots are that memory itself, the
/// window's address plus the field's offset, good while the window lives.
/// Storing an object retains it and releases the one it replaces, and the
/// window releases what is left as it goes. The slots are untyped pointers,
/// as the C struct that declares the array has them.
struct VRControllerFrameObjects<Value: AnyObject> {
    private let slots: UnsafeMutablePointer<UnsafeMutableRawPointer?>

    init(fieldAt offset: Int, of window: VRController) {
        slots = (Unmanaged.passUnretained(window).toOpaque() + offset).assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    }

    var count: Int { Int(MAX4D) }

    subscript(index: Int) -> Value? {
        get {
            precondition(index >= 0 && index < count, "a time of the series out of range")
            return slots[index].map { Unmanaged<Value>.fromOpaque($0).takeUnretainedValue() }
        }
        nonmutating set {
            precondition(index >= 0 && index < count, "a time of the series out of range")
            let former = slots[index]
            slots[index] = newValue.map { Unmanaged.passUnretained($0).retain().toOpaque() }
            if let former { Unmanaged<AnyObject>.fromOpaque(former).release() }
        }
    }

    func releaseAll() {
        for index in 0..<count where slots[index] != nil { self[index] = nil }
    }
}

/// The copies of the volumes that Undo puts back, one per time of the series,
/// in the array that is a field of a VRController: malloc'ed, and freed by
/// the window.
struct VRControllerUndoVolumes {
    private let slots: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>

    init(fieldAt offset: Int, of window: VRController) {
        slots = (Unmanaged.passUnretained(window).toOpaque() + offset).assumingMemoryBound(to: UnsafeMutablePointer<Float>?.self)
    }

    var count: Int { Int(MAX4D) }

    subscript(index: Int) -> UnsafeMutablePointer<Float>? {
        get {
            precondition(index >= 0 && index < count, "a time of the series out of range")
            return slots[index]
        }
        nonmutating set {
            precondition(index >= 0 && index < count, "a time of the series out of range")
            slots[index] = newValue
        }
    }

    func contains(where predicate: (UnsafeMutablePointer<Float>?) -> Bool) -> Bool {
        (0..<count).contains { predicate(slots[$0]) }
    }
}
