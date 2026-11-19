/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Cocoa
import IsiXVolumeRendering

/// Window Controller for Surface Rendering.
///
/// Implemented in Swift: the Objective-C name, the selectors, the outlets and
/// the bindings of SR.xib are those of the former class. The controller's
/// responsibilities are spread over its extensions: the toolbar
/// (SRController+Toolbar.swift), and the 3D points, the ROI volumes, the fly
/// through and the image exports (SRController+Points.swift).
/// @usableFromInline because plugins built against the former SDK look up its
/// Objective-C class: without it, the class symbol of an internal Swift class is
/// private external, which a Release build, having no testability, leaves
/// unexported. The attribute gives it public linkage and changes nothing else.
@objc(SRController) @usableFromInline
final class SRController: Window3DController, NSToolbarDelegate, NSToolbarItemValidation {
    // MARK: Outlets of SR.xib

    // The outlets, the surfaces' settings and the fields of the series and of
    // the points below are the instance variables of the former Horos and
    // OsiriX plugin SDK, each a stored field with the type its header
    // declared: a plugin reads and writes them at the exported offset, and no
    // setter runs.
    @IBOutlet var toolsView: NSView?
    @IBOutlet var LODView: NSView?
    @IBOutlet var BlendingView: NSView?
    @IBOutlet var export3DView: NSView?
    @IBOutlet var perspectiveView: NSView?
    @IBOutlet var OrientationsView: NSView?
    @IBOutlet var BackgroundColorView: NSView?
    @IBOutlet var SRSettingsWindow: NSWindow?
    // The Stereo menu and its screen geometry.
    @IBOutlet var stereoIconView: NSView?
    @IBOutlet var SRGeometrieSettingsWindow: NSWindow?
    @IBOutlet var distanceValue: NSTextField?
    @IBOutlet var heightValue: NSTextField?
    @IBOutlet var eyeDistance: NSTextField?
    // Outlets that only older copies of that SDK's headers declare, and that
    // SR.xib connects under these names: the slider of the level of detail,
    // the text and the slider of the fusion, and the controls of the settings
    // sheet. The window reaches the controls by bindings and actions and
    // reads none of these; they hold what the nib connects.
    @IBOutlet var LODSlider: NSSlider?
    @IBOutlet var blendingPercentage: NSTextField?
    @IBOutlet var blendingSlider: NSSlider?
    @IBOutlet var checkFirst: NSButton?
    @IBOutlet var checkSecond: NSButton?
    @IBOutlet var firstValue: NSTextField?
    @IBOutlet var secondValue: NSTextField?
    @IBOutlet var resolSlide: NSSlider?
    @IBOutlet var firstTrans: NSSlider?
    @IBOutlet var secondTrans: NSSlider?
    @IBOutlet var firstPopup: NSPopUpButton?
    @IBOutlet var secondPopup: NSPopUpButton?
    @IBOutlet var preprocessMatrix: NSMatrix?
    // The two text fields of the sheet that those headers named decimate and
    // smooth, the names the numbers have here. The nib connects no outlet of
    // those names: a connection would hand the field's pointer to the setter
    // of the number. The fields are found in the sheet, by the number each is
    // bound to, when the nib is loaded. Copies, read by nothing.
    var decimateFieldOfOlderSDK: NSTextField?, smoothFieldOfOlderSDK: NSTextField?
    // The second settings sheet of those headers, for the fused series, and
    // its controls. SR.xib has one sheet, which edits the surfaces of the
    // fused series too (fusionSettingsWindow): nothing stands behind these
    // outlets, nil unless a plugin stores one, and never released.
    unowned(unsafe) var BSRSettingsWindow: NSWindow?
    unowned(unsafe) var BcheckFirst: NSButton?, BcheckSecond: NSButton?
    unowned(unsafe) var BfirstValue: NSTextField?, BsecondValue: NSTextField?, Bdecimate: NSTextField?, Bsmooth: NSTextField?
    unowned(unsafe) var BresolSlide: NSSlider?, BfirstTrans: NSSlider?, BsecondTrans: NSSlider?
    unowned(unsafe) var BfirstPopup: NSPopUpButton?, BsecondPopup: NSPopUpButton?
    unowned(unsafe) var BfirstColor: NSColorWell?, BsecondColor: NSColorWell?
    unowned(unsafe) var BpreprocessMatrix: NSMatrix?

    /// The `view` outlet; -view stays the method of Window3DController.
    var srView: SRView?

    @objc(setView:)
    private func setSRViewOutlet(_ view: SRView?) { srView = view }

    // MARK: The surfaces' settings, bound by the settings sheet

    @objc dynamic var firstSurface: Float = 0
    @objc dynamic var secondSurface: Float = 0
    @objc dynamic var resolution: Float = 0
    @objc dynamic var firstTransparency: Float = 0
    @objc dynamic var secondTransparency: Float = 0
    @objc dynamic var decimate: Float = 0
    @objc dynamic var smooth: Int32 = 0
    @objc dynamic var firstColor: NSColor?
    @objc dynamic var secondColor: NSColor?
    @objc dynamic var shouldDecimate = false
    @objc dynamic var shouldSmooth = false
    @objc dynamic var useFirstSurface = false
    @objc dynamic var useSecondSurface = false
    @objc dynamic var shouldRenderFusion = false

    /// Whether the sheet open edits the fused series' surfaces.
    var fusionSettingsWindow = false
    var settingsOfSDK: NSMutableDictionary? = NSMutableDictionary()
    var blendingSettingsOfSDK: NSMutableDictionary? = NSMutableDictionary()
    /// The two dictionaries of settings: one a plugin set to nil is made again.
    private var settings: NSMutableDictionary {
        if let settings = settingsOfSDK { return settings }
        let settings = NSMutableDictionary()
        settingsOfSDK = settings
        return settings
    }
    var blendingSettings: NSMutableDictionary {
        if let settings = blendingSettingsOfSDK { return settings }
        let settings = NSMutableDictionary()
        blendingSettingsOfSDK = settings
        return settings
    }
    // The surfaces of the fused series as that SDK's thirteen instance
    // variables: the settings of the fusion sheet are in the dictionary above,
    // and these are written from it wherever it changes, and not read.
    var fusionFirstSurfaceOfSDK: Float = 0, fusionSecondSurfaceOfSDK: Float = 0, fusionResolutionOfSDK: Float = 0
    var fusionFirstTransparencyOfSDK: Float = 0, fusionSecondTransparencyOfSDK: Float = 0, fusionDecimateOfSDK: Float = 0
    var fusionSmoothOfSDK: Int32 = 0
    var fusionFirstColorOfSDK: NSColor?, fusionSecondColorOfSDK: NSColor?
    var fusionShouldDecimateOfSDK = false, fusionShouldSmoothOfSDK = false
    var fusionUseFirstSurfaceOfSDK = false, fusionUseSecondSurfaceOfSDK = false
    // The same thirteen under the names older copies of that SDK's headers
    // gave them, with an underscore: a second copy of each, written with the
    // first.
    var _fusionFirstSurface: Float = 0, _fusionSecondSurface: Float = 0, _fusionResolution: Float = 0
    var _fusionFirstTransparency: Float = 0, _fusionSecondTransparency: Float = 0, _fusionDecimate: Float = 0
    var _fusionSmooth: Int32 = 0
    var _fusionFirstColor: NSColor?, _fusionSecondColor: NSColor?
    var _fusionShouldDecimate = false, _fusionShouldSmooth = false
    var _fusionUseFirstSurface = false, _fusionUseSecondSurface = false

    // MARK: The series

    // nonisolated(unsafe): -pixList, -fileList and -blendingController are
    // read on any thread, as the Objective-C instance variables were; they are
    // set once, by the initializer.
    nonisolated(unsafe) var pixListStorage: NSMutableArray?
    nonisolated(unsafe) var fileListStorage: NSArray?
    /// Not retained, as before: the fused viewer closes the window first.
    nonisolated(unsafe) private weak var blendingControllerStorage: ViewerController?
    /// The pointer to the fused viewer with no retain, as the former SDK kept
    /// it: written with the reference above and not read, since that one
    /// becomes nil when the viewer goes.
    unowned(unsafe) var blendingControllerOfSDK: ViewerController?
    var volumeData: NSData?
    var toolbar: NSToolbar?
    /// The 2D viewer the window was opened from.
    var viewer2DStorage: ViewerController?
    /// The adapter of the fly through window last opened, not retained, as
    /// that SDK kept it: written when the window opens and not read.
    unowned(unsafe) var FTAdapter: SRFlyThruAdapter?
    // That SDK declared these three and never wrote them: nothing stands
    // behind them, and they are never released.
    var blending = false
    unowned(unsafe) var blendingVolumeData: NSData?
    unowned(unsafe) var blendingPixList: NSMutableArray?

    // MARK: 3D points and ROI volumes

    // The 2D points the view shows, as that SDK kept them: five lists, of the
    // ROIs and of NSNumbers of the slice (a long) and of the patient
    // coordinates (floats). The window's code reads and writes them as the
    // Swift arrays below.
    var roi2DPointsOfSDK: NSMutableArray? = NSMutableArray()
    var sliceNumber2DPointsOfSDK: NSMutableArray? = NSMutableArray()
    var x2DPointsOfSDK: NSMutableArray? = NSMutableArray()
    var y2DPointsOfSDK: NSMutableArray? = NSMutableArray()
    var z2DPointsOfSDK: NSMutableArray? = NSMutableArray()

    /// Puts `values` in `list`, or in a new list when a plugin set it to nil.
    private static func filled(_ list: NSMutableArray?, _ values: [Any]) -> NSMutableArray {
        let list = list ?? NSMutableArray()
        list.setArray(values)
        return list
    }
    private static func floats(_ list: NSMutableArray?) -> [Float] {
        (list ?? []).map { ($0 as? NSNumber)?.floatValue ?? 0 }
    }
    var roi2DPointsArray: [ROI] {
        get { (roi2DPointsOfSDK ?? []).compactMap { $0 as? ROI } }
        set { roi2DPointsOfSDK = Self.filled(roi2DPointsOfSDK, newValue) }
    }
    var sliceNumber2DPointsArray: [Int] {
        get { (sliceNumber2DPointsOfSDK ?? []).map { ($0 as? NSNumber)?.intValue ?? 0 } }
        set { sliceNumber2DPointsOfSDK = Self.filled(sliceNumber2DPointsOfSDK, newValue.map { NSNumber(value: $0) }) }
    }
    var x2DPointsArray: [Float] {
        get { Self.floats(x2DPointsOfSDK) }
        set { x2DPointsOfSDK = Self.filled(x2DPointsOfSDK, newValue.map { NSNumber(value: $0) }) }
    }
    var y2DPointsArray: [Float] {
        get { Self.floats(y2DPointsOfSDK) }
        set { y2DPointsOfSDK = Self.filled(y2DPointsOfSDK, newValue.map { NSNumber(value: $0) }) }
    }
    var z2DPointsArray: [Float] {
        get { Self.floats(z2DPointsOfSDK) }
        set { z2DPointsOfSDK = Self.filled(z2DPointsOfSDK, newValue.map { NSNumber(value: $0) }) }
    }
    /// Read on any thread through -roiVolumes, as the instance variable was.
    nonisolated(unsafe) var roiVolumesOfSDK: NSMutableArray? = NSMutableArray()
    /// The list of the ROI volumes: one a plugin set to nil is made again.
    nonisolated var roiVolumesStorage: NSMutableArray {
        if let volumes = roiVolumesOfSDK { return volumes }
        let volumes = NSMutableArray()
        roiVolumesOfSDK = volumes
        return volumes
    }
    var flyThruRecordingTimeFrame: TimeInterval = 0

    /// [[SRController alloc] initWithPix:::::]: nil, after an alert, when the
    /// slices have neither an interval nor a thickness, or not all the same
    /// size, or the view refuses the volume.
    @objc(initWithPix:::::)
    convenience init?(pix: NSMutableArray?, _ f: NSArray?, _ vData: NSData?, _ bC: ViewerController?, _ vC: ViewerController?) {
        guard let firstObject = pix?.firstObject as? DCMPix else { return nil }
        if Float(abs(firstObject.sliceInterval)) == 0 {
            let sliceThickness = Float(firstObject.sliceThickness)
            if sliceThickness > 0 {
                HorosAlertPanel.runCritical(title: NSLocalizedString("Slice interval", comment: ""),
                                            message: NSLocalizedString("I'm not able to find the slice interval. Slice interval will be equal to slice thickness.", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            } else {
                HorosAlertPanel.runCritical(title: NSLocalizedString("Slice interval/thickness", comment: ""),
                                            message: NSLocalizedString("Problems with slice thickness/interval to do a 3D reconstruction.", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                return nil
            }
        }

        // CHECK IMAGE SIZE
        for case let p as DCMPix in pix ?? [] where p.pwidth != firstObject.pwidth || p.pheight != firstObject.pheight {
            HorosAlertPanel.runCritical(title: NSLocalizedString("Images size", comment: ""),
                                        message: NSLocalizedString("These images don't have the same height and width to allow a 3D reconstruction...", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return nil
        }

        self.init(windowNibName: "SR")
        fileListStorage = f
        pixListStorage = pix
        volumeData = vData

        window?.delegate = self

        let voxels = vData.map { UnsafeMutablePointer(mutating: $0.bytes.assumingMemoryBound(to: Float.self)) }
        if srView?.setPixSource(pix, voxels) != 0 {
            return nil
        }

        blendingControllerStorage = bC
        blendingControllerOfSDK = bC
        if let bC { // Blending! Activate image fusion
            srView?.setBlendingPixSource(bC)
        }

        viewer2DStorage = vC
        if let viewer2D = vC, let rois = viewer2D.roiList(), let pixes = viewer2D.pixList() {
            let count = viewer2D.imageView()?.dcmPixList?.count ?? 0
            for i in 0..<count {
                for case let roi as ROI in (rois.object(at: i) as? NSArray) ?? [] where roi.type == .t2DPoint {
                    guard let point = (roi.points as NSArray?)?.object(at: 0) as? MyPoint,
                          let slice = pixes.object(at: i) as? DCMPix else { continue }
                    let location = Self.patientLocation(of: point, on: slice)
                    // add the 3D Point to the SR view
                    srView?.add3DPoint(Double(location.x), Double(location.y), Double(location.z))
                    // add the 2D Point to our list
                    record2DPoint(roi, slice: i, location)
                }
            }
        }

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(remove3DPoint(_:)), name: .OsirixRemoveROI, object: nil)
        nc.addObserver(self, selector: #selector(add3DPoint(_:)), name: .OsirixROISelected, object: nil)
        nc.addObserver(self, selector: #selector(closeViewerNotification(_:)), name: .OsirixCloseViewer, object: nil)

        computeROIVolumes()
        displayROIVolumes()

        setupToolbar()
    }

    isolated deinit {
        NSLog("Dealloc SRController")
        NotificationCenter.default.removeObserver(self)
        toolbar?.delegate = nil
    }

    // MARK: What Window3DController asks

    override func viewer() -> ViewerController! { viewer2DStorage }

    override func view() -> Any! { srView }

    override nonisolated func blendingController() -> ViewerController! { blendingControllerStorage }

    override nonisolated func pixList() -> NSMutableArray! { pixListStorage }

    override nonisolated func fileList() -> [Any]! { fileListStorage as? [Any] }

    @objc func viewer2D() -> ViewerController? { viewer2DStorage }

    override dynamic func currentStudy() -> DicomStudy! { viewer2DStorage?.currentStudy() }

    override dynamic func currentSeries() -> DicomSeries! { viewer2DStorage?.currentSeries() }

    override dynamic func currentImage() -> DicomImage! { viewer2DStorage?.currentImage() }

    // MARK: Window

    override func windowDidLoad() {
        super.windowDidLoad()
        settings["resolution"] = NSNumber(value: 0.5)
        settings["shouldDecimate"] = NSNumber(value: true)
        settings["shouldSmooth"] = NSNumber(value: true)
        settings["firstSurface"] = NSNumber(value: 300)
        settings["secondSurface"] = NSNumber(value: -500)
        settings["firstTransparency"] = NSNumber(value: 1.0)
        settings["secondTransparency"] = NSNumber(value: 1.0)
        settings["decimate"] = NSNumber(value: 0.5)
        settings["smooth"] = NSNumber(value: 20)
        settings["firstColor"] = NSColor(calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        settings["secondColor"] = NSColor(calibratedRed: 1.0, green: 0.592, blue: 0.608, alpha: 1.0)
        settings["useFirstSurface"] = NSNumber(value: true)
        settings["useSecondSurface"] = NSNumber(value: false)

        blendingSettings.addEntries(from: settings as! [AnyHashable: Any])
        copyFusionSettings()

        shouldRenderFusion = false
        decimateFieldOfOlderSDK = Self.textField(in: SRSettingsWindow?.contentView, boundTo: "decimate")
        smoothFieldOfOlderSDK = Self.textField(in: SRSettingsWindow?.contentView, boundTo: "smooth")
    }

    /// The text field under `view` whose value is bound to `keyPath`.
    private static func textField(in view: NSView?, boundTo keyPath: String) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.infoForBinding(.value)?[.observedKeyPath] as? String == keyPath {
            return field
        }
        for subview in view.subviews {
            if let field = textField(in: subview, boundTo: keyPath) { return field }
        }
        return nil
    }

    @IBAction override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        srView?.squareView(self)
    }

    @objc(CloseViewerNotification:)
    func closeViewerNotification(_ note: Notification?) {
        if PreviousSeriesHold.window(self, keepsSeriesReleasedBy: note) { return }
        if let viewer2D = viewer2DStorage, (note?.object as AnyObject?) === viewer2D {
            offFullScreen()
            window?.close()
        }
    }

    override func windowWillClose(_ notification: Notification) {
        horos_windowWillClose = true
        window?.acceptsMouseMovedEvents = false
        // The Point Info panel leaves the screen with its window: left open,
        // it outlived this controller and its view.
        CompanionPanels.takeOffScreen(srView?.point3DInfoPanel)
        NotificationCenter.default.post(name: .OsirixWindow3dClose, object: self, userInfo: nil)
        window?.delegate = nil
        // [self autorelease]: the reference the code that made it kept.
        _ = Unmanaged.passUnretained(self).autorelease()
    }

    // MARK: Actions of SR.xib

    @IBAction func roiDeleteAll(_ sender: Any?) {
        viewer2DStorage?.roiDeleteAll(sender)
    }

    /// The tag that names what `sender` chose: that of the selected cell of a
    /// matrix, as the orientation and tools matrices of SR.xib send, or the
    /// item's own tag for a menu item, which has no cells.
    static func chosenTag(of sender: Any?) -> Int? {
        if let item = sender as? NSMenuItem { return item.tag }
        return (sender as? NSControl)?.selectedCell()?.tag
    }

    @IBAction func setOrientation(_ sender: Any?) {
        switch Self.chosenTag(of: sender) {
        case 0: srView?.axView(self)
        case 1: srView?.coView(self)
        case 2: srView?.saView(self)
        case 3: srView?.saViewOpposite(self)
        default: break
        }
    }

    /// The tool `sender` chose (see chosenTag(of:)).
    @IBAction func setDefaultTool(_ sender: Any?) {
        let tag = Self.chosenTag(of: sender)
        if let tag, tag >= 0, let tool = ToolMode(rawValue: Int16(truncatingIfNeeded: tag)) {
            srView?.setCurrentTool(tool)
        }
    }

    @IBAction func SettingsPopup(_ sender: Any?) {
        switch (sender as AnyObject?)?.tag ?? 0 {
        case 1: firstSurface = -500.0
        case 11: secondSurface = -500.0
        case 2: firstSurface = 500.0
        case 12: secondSurface = 500.0
        case 3: firstSurface = 2000.0
        case 13: secondSurface = 2000.0
        default: break
        }
    }

    @IBAction func ApplySettings(_ sender: Any?) {
        let tag = (sender as AnyObject?)?.tag ?? 0
        // Commit the field editor and its bindings before rendering or saving values.
        // If validation refuses the edit, keep the settings sheet open.
        if tag != 0 && SRSettingsWindow?.makeFirstResponder(nil) == false { return }
        if tag == 0 { SRSettingsWindow?.endEditing(for: nil) }

        SRSettingsWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))

        guard tag != 0 else { return }
        let d: NSMutableDictionary
        if fusionSettingsWindow {
            d = blendingSettings
            shouldRenderFusion = true
            renderFusionSurfaces()
        } else {
            d = settings
            renderSurfaces()
        }
        defer { if fusionSettingsWindow { copyFusionSettings() } }

        d["resolution"] = NSNumber(value: resolution)
        d["shouldDecimate"] = NSNumber(value: shouldDecimate)
        d["shouldSmooth"] = NSNumber(value: shouldSmooth)
        d["firstSurface"] = NSNumber(value: firstSurface)
        d["secondSurface"] = NSNumber(value: secondSurface)
        d["firstTransparency"] = NSNumber(value: firstTransparency)
        d["secondTransparency"] = NSNumber(value: secondTransparency)
        d["decimate"] = NSNumber(value: decimate)
        d["smooth"] = NSNumber(value: smooth)
        d["firstColor"] = firstColor
        d["secondColor"] = secondColor
        d["useFirstSurface"] = NSNumber(value: useFirstSurface)
        d["useSecondSurface"] = NSNumber(value: useSecondSurface)
    }

    /// The red, green and blue of a surface's colour in generic RGB. The
    /// colour well gives what the colour panel picked: grey, CMYK and named
    /// colours convert; a colour that does not (a pattern), or none, is black.
    /// The view's 3D points and their annotations read their colours through
    /// it too, since NSColor raises when asked for the components of a colour
    /// that is not RGB.
    static func surfaceRGB(_ color: NSColor?) -> (red: Float, green: Float, blue: Float) {
        guard let rgb = color?.usingColorSpace(.genericRGB) else { return (0, 0, 0) }
        return (Float(rgb.redComponent), Float(rgb.greenComponent), Float(rgb.blueComponent))
    }

    @objc func renderSurfaces() {
        guard let view = srView else { return }
        // The sheet's slider keeps the resolution between 0.1 and 1; VTK cannot resample by 0.
        let resolution = SurfaceResolution.clamped(resolution)
        // The wait window stays up for at least 0.1 s: open it when a surface is built, unless the
        // surfaces to build took less than that last time, when the window would only add its own wait.
        var expected: TimeInterval = 0
        var unknown = false
        for surface in 0..<2 {
            let used = surface == 0 ? useFirstSurface : useSecondSurface
            let iso = surface == 0 ? firstSurface : secondSurface
            if used && view.changeActorBuildsGeometry(surface, resolution, iso, shouldDecimate, decimate, shouldSmooth, Int(smooth)) {
                let last = view.surfaceBuildSeconds(surface)
                if last < 0 { unknown = true } else { expected += last }
            }
        }
        let www: WaitRendering? = unknown || expected >= 0.1 ? WaitRendering(NSLocalizedString("Preparing 3D Iso Surface...", comment: "")) : nil
        www?.start()

        let color = Self.surfaceRGB(firstColor)
        let sColor = Self.surfaceRGB(secondColor)

        // FIRST SURFACE
        if useFirstSurface {
            view.changeActor(0, resolution, firstTransparency, color.red, color.green, color.blue, firstSurface,
                             shouldDecimate, decimate, shouldSmooth, Int(smooth))
        } else {
            view.deleteActor(0)
        }

        // SECOND SURFACE
        if useSecondSurface {
            view.changeActor(1, resolution, secondTransparency, sColor.red, sColor.green, sColor.blue, secondSurface,
                             shouldDecimate, decimate, shouldSmooth, Int(smooth))
        } else {
            view.deleteActor(1)
        }

        www?.end()
        www?.close()
    }

    @objc func renderFusionSurfaces() {
        guard let view = srView else { return }
        // As in -renderSurfaces. The colour is converted to RGB first: asking a
        // grey, CMYK or named colour for its red raises an exception.
        let resolution = SurfaceResolution.clamped(resolution)
        let color = Self.surfaceRGB(firstColor)
        let sColor = Self.surfaceRGB(secondColor)
        if useFirstSurface {
            view.BchangeActor(0, resolution, firstTransparency, color.red, color.green, color.blue, firstSurface,
                              shouldDecimate, decimate, shouldSmooth, Int(smooth))
        } else {
            view.BdeleteActor(0)
        }

        // SECOND SURFACE
        if useSecondSurface {
            view.BchangeActor(1, resolution, secondTransparency, sColor.red, sColor.green, sColor.blue, secondSurface,
                              shouldDecimate, decimate, shouldSmooth, Int(smooth))
        } else {
            view.BdeleteActor(1)
        }
    }

    @objc(ChangeSettings:)
    func changeSettings(_ sender: Any?) {
        fusionSettingsWindow = false
        beginSettingsSheet(with: settings)
    }

    @objc(BChangeSettings:)
    func bChangeSettings(_ sender: Any?) {
        fusionSettingsWindow = true
        beginSettingsSheet(with: blendingSettings)
    }

    /// Fills the sheet's bindings from `values` and shows it.
    private func beginSettingsSheet(with values: NSDictionary) {
        func number(_ key: String) -> NSNumber? { values[key] as? NSNumber }
        resolution = number("resolution")?.floatValue ?? 0
        shouldDecimate = number("shouldDecimate")?.boolValue ?? false
        shouldSmooth = number("shouldSmooth")?.boolValue ?? false
        firstSurface = number("firstSurface")?.floatValue ?? 0
        secondSurface = number("secondSurface")?.floatValue ?? 0
        firstTransparency = number("firstTransparency")?.floatValue ?? 0
        secondTransparency = number("secondTransparency")?.floatValue ?? 0
        decimate = number("decimate")?.floatValue ?? 0
        // The float the dictionary holds, made an int as C did.
        smooth = Int32(number("smooth")?.floatValue ?? 0)
        firstColor = values["firstColor"] as? NSColor
        secondColor = values["secondColor"] as? NSColor
        useFirstSurface = number("useFirstSurface")?.boolValue ?? false
        useSecondSurface = number("useSecondSurface")?.boolValue ?? false

        if let sheet = SRSettingsWindow {
            window?.beginSheet(sheet, completionHandler: nil)
        }
    }

    // MARK: The 2D viewer's points

    /// The patient coordinates of a 2D point ROI's point on `slice`, as floats.
    static func patientLocation(of point: MyPoint, on slice: DCMPix) -> (x: Float, y: Float, z: Float) {
        var location = [Float](repeating: 0, count: 3)
        slice.convertX(point.x, pixY: point.y, toDICOMCoords: &location, pixelCenter: true)
        return (location[0], location[1], location[2])
    }

    /// Adds a 2D point ROI to the list of the points the view shows.
    func record2DPoint(_ roi: ROI, slice: Int, _ location: (x: Float, y: Float, z: Float)) {
        roi2DPointsArray.append(roi)
        sliceNumber2DPointsArray.append(slice)
        x2DPointsArray.append(location.x)
        y2DPointsArray.append(location.y)
        z2DPointsArray.append(location.z)
    }
}
