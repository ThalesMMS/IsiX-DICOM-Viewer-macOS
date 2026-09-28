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

/// Window Controller for the ThreeDPosition. The ThreeDPosition provides a GUI
/// to move a 3D DataSet in space (3D coordinates).
///
/// Implemented in Swift since #715: the Objective-C name, the selectors and
/// <Horos/ThreeDPositionController.h> are those of the former class, the
/// File's Owner of 3DPosition.xib.
@objc(ThreeDPositionController)
public final class ThreeDPositionController: NSWindowController {
    /// The former static `nav`, set by -initWithViewer: and cleared when a
    /// controller goes away. It never retained the controller: weak.
    private static weak var nav: ThreeDPositionController?

    @objc public private(set) var viewerController: ViewerController?

    @IBOutlet private var axialPan: ThreeDPanView?
    @IBOutlet private var verticalPan: ThreeDPanView?
    @IBOutlet private var matrixMode: NSMatrix?

    @objc(threeDPositionController)
    public class func threeDPositionController() -> ThreeDPositionController? {
        return nav
    }

    /// -initWithWindowNibName:@"3DPosition", through the Objective-C
    /// initializer the window controllers override.
    @objc(initWithViewer:)
    public convenience init(viewer: ViewerController?) {
        self.init(windowNibName: "3DPosition")

        ThreeDPositionController.nav = self

        _ = self.window // generate the awake from nib ! and populates the nib variables like navigatorView

        self.setViewer(viewer)
        axialPan?.setController(self)
        verticalPan?.setController(self)

        NotificationCenter.default.addObserver(self, selector: #selector(closeViewerNotification(_:)), name: .OsirixCloseViewer, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(setWindowLevel(_:)), name: NSApplication.willBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(setWindowLevel(_:)), name: NSApplication.willResignActiveNotification, object: nil)
    }

    @objc(movePositionPosition:)
    public func movePositionPosition(_ move: UnsafeMutablePointer<Float>?) {
        let viewerController = self.viewerController
        let maxMovieIndex = Int(viewerController?.maxMovieIndex() ?? 0)

        for i in 0 ..< max(maxMovieIndex, 0) {
            for case let p as DCMPix in (viewerController?.pixList(i) as NSArray?) ?? NSArray() {
                var o: [Float] = [0, 0, 0]

                if let move = move {
                    o[0] = Float(p.originX + Double(move[0]) * p.pixelSpacingX)
                    o[1] = Float(p.originY + Double(move[1]) * p.pixelSpacingY)
                    o[2] = Float(p.originZ - Double(move[2]) * p.sliceInterval)
                } else {
                    o[0] = Float(p.originX)
                    o[1] = Float(p.originY)
                    o[2] = Float(p.originZ)
                }

                o.withUnsafeMutableBufferPointer { p.setOrigin($0.baseAddress) }

                p.sliceInterval = 0

                p.computeSliceLocation()
            }
        }

        viewerController?.computeInterval()
        viewerController?.propagateSettings()

        for case let v as ViewerController in (ViewerController.getDisplayed2DViewers() as NSArray?) ?? NSArray() {
            v.imageView()?.sendSyncMessage(0)
            v.refresh()
        }
        // OSIRIX_LIGHT is not defined for Horos.
        if let orthogonalMPRPETCTViewer: AnyClass = NSClassFromString("OrthogonalMPRPETCTViewer") {
            for w in NSApplication.shared.windows {
                if let windowController = w.windowController, windowController.isKind(of: orthogonalMPRPETCTViewer) {
                    _ = windowController.perform(NSSelectorFromString("realignDataSet:"), with: self)
                }
            }
        }
    }

    @IBAction public func reset(_ sender: Any?) {
        viewerController?.executeRevert()

        self.movePositionPosition(nil)
    }

    @IBAction public func changeMatrixMode(_ sender: Any?) {
        switch matrixMode?.selectedTag() ?? 0 {
        case 0:
            axialPan?.image = NSImage(named: "AxialSmall.tif")
            verticalPan?.image = NSImage(named: "CorSmall.tif")
        case 1:
            axialPan?.image = NSImage(named: "CorSmall.tif")
            verticalPan?.image = NSImage(named: "AxialSmall.tif")
        case 2:
            axialPan?.image = NSImage(named: "SagSmall.tif")
            verticalPan?.image = NSImage(named: "AxialSmall.tif")
        default:
            break
        }
    }

    @objc public func mode() -> Int32 {
        return Int32(truncatingIfNeeded: matrixMode?.selectedTag() ?? 0)
    }

    @IBAction public func changePosition(_ sender: Any?) {
        var move: [Float] = [0, 0, 0]
        // [sender tag]: 0 for a sender without one, as a message to nil.
        let tag = ((sender as AnyObject?)?.tag as Int?) ?? 0

        switch matrixMode?.selectedTag() ?? 0 {
        case 0:
            switch tag {
            case 0: move[0] -= 1 / 2.0
            case 1: move[0] += 1 / 2.0
            case 2: move[1] += 1 / 2.0
            case 3: move[1] -= 1 / 2.0
            case 4: move[2] += 1 / 2.0
            case 5: move[2] -= 1 / 2.0
            case 6: move[0] -= 1 / 2.0
            case 7: move[0] += 1 / 2.0
            default: break
            }
        case 1:
            switch tag {
            case 0: move[0] -= 1 / 2.0
            case 1: move[0] += 1 / 2.0
            case 2: move[2] += 1 / 2.0
            case 3: move[2] -= 1 / 2.0
            case 4: move[1] += 1 / 2.0
            case 5: move[1] -= 1 / 2.0
            case 6: move[0] -= 1 / 2.0
            case 7: move[0] += 1 / 2.0
            default: break
            }
        case 2:
            switch tag {
            case 0: move[1] -= 1 / 2.0
            case 1: move[1] += 1 / 2.0
            case 2: move[2] += 1 / 2.0
            case 3: move[2] -= 1 / 2.0
            case 4: move[0] += 1 / 2.0
            case 5: move[0] -= 1 / 2.0
            case 6: move[0] -= 1 / 2.0
            case 7: move[0] += 1 / 2.0
            default: break
            }
        default:
            break
        }

        move.withUnsafeMutableBufferPointer { self.movePositionPosition($0.baseAddress) }
    }

    public override func awakeFromNib() {
        self.window?.acceptsMouseMovedEvents = true
    }

    @objc(setViewer:)
    public func setViewer(_ viewer: ViewerController?) {
        viewer?.checkEverythingLoaded()

        if viewerController == nil {
            matrixMode?.selectCell(withTag: Int(viewer?.currentOrientationTool ?? 0))
            self.changeMatrixMode(self)
        }

        if viewerController !== viewer {
            viewerController = viewer
        }

        if (viewerController?.isDataVolumicIn4D(true) ?? false) == false {
            NSLog("unsupported data for ThreeDPositionController")
            self.window?.close()
            return
        }
    }

    @objc(closeViewerNotification:)
    public func closeViewerNotification(_ notif: Notification?) {
        if ((ViewerController.getDisplayed2DViewers() as NSArray?)?.count ?? 0) == 0 {
            self.window?.close()
        }
    }

    @objc(windowWillClose:)
    public func windowWillClose(_ notification: Notification?) {
        self.window?.acceptsMouseMovedEvents = false

        self.window?.orderOut(self)

        // Balances the alloc of the caller, which never releases the panel.
        _ = Unmanaged.passUnretained(self).autorelease()
    }

    deinit {
        NSLog("ThreeDPositionController dealloc")
        ThreeDPositionController.nav = nil
        NotificationCenter.default.removeObserver(self)
    }

    @objc(setWindowLevel:)
    public func setWindowLevel(_ notification: Notification?) {
        let name = notification?.name
        if name == NSApplication.willBecomeActiveNotification {
            self.window?.level = .floating
        } else if name == NSApplication.willResignActiveNotification {
            self.window?.level = viewerController?.window?.level ?? NSWindow.Level(rawValue: 0)
        }
    }
}
