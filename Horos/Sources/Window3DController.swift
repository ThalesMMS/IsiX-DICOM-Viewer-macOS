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
import IsiXImaging

// The superclass of the 3D viewers' window controllers (VR, SR, MPR, CPR,
// endoscopy, orthogonal MPR, PET-CT, ROI volume) is implemented here, in
// Swift, under the interface Window3DController.h declares
// (@objc @implementation): Objective-C (VRController, SRController) still
// subclasses it, so the interface stays Objective-C's, without instance
// variables. The window level presets are in Window3DController+WindowLevel.swift,
// the colour and opacity tables in Window3DController+ColorTables.swift and the
// class's own full screen in Window3DController+FullScreen.swift.
//
// What every subclass answers itself (-viewer, -view, -pixList, -fileList and
// the others) has a default here, as the former .m had. The defaults that
// touch no window run on any thread (nonisolated), as the Objective-C methods
// did: the printing view and other threads ask a controller for its files and
// images. The methods the former .m defined without declaring them are
// private here, as they were to that file, or, for -fullWindowView: and
// -syncSeriesState, which subclasses implement under the same selector with
// other types, held by Window3DControllerDefaults and added at run time: a
// subclass's method answers first, as before.
@objc @implementation extension Window3DController {
    // The outlets the subclasses read, declared by the header.
    final var addWLWWWindowOutlet: NSWindow?
    final var newNameOutlet: NSTextField?
    final var wlOutlet: NSTextField?
    final var wwOutlet: NSTextField?
    final var clutNameOutlet: NSTextField?
    final var addOpacityWindowOutlet: NSWindow?
    final var opacityNameOutlet: NSTextField?
    final var opacityViewOutlet: OpacityTransferView?

    // The outlets only this class reads: the window level sheet, the colour
    // table editor and the three menus.
    final var setWLWWWindowOutlet: NSWindow?
    final var wlsetOutlet: NSTextField?
    final var wwsetOutlet: NSTextField?
    final var fromsetOutlet: NSTextField?
    final var tosetOutlet: NSTextField?
    final var addCLUTWindowOutlet: NSWindow?
    final var clutViewOutlet: ColorTransferView?
    final var wlwwPopupOutlet: NSPopUpButton?
    final var clutPopupOutlet: NSPopUpButton?
    final var opacityPopupOutlet: NSPopUpButton?

    // nonisolated(unsafe): read on any thread, as the Objective-C instance
    // variables were, through accessors no subclass overrides.
    nonisolated(unsafe) final var currentWLWWMenu: String?
    nonisolated(unsafe) final var currentCLUTMenu: String?
    nonisolated(unsafe) final var currentOpacityMenu: String?
    nonisolated(unsafe) final var willClose = false

    // The class's own full screen (Window3DController+FullScreen.swift).
    nonisolated(unsafe) final var fullScreenOn = false
    final var fullScreenWindow: NSWindow?
    final var startingWindow: NSWindow?
    final var savedContentView: NSView?

    // MARK: - Life cycle

    // Every 3D window - MPR, CPR, VR, SR, Endoscopy, Orthogonal MPR, PET-CT, ROI
    // volume - has its own full screen in fullScreenMenu:, which moves the content
    // view into a borderless window. A native full-screen Space is a different thing
    // under the same name, and the window cannot be in both. Declared here rather
    // than in windowDidLoad because a subclass may override that without calling
    // super; setWindow: is what NSWindowController calls when the nib's window
    // arrives, for every subclass.
    //
    // Nonisolated, as NSWindowController's own accessors are in Objective-C:
    // other threads ask a controller for its window. The accessors call
    // NSWindowController's implementations directly, which an isolated override
    // could not do without a main-thread check on every read.
    public nonisolated override var window: NSWindow? {
        get { Window3DWindowAccessors.window(of: self) }
        set {
            Window3DWindowAccessors.setWindow(newValue, of: self)
            MainActor.assumeIsolated {
                FullScreenWindowSupport.declineNativeFullScreen(newValue)
            }
        }
    }

    deinit {
        NSObject.cancelPreviousPerformRequests(withTarget: self)

        willClose = true

        NSLog("Window3DController dealloc")
    }

    // MARK: - Outlets

    var addWLWWWindow: NSWindow! {
        get { addWLWWWindowOutlet }
        set { addWLWWWindowOutlet = newValue }
    }

    var newName: NSTextField! {
        @objc(horos_newName) get { newNameOutlet }
        set { newNameOutlet = newValue }
    }

    var wl: NSTextField! {
        get { wlOutlet }
        set { wlOutlet = newValue }
    }

    var ww: NSTextField! {
        get { wwOutlet }
        set { wwOutlet = newValue }
    }

    var clutName: NSTextField! {
        get { clutNameOutlet }
        set { clutNameOutlet = newValue }
    }

    var addOpacityWindow: NSWindow! {
        get { addOpacityWindowOutlet }
        set { addOpacityWindowOutlet = newValue }
    }

    @objc(OpacityName) var opacityName: NSTextField! {
        get { opacityNameOutlet }
        set { opacityNameOutlet = newValue }
    }

    @objc(OpacityView) var opacityView: OpacityTransferView! {
        get { opacityViewOutlet }
        set { opacityViewOutlet = newValue }
    }

    // The nib connects these by their names (key-value coding).
    @objc(setSetWLWWWindow:) private func setSetWLWWWindow(_ window: NSWindow?) { setWLWWWindowOutlet = window }
    @objc(setWlset:) private func setWlset(_ field: NSTextField?) { wlsetOutlet = field }
    @objc(setWwset:) private func setWwset(_ field: NSTextField?) { wwsetOutlet = field }
    @objc(setFromset:) private func setFromset(_ field: NSTextField?) { fromsetOutlet = field }
    @objc(setToset:) private func setToset(_ field: NSTextField?) { tosetOutlet = field }
    @objc(setAddCLUTWindow:) private func setAddCLUTWindow(_ window: NSWindow?) { addCLUTWindowOutlet = window }
    @objc(setClutView:) private func setClutView(_ view: ColorTransferView?) { clutViewOutlet = view }
    @objc(setWlwwPopup:) private func setWlwwPopup(_ popup: NSPopUpButton?) { wlwwPopupOutlet = popup }
    @objc(setClutPopup:) private func setClutPopup(_ popup: NSPopUpButton?) { clutPopupOutlet = popup }
    @objc(setOpacityPopup:) private func setOpacityPopup(_ popup: NSPopUpButton?) { opacityPopupOutlet = popup }

    // MARK: - State the subclasses share

    nonisolated var horos_curWLWWMenu: String! {
        get { currentWLWWMenu }
        set { currentWLWWMenu = newValue }
    }

    nonisolated var horos_curCLUTMenu: String! {
        get { currentCLUTMenu }
        set { currentCLUTMenu = newValue }
    }

    nonisolated var horos_curOpacityMenu: String! {
        get { currentOpacityMenu }
        set { currentOpacityMenu = newValue }
    }

    nonisolated var horos_FullScreenOn: Bool {
        fullScreenOn
    }

    var horos_FullScreenWindow: NSWindow! {
        fullScreenWindow
    }

    nonisolated var horos_windowWillClose: Bool {
        get { willClose }
        set { willClose = newValue }
    }

    nonisolated func windowWillClose() -> Bool {
        return willClose
    }

    // MARK: - What subclasses answer

    func viewer() -> ViewerController! {
        return nil
    }

    func view() -> Any! {
        return nil
    }

    nonisolated func blendingController() -> ViewerController! {
        return nil
    }

    public nonisolated override func pixList() -> NSMutableArray! {
        return nil
    }

    nonisolated func fileList() -> [Any]! {
        return nil
    }

    nonisolated func is4D() -> Bool {
        return false
    }

    func movieFrames() -> Int {
        return 1
    }

    func setMovieFrame(_ l: Int) {
    }

    func load3DState() {
        // Override.
        NSLog("Error: inherited [Window3DController load3DState] should not be called")
    }

    @objc(hideROIVolume:)
    func hideROIVolume(_ v: Any!) {
        // Override
        NSLog("Error: inherited [Window3DController hideROIVolume] should not be called")
    }

    @objc(displayROIVolume:)
    func displayROIVolume(_ v: Any!) {
        // Override
        NSLog("Error: inherited [Window3DController displayROIVolume] should not be called")
    }

    nonisolated func roiVolumes() -> [Any]! {
        // Override
        NSLog("Error: inherited [Window3DController roiVolumes] should not be called")

        return nil
    }

    /// The defaults Window3DControllerDefaults holds, added to the class the
    /// first time a controller that does not implement one is sent it.
    public override class func resolveInstanceMethod(_ selector: Selector!) -> Bool {
        if let selector, Window3DControllerDefaults.selectors.contains(selector),
           let method = class_getInstanceMethod(Window3DControllerDefaults.self, selector) {
            class_addMethod(Window3DController.self, selector, method_getImplementation(method), method_getTypeEncoding(method))
            return true
        }
        return super.resolveInstanceMethod(selector)
    }

    // MARK: - The other viewers of the series

    @objc(mprViewer:)
    private func mprViewer(_ sender: Any?) {
        viewer()?.mprViewer(sender)
    }

    @objc(cprViewer:)
    private func cprViewer(_ sender: Any?) {
        viewer()?.cprViewer(sender)
    }

    @objc(endoscopyViewer:)
    private func endoscopyViewer(_ sender: Any?) {
        viewer()?.endoscopyViewer(sender)
    }

    @objc(VRViewer:)
    private func vrViewer(_ sender: Any?) {
        viewer()?.vrViewer(sender)
    }

    @objc(SRViewer:)
    private func srViewer(_ sender: Any?) {
        viewer()?.srViewer(sender)
    }

    @objc(orthogonalMPRViewer:)
    private func orthogonalMPRViewer(_ sender: Any?) {
        viewer()?.orthogonalMPRViewer(sender)
    }

    // MARK: - Printing and mail

    func print(_ sender: Any!) {
        let defaults = UserDefaults.standard
        let settings = NSMutableDictionary(dictionary: defaults.object(forKey: "previousPrintSettings") as? [AnyHashable: Any] ?? [:])

        settings["columns"] = NSNumber(value: Int32(1))
        settings["rows"] = NSNumber(value: Int32(1))

        let tmpFolder = (FileManager.default.tmpDirPath() as NSString).appendingPathComponent("print")

        let files = NSMutableArray()

        try? FileManager.default.removeItem(atPath: tmpFolder)
        try? FileManager.default.createDirectory(atPath: tmpFolder, withIntermediateDirectories: true, attributes: nil)

        var image: NSImage?
        if let view = view() as AnyObject?, view.responds(to: NSSelectorFromString("nsimageQuicktime")) {
            image = view.perform(NSSelectorFromString("nsimageQuicktime"))?.takeUnretainedValue() as? NSImage
        }

        let bitmapData = image?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
            .representation(using: .jpeg, properties: [.compressionFactor: NSDecimalNumber(value: Float(0.9))])

        files.add((tmpFolder as NSString).appendingFormat("/%d", Int32(1)))

        (bitmapData as NSData?)?.write(toFile: files.lastObject as! String, atomically: true)

        let pV = printView(viewer: self, settings: settings, files: files, printInfo: NSPrintInfo.shared)

        let printOperation = NSPrintOperation(view: pV)

        printOperation.canSpawnSeparateThread = true

        guard let window else { return }
        printOperation.runModal(for: window, delegate: self,
                                didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
    }

    /// Removes the pages written for printing. Nonisolated: the operation may
    /// run on a thread of its own.
    @objc(printOperationDidRun:success:contextInfo:)
    private nonisolated func printOperationDidRun(_ printOperation: NSPrintOperation, success: Bool, contextInfo info: UnsafeMutableRawPointer?) {
        let tmpFolder = (FileManager.default.tmpDirPath() as NSString).appendingPathComponent("print")

        try? FileManager.default.removeItem(atPath: tmpFolder)
    }

    func sendMailImage(_ im: NSImage!) {
        let representations = im.representations

        let bitmapData = NSBitmapImageRep.representationOfImageReps(in: representations, using: .jpeg,
                                                                    properties: [.compressionFactor: NSDecimalNumber(value: Float(0.9))])

        let path = ((BrowserController.currentBrowser()?.database?.tempDirPath() ?? "") as NSString).appendingPathComponent("IsiX DICOM Viewer.jpg")
        (bitmapData as NSData?)?.write(toFile: path, atomically: true)

        let email = Mailer()

        _ = email.sendMail("--", to: "--", subject: "", isMIME: true, name: "--", sendNow: false,
                           image: ((BrowserController.currentBrowser()?.database?.tempDirPath() ?? "") as NSString).appendingPathComponent("IsiX DICOM Viewer.jpg"))
    }
}

// -validateMenuItem:, declared by Window3DController+SwiftIvars.h (category
// SwiftUndeclared) rather than by the class's header, as before.
@objc(SwiftUndeclared) @implementation extension Window3DController {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return true }

        switch action {
        case #selector(Window3DController.applyCLUT(_:)):
            item.state = ThreeDPresetMenus.checksItem(title: item.title, current: currentCLUTMenu) ? .on : .off
            return true
        case #selector(Window3DController.applyOpacity(_:)):
            item.state = ThreeDPresetMenus.checksItem(title: item.title, current: currentOpacityMenu) ? .on : .off
            return true
        case NSSelectorFromString("ApplyWLWW:"):
            item.state = ViewerPresetMenus.checksWLWWItem(title: item.title, current: currentWLWWMenu) ? .on : .off
            return true
        case NSSelectorFromString("showCLUTOpacityPanel:"), NSSelectorFromString("loadAdvancedCLUTOpacity:"):
            // The first image of the series, as [[self pixList] objectAtIndex:0]
            // read it: nothing without a list, the range exception of an empty one.
            let first = (pixList() as NSArray?)?.object(at: 0) as? DCMPix
            return first?.isRGB != true
        case NSSelectorFromString("noAction:"):
            return false
        default:
            return true
        }
    }
}

/// NSWindowController's -window and -setWindow:, called as `super` would call
/// them, without Swift's isolation: Window3DController's override is
/// nonisolated.
private enum Window3DWindowAccessors {
    private typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<NSWindow>?
    private typealias Setter = @convention(c) (AnyObject, Selector, NSWindow?) -> Void

    private static let getter = #selector(getter: NSWindowController.window)
    private static let setter = #selector(setter: NSWindowController.window)

    static func window(of controller: AnyObject) -> NSWindow? {
        let implementation = class_getMethodImplementation(NSWindowController.self, getter)
        return unsafeBitCast(implementation, to: Getter.self)(controller, getter)?.takeUnretainedValue()
    }

    static func setWindow(_ window: NSWindow?, of controller: AnyObject) {
        let implementation = class_getMethodImplementation(NSWindowController.self, setter)
        unsafeBitCast(implementation, to: Setter.self)(controller, setter, window)
    }
}

/// The defaults the former .m gave two messages without the header declaring
/// them: -fullWindowView: (the orthogonal MPR viewers implement it with an
/// index) and -syncSeriesState (the PET-CT viewer has it as a property of its
/// own type), which Swift refuses beside a declaration of the superclass with
/// the same selector. Window3DController adds each default to itself at run
/// time (+resolveInstanceMethod:), when a controller that does not implement
/// it is first sent it: a subclass's method answers first, as before.
private final class Window3DControllerDefaults: NSObject {
    static let selectors: Set<Selector> = [#selector(fullWindowView(_:)), #selector(syncSeriesState)]

    @objc(fullWindowView:) func fullWindowView(_ sender: Any?) {
    }

    @objc(syncSeriesState) func syncSeriesState() -> Int32 {
        return 0
    }
}

extension Window3DController {
    /// The minute of the hour plus the second of the minute, now, on the
    /// Gregorian calendar in the default time zone: what the series numbers of
    /// a 3D export add to their base, so that two exports seldom share one.
    static func horos_calendarMinuteOfHourPlusSecondOfMinute() -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = NSTimeZone.default
        let now = Date()
        return calendar.component(.minute, from: now) + calendar.component(.second, from: now)
    }
}
