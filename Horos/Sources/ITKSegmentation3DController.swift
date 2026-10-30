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

/// Segmentation WindowController: the region growing window of a 2D viewer
/// (ITKSegmentation.xib). A click in the viewer is the seed; the window's
/// algorithm, parameters and options choose how the ROI grows, in the current
/// image or the whole volume, previewed or computed.
///
/// Implemented in Swift: the Objective-C name, the selectors and the keys the
/// nib connects and binds are those of the former class. The algorithms and
/// their parameter fields are in ITKSegmentation3DController+Algorithms.swift,
/// the preview and the computation in
/// ITKSegmentation3DController+RegionGrowing.swift, the rules in
/// IsiXSegmentation. The ITK filters are ITKSegmentation3D's, called through
/// its Objective-C interface.
///
/// The viewer creates the window and keeps no reference to it: the window
/// controller releases itself when its window closes. A viewer has one such
/// window at most: +segmentationControllerForViewer: finds it.
@objc(ITKSegmentation3DController)
public final class ITKSegmentation3DController: NSWindowController, NSWindowDelegate {
    /// Not retained, as the former ivars: the window closes with its viewer,
    /// and the results viewer is forgotten when it closes.
    unowned(unsafe) var viewerController: ViewerController?
    unowned(unsafe) var resultsViewer: ViewerController?

    /// The seed, in pixels of the current image; none at 0 on either axis.
    var seed = NSPoint.zero

    // parameters
    @IBOutlet var parametersBox: NSBox?
    @IBOutlet var growingMode: NSMatrix?
    @IBOutlet var algorithmPopup: NSPopUpButton?
    @IBOutlet var startingPointWorldPosition: NSTextField?
    @IBOutlet var startingPointPixelPosition: NSTextField?
    @IBOutlet var startingPointValue: NSTextField?
    @IBOutlet var params: HorosFormView?
    // results
    @IBOutlet var resultsBox: NSBox?
    @IBOutlet var outputResult: NSMatrix?
    @IBOutlet var pixelsSet: NSMatrix?
    @IBOutlet var pixelsValue: NSMatrix?
    @IBOutlet var roiResolution: NSSlider?
    @IBOutlet var computeButton: NSButton?
    /// The field of the grown ROI's name. The nib connects it as newName,
    /// through the setter: a getter of that name, in the new family, would
    /// hand its callers a retained field.
    var newNameField: NSTextField?

    @objc(setNewName:)
    func setNewName(_ field: NSTextField?) {
        newNameField = field
    }

    public override var windowNibName: NSNib.Name? {
        return "ITKSegmentation"
    }

    // MARK: - Life cycle

    /// The window of `v`, if it has one open.
    @objc(segmentationControllerForViewer:)
    public class func segmentationController(forViewer v: ViewerController!) -> ITKSegmentation3DController? {
        for window in NSApp.windows {
            guard let controller = window.windowController, controller.windowNibName == "ITKSegmentation" else { continue }
            if let controller = controller as? ITKSegmentation3DController, controller.viewerController === v {
                return controller
            }
        }

        return nil
    }

    /// A new window for `v`, the nib loaded when it is shown. Callers that
    /// want the window `v` already has ask +segmentationControllerForViewer:
    /// first.
    @objc(initWithViewer:)
    public init(viewer v: ViewerController!) {
        super.init(window: nil)

        viewerController = v
        resultsViewer = nil
        seed = .zero

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(mouseViewerDown(_:)), name: .OsirixMouseDown, object: nil)
        nc.addObserver(self, selector: #selector(closeViewerNotification(_:)), name: .OsirixCloseViewer, object: nil)
        nc.addObserver(self, selector: #selector(drawStartingPoint(_:)), name: .HorosDrawObjectsCanvas, object: nil)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        NSLog("ITKSegmentation3DController dealloc")
    }

    public override func windowDidLoad() {
        super.windowDidLoad()
        fillAlgorithmPopup()
        changeAlgorithm(self)
    }

    @objc public func windowWillClose(_ notification: Notification) {
        window?.acceptsMouseMovedEvents = false

        viewerController?.roiDelete(withName: Self.previewName)

        NSLog("windowWillClose")

        NotificationCenter.default.removeObserver(self)

        // The former [self autorelease]: balances the reference the viewer
        // kept of the new window, once the current autorelease pool drains.
        _ = Unmanaged.passUnretained(self).autorelease()
    }

    // MARK: - The viewer

    @objc(viewer)
    public func viewer() -> ViewerController! {
        return viewerController
    }

    /// Whether the viewer's images form a volume (bound by the nib: the 3D
    /// growing mode needs one).
    @objc public var dataVolumic: Bool {
        return viewerController?.isDataVolumicIn4D(false) ?? false
    }

    @objc(startingPoint)
    public func startingPoint() -> NSPoint {
        return seed
    }

    @objc(CloseViewerNotification:)
    func closeViewerNotification(_ note: Notification!) {
        if (note.object as AnyObject?) === resultsViewer { resultsViewer = nil }

        if (note.object as AnyObject?) === viewerController {
            window?.close()
        }
    }

    @objc(drawStartingPoint:)
    func drawStartingPoint(_ note: Notification!) {
        guard let imageView = viewerController?.imageView(), (note.object as AnyObject?) === imageView else { return }
        SegmentationSeedPoint.drawCross(at: seed, userInfo: note.userInfo, backingScaleFactor: window?.backingScaleFactor ?? 1)
    }

    /// A click in the viewer: the seed, shown in the window, then a preview;
    /// the viewer does nothing else with the click.
    @objc(mouseViewerDown:)
    func mouseViewerDown(_ note: NSNotification) {
        guard let viewer = viewerController, (note.object as AnyObject?) === viewer else { return }

        let xpx = SegmentationSeedPoint.intValue(note.userInfo?["X"])
        let ypx = SegmentationSeedPoint.intValue(note.userInfo?["Y"])

        let texts = SegmentationSeedPoint.texts(viewer: viewer, x: xpx, y: ypx)
        startingPointPixelPosition?.stringValue = texts.pixel
        startingPointWorldPosition?.stringValue = texts.world
        startingPointValue?.stringValue = texts.value
        seed = NSPoint(x: CGFloat(xpx), y: CGFloat(ypx))

        preview(viewer)

        (note.value(forKey: "userInfo") as? NSMutableDictionary)?.setValue(NSNumber(value: true), forKey: "stopMouseDown")
    }
}
