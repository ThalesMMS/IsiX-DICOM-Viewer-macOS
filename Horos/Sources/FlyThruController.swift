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

/// Window Controller for FlyThru.
///
/// Implemented in Swift since #715: the Objective-C name, the selectors and
/// <Horos/FlyThruController.h> are those of the former class, the File's
/// Owner of FlyThru.xib, whose controls bind to flyThru, curMovieIndex, the
/// hide… flags, exportFormat, levelOfDetailType, dcmSeriesName and tabIndex.
/// What the export reads from the 3D view goes through FlyThruHostBridge,
/// because VRView.h is C++.
@objc(FlyThruController)
public final class FlyThruController: NSWindowController, NSWindowDelegate {
    @IBOutlet private var LOD: NSMatrix?
    @IBOutlet private var boxPlay: NSBox?
    @IBOutlet private var boxExport: NSBox?
    @IBOutlet private var boxCompute: NSBox?

    @IBOutlet private var tabView: NSTabView?
    @IBOutlet private var FTview: NSTableView?
    @IBOutlet private var colCamNumber: NSTableColumn?
    @IBOutlet private var colCamPreview: NSTableColumn?

    @IBOutlet private var methodChooser: NSMatrix?
    @IBOutlet private var computeButton: NSButton?

    @IBOutlet private var framesSlider: NSSlider?
    @IBOutlet private var playButton: NSButton?

    @IBOutlet private var MatrixSize: NSTextField?
    @IBOutlet private var numberOfFramesTextField: NSTextField?
    @IBOutlet private var MatrixSizePopup: NSPopUpButton?

    private var boxPlayOrigin = NSPoint.zero
    private var windowFrame = NSRect.zero

    @IBOutlet private var exportButton: NSButton?
    /// The stepsArrayController outlet, which the readonly property reads.
    private var stepsArrayControllerOutlet: FlyThruStepsArrayController?

    /// The 3D window controller, retained.
    private var controller3D: Window3DController?

    private var movieTimer: Timer?
    private var lastMovieTime: TimeInterval = 0

    /// The exportButtonOption outlet, which -exportButtonOption returns.
    private var exportButtonOptionOutlet: NSButton?

    @objc public dynamic var flyThru: FlyThru?
    @objc public dynamic var hidePlayBox: Bool = false
    @objc public dynamic var hideComputeBox: Bool = false
    @objc public dynamic var hideExportBox: Bool = false
    @objc public dynamic var exportFormat: Int32 = 0
    /// Copied, as a String.
    @objc public dynamic var dcmSeriesName: String?
    @objc public dynamic var levelOfDetailType: Int32 = 0
    @objc public dynamic var exportSize: Int32 = 0
    /// link between abstract fly thru and concret 3D world (such as VR, SR, ...)
    @objc(FTAdapter) public dynamic var ftAdapter: FlyThruAdapter?
    @objc public dynamic var tabIndex: Int32 = 0

    /// -setCurMovieIndex: moves the view to that frame of the path before the
    /// index changes, as the former setter did.
    @objc public dynamic var curMovieIndex: Int32 = 0 {
        willSet {
            if (flyThru?.pathCameras?.count ?? 0) > 0 {
                ftAdapter?.setCurrentViewToCamera(flyThru?.pathCameras?.object(at: Int(newValue) - 1) as? Camera)
            }
        }
    }

    @objc public var currentCamera: Camera? {
        return ftAdapter?.getCurrentCamera()
    }

    @objc public var stepsArrayController: FlyThruStepsArrayController? {
        return stepsArrayControllerOutlet
    }

    /// Where the xib sets the stepsArrayController outlet.
    @objc(setStepsArrayController:)
    private func setStepsArrayControllerOutlet(_ controller: FlyThruStepsArrayController?) {
        stepsArrayControllerOutlet = controller
    }

    /// Where the xib sets the exportButtonOption outlet.
    @objc(setExportButtonOption:)
    private func setExportButtonOptionOutlet(_ button: NSButton?) {
        exportButtonOptionOutlet = button
    }

    @objc(setWindow3DController:)
    public func setWindow3DController(_ w3Dc: Window3DController?) {
        if controller3D === w3Dc { return }

        controller3D = w3Dc

        if let endoscopy: AnyClass = NSClassFromString("EndoscopyVRController"), controller3D?.isKind(of: endoscopy) == true {
            MatrixSize?.isHidden = true
            MatrixSizePopup?.isHidden = true
        }
    }

    @objc public func window3DController() -> Window3DController? {
        return controller3D
    }

    /// -initWithWindowNibName:@"FlyThru", through the Objective-C initializer.
    @objc(initWithFlyThruAdapter:)
    public convenience init(flyThruAdapter aFlyThruAdapter: FlyThruAdapter?) {
        self.init(windowNibName: "FlyThru")
        self.setupController()
        self.setFTAdapterAfterSetup(aFlyThruAdapter)
    }

    /// self.FTAdapter = … of the initializer, through the setter.
    private func setFTAdapterAfterSetup(_ aFlyThruAdapter: FlyThruAdapter?) {
        self.ftAdapter = aFlyThruAdapter
    }

    @objc public func setupController() {
        controller3D = nil

        self.window?.delegate = self   // In order to receive the windowWillClose notification!
        // [[self window] setBackgroundColor:[NSColor blackColor]];
        self.window?.alphaValue = 0.75
        self.loadWindow()

        self.flyThru = FlyThru()
        self.hidePlayBox = true
        self.hideComputeBox = false
        self.hideExportBox = true
        self.exportFormat = 0
        self.levelOfDetailType = 1
        self.dcmSeriesName = NSLocalizedString("FlyThru", comment: "")
        self.exportSize = 0

        boxPlayOrigin = boxPlay?.frame.origin ?? .zero
        windowFrame = self.window?.frame ?? .zero

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(Window3DClose(_:)),
                                               name: .OsirixWindow3dClose,
                                               object: nil)
    }

    @objc(Window3DClose:)
    public func Window3DClose(_ notification: Notification?) {
        if (notification?.object as AnyObject?) === controller3D { // The 3D window will be released.... Kill ourself
            self.window?.close()
        }
    }

    public func windowWillClose(_ notification: Notification) {
        self.window?.acceptsMouseMovedEvents = false

        if movieTimer != nil {
            movieTimer?.invalidate()
            movieTimer = nil
        }

        self.window?.delegate = nil

        // Balances the alloc of the caller, which never releases the window controller.
        _ = Unmanaged.passUnretained(self).autorelease()
    }

    public func windowDidBecomeKey(_ aNotification: Notification) {
        self.window?.alphaValue = 1.0
    }

    public func windowDidResignKey(_ aNotification: Notification) {
        self.window?.alphaValue = 0.5
    }

    deinit {
        NSLog("FlyThruController released")

        NotificationCenter.default.removeObserver(self)
    }

    public override func keyDown(with theEvent: NSEvent) {
        guard let characters = theEvent.characters as NSString?, characters.length > 0 else { return }

        let c = Int(characters.character(at: 0))
        if c == NSDeleteFunctionKey || c == NSDeleteCharacter || c == NSBackspaceCharacter || c == NSDeleteCharFunctionKey {
            stepsArrayControllerOutlet?.keyDown(theEvent)
        } else {
            super.keyDown(with: theEvent)
        }
    }

    @objc public func setCurrentView() {
        if (flyThru?.steps?.count ?? 0) > 0 {
            // [FTview selectedRow] as an int: 0 without the table, as a message to nil.
            let index = Int(Int32(truncatingIfNeeded: FTview?.selectedRow ?? 0))
            ftAdapter?.setCurrentViewToCamera(flyThru?.steps?.object(at: index) as? Camera)
            framesSlider?.intValue = ((flyThru?.stepsPositionInPath?.object(at: index) as? NSNumber)?.int32Value) ?? 0
        }
    }

    @IBAction public func flyThruSetCurrentView(_ sender: Any?) {
        self.setCurrentView()
    }

    @IBAction public func flyThruCompute(_ sender: Any?) {
        let loop = flyThru?.loop ?? false
        let minSteps = loop ? 2 : 3 // for the spline, 3 points are needed. (in the case of a loop, the 3rd point is added in the 'computePath' method of the FlyThru)
        var userChoice = 1
        let stepsCount = flyThru?.steps?.count ?? 0

        if stepsCount < 2 {
            HorosAlertPanel.run(title: NSLocalizedString("Error", comment: ""), message: NSLocalizedString("Add at least 2 frames for a Fly Thru.", comment: ""), defaultButton: nil, alternateButton: nil, otherButton: nil)
            return
        }

        if (flyThru?.interpolationMethod ?? 0) == 1 && stepsCount < minSteps {
            userChoice = HorosAlertPanel.run(title: NSLocalizedString("Spline Interpolation Error", comment: ""), message: NSLocalizedString("The Spline Interpolation needs at least 3 points to be run.", comment: ""), defaultButton: NSLocalizedString("Use Linear Interpollation", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil)
            if userChoice == 1 {
                flyThru?.interpolationMethod = 2 // changing the method
                // selection of the right radio button
                //[[methodChooser cellWithTag:1] setState: NSOffState];
                //[[methodChooser cellWithTag:2] setState: NSOnState];
            }
        }

        if userChoice == 1 {
            var v = numberOfFramesTextField?.intValue ?? 0

            if v < 2 { v = 2 }
            if v > 5000 { v = 5000 }

            numberOfFramesTextField?.intValue = v
            numberOfFramesTextField?.selectText(self)

            flyThru?.numberOfFrames = v
            flyThru?.computePath()

            // 4D
            if controller3D?.is4D() ?? false {
                let pathCameras = flyThru?.pathCameras ?? NSMutableArray()
                var previousIndex = (pathCameras.object(at: 0) as? Camera)?.movieIndexIn4D ?? 0
                var sameIndexes = true
                var i = 1
                while i < pathCameras.count && sameIndexes {
                    sameIndexes = sameIndexes && (previousIndex == ((pathCameras.object(at: i) as? Camera)?.movieIndexIn4D ?? 0))
                    previousIndex = (pathCameras.object(at: i) as? Camera)?.movieIndexIn4D ?? 0
                    i += 1
                }
                if sameIndexes {
                    NSLog("sameIndexes")
                    let movieFrames = controller3D?.movieFrames() ?? 0
                    var j: Int32 = 0
                    for i in 0 ..< pathCameras.count {
                        (pathCameras.object(at: i) as? Camera)?.movieIndexIn4D = Int(j)
                        // (j+1) % movieFrames; a zero divisor leaves j+1, as arm64 gave.
                        let next = Int(j) + 1
                        j = Int32(truncatingIfNeeded: movieFrames == 0 ? next : next % movieFrames)
                        NSLog("j : %d", j)
                    }
                }
            }

            self.hidePlayBox = false
            self.hideExportBox = false

            //	[nbFramesTextField setStringValue: [NSString stringWithFormat:@"%d",[flyThru numberOfFrames]]];

            framesSlider?.maxValue = Double((flyThru?.numberOfFrames ?? 0) &- 1)

            let isVRController = NSClassFromString("VRController").map { controller3D?.isKind(of: $0) ?? false } ?? false
            if isVRController == false { // Only the VR supports LOD versus Best rendering mode
                self.levelOfDetailType = 0
                LOD?.cell(withTag: 1)?.isEnabled = false
            } else {
                LOD?.cell(withTag: 1)?.isEnabled = true
            }
        }
    }

    @IBAction public func flyThruSetCurrentViewToSliderPosition(_ sender: Any?) {
        if let pathCameras = flyThru?.pathCameras, pathCameras.count > 0 {
            var index = Int(framesSlider?.intValue ?? 0)
            // An int against an NSUInteger: a negative index is past the end too.
            if index < 0 || index > pathCameras.count { index = Int(Int32(truncatingIfNeeded: pathCameras.count - 1)) }
            ftAdapter?.setCurrentViewToCamera(pathCameras.object(at: index) as? Camera)
        }
    }

    @objc(flyThruPlayStop:)
    public func flyThruPlayStop(_ sender: Any?) {
        //self.curMovieIndex = [framesSlider intValue];

        if movieTimer != nil {
            movieTimer?.invalidate()
            movieTimer = nil

            playButton?.title = "Play"

            ftAdapter?.setCurrentViewToCamera(flyThru?.pathCameras?.object(at: Int(curMovieIndex)) as? Camera)

            self.hideComputeBox = false
            self.hideExportBox = false
        } else {
            let timer = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(performMovieAnimation(_:)), userInfo: nil, repeats: true)
            movieTimer = timer
            RunLoop.current.add(timer, forMode: .modalPanel)
            RunLoop.current.add(timer, forMode: .eventTracking)

            lastMovieTime = Date.timeIntervalSinceReferenceDate

            playButton?.title = NSLocalizedString("Stop", comment: "")

            self.hideComputeBox = true
            self.hideExportBox = true
        }
    }

    /// movieIndex, a short, brought under the 3D window's movie frames as the
    /// former loop did: while (movieIndex >= movieFrames) movieIndex -= movieFrames.
    private func setMovieFrame(forShortIndex start: Int16) {
        var movieIndex = start

        while Int(movieIndex) >= (self.window3DController()?.movieFrames() ?? 0) {
            movieIndex = Int16(truncatingIfNeeded: Int(movieIndex) - (self.window3DController()?.movieFrames() ?? 0))
        }
        if movieIndex < 0 { movieIndex = 0 }

        self.window3DController()?.setMovieFrame(Int(movieIndex))
    }

    @objc(performMovieAnimation:)
    public func performMovieAnimation(_ sender: Any?) {
        let thisTime = Date.timeIntervalSinceReferenceDate
        var val: Int16

        val = Int16(truncatingIfNeeded: curMovieIndex)
        val = Int16(truncatingIfNeeded: Int32(val) + 1)

        if val < 0 { val = 1 }
        if Int32(val) > (flyThru?.numberOfFrames ?? 0) { val = 1 }

        self.curMovieIndex = Int32(val)

        if (self.window3DController()?.movieFrames() ?? 0) > 1 {
            self.setMovieFrame(forShortIndex: Int16(truncatingIfNeeded: curMovieIndex - 1))
        }

        //[framesSlider setIntValue:curMovieIndex];
        ftAdapter?.setCurrentViewToLowResolutionCamera(flyThru?.pathCameras?.object(at: Int(curMovieIndex) - 1) as? Camera)

        lastMovieTime = thisTime
    }

    @IBAction public func flyThruQuicktimeExport(_ sender: Any?) {
        numberOfFramesTextField?.selectText(self)

        ftAdapter?.prepareMovieGenerating()

        let movieFrames = { self.window3DController()?.movieFrames() ?? 0 }

        if exportFormat == 0 {
            var numberOfFrames = Int(flyThru?.numberOfFrames ?? 0)

            if movieFrames() > 1 {
                numberOfFrames /= movieFrames()
                numberOfFrames *= movieFrames()
            }

            let mov = QuicktimeExport(selector: self, #selector(imageForFrame(_:maxFrame:)), numberOfFrames)
            let firstFile = (self.window3DController()?.fileList() as NSArray?)?.object(at: 0) as AnyObject?
            _ = mov?.createMovieQTKit(true, false, firstFile?.value(forKeyPath: "series.study.name") as? String)
        } else {
            let dcmSequence = DICOMExport()
            var numberOfFrames = Int(flyThru?.numberOfFrames ?? 0)

            let producedFiles = NSMutableArray()

            if movieFrames() > 1 {
                numberOfFrames /= movieFrames()
                numberOfFrames *= movieFrames()
            }

            let progress = Wait(string: NSLocalizedString("Creating series", comment: ""))
            progress?.showWindow(self)
            progress?.progress()?.maxValue = Double(numberOfFrames)

            let now = Date()
            let calendar = Calendar.current
            dcmSequence.setSeriesNumber(8500 + calendar.component(.minute, from: now) + calendar.component(.second, from: Date()))
            dcmSequence.setSeriesDescription(dcmSeriesName)
            dcmSequence.setSourceFile(((controller3D?.pixList() as NSArray?)?.object(at: 0) as? DCMPix)?.srcFile)

            for i in 0 ..< max(numberOfFrames, 0) {
                autoreleasepool {
                    if movieFrames() > 1 {
                        self.setMovieFrame(forShortIndex: Int16(truncatingIfNeeded: i))
                    }

                    ftAdapter?.setCurrentViewToCamera(flyThru?.pathCameras?.object(at: i) as? Camera)
                    _ = ftAdapter?.getCurrentCameraImage(levelOfDetailType != 0)

                    var width = 0, height = 0, spp = 0, bpp = 0

                    let view = controller3D?.view()
                    let dataPtr = FlyThruHostBridge.rawPixels(ofView: view, width: &width, height: &height, spp: &spp, bpp: &bpp)
                    var o = [Float](repeating: 0, count: 9)

                    if let dataPtr = dataPtr {
                        dcmSequence.setPixelData(dataPtr, samplesPerPixel: Int32(truncatingIfNeeded: spp), bitsPerSample: Int32(truncatingIfNeeded: bpp), width: width, height: height)

                        FlyThruHostBridge.getOrientation(&o, ofView: controller3D?.view())

                        if UserDefaults.standard.bool(forKey: "exportOrientationIn3DExport") {
                            dcmSequence.setOrientation(&o)
                        }

                        let isVRController = NSClassFromString("VRController").map { controller3D?.isKind(of: $0) ?? false } ?? false
                        if isVRController { //||  [controller3D isKindOfClass: [VRPROController class]])
                            let resolution = Float(FlyThruHostBridge.resolution(ofView: controller3D?.view()))

                            if resolution != 0 {
                                dcmSequence.setPixelSpacing(resolution, resolution)
                            }
                        }

                        if let f = dcmSequence.writeDCMFile(nil) {
                            producedFiles.add(NSDictionary(object: f, forKey: "file" as NSString))
                        }

                        free(dataPtr)

                        progress?.increment(by: 1)
                    }
                }
            }

            progress?.close()

            if producedFiles.count > 0 {
                let database = BrowserController.currentBrowser()?.database
                var objects = database?.addFiles(atPaths: producedFiles.value(forKey: "file") as? [Any],
                                                 postNotifications: true,
                                                 dicomOnly: true,
                                                 rereadExistingItems: true,
                                                 generatedByOsiriX: true)

                objects = BrowserController.currentBrowser()?.database?.objects(withIDs: objects)

                if UserDefaults.standard.bool(forKey: "afterExportSendToDICOMNode") {
                    BrowserController.currentBrowser()?.selectServer(objects)
                }

                if UserDefaults.standard.bool(forKey: "afterExportMarkThemAsKeyImages") {
                    for case let im as NSManagedObject in (objects as NSArray?) ?? NSArray() {
                        im.setValue(NSNumber(value: true), forKey: "isKeyImage")
                    }
                }
            }
        }

        ftAdapter?.endMovieGenerating()
    }

    @objc(imageForFrame:maxFrame:)
    public func imageForFrame(_ cur: NSNumber?, maxFrame max: NSNumber?) -> NSImage? {
        let current = cur?.int32Value ?? 0
        if current != -1 {
            if (self.window3DController()?.movieFrames() ?? 0) > 1 {
                self.setMovieFrame(forShortIndex: Int16(truncatingIfNeeded: current))
            }

            ftAdapter?.setCurrentViewToCamera(flyThru?.pathCameras?.object(at: Int(current)) as? Camera)
            return ftAdapter?.getCurrentCameraImage(levelOfDetailType != 0)
        } else {
            ftAdapter?.setCurrentViewToCamera(flyThru?.pathCameras?.object(at: 0) as? Camera)
            return ftAdapter?.getCurrentCameraImage(levelOfDetailType != 0)
        }
    }

    @objc public func updateThumbnails() {
        let stepsCameras = flyThru?.steps
        let enumerator = stepsCameras?.objectEnumerator()
        while let cam = enumerator?.nextObject() {
            ftAdapter?.setCurrentViewToCamera(cam as? Camera)
            let im = ftAdapter?.getCurrentCameraImage(false)
            (cam as? Camera)?.previewImage = im
        }
    }

    @objc public func exportButtonOption() -> NSButton? {
        return exportButtonOptionOutlet
    }
}
