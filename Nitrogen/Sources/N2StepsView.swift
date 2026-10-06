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

/// The column of N2StepViews that shows the steps of an N2Steps.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// `<Horos/N2StepsView.h>` are those of the former class.
@available(*, deprecated)
@objc(N2StepsView)
public final class N2StepsView: N2View {
    @IBOutlet public var _steps: N2Steps?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        awakeFromNib()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public override func awakeFromNib() {
        MainActor.assumeIsolated {
            let columnDescriptors = [N2ColumnDescriptor.descriptor()]
            let layout = N2ColumnLayout(forView: self, columnDescriptors: columnDescriptors, controlSize: .mini)
            layout.forcesSuperviewHeight = true
            layout.separation = .zero

            NotificationCenter.default.addObserver(self, selector: #selector(stepsDidAddStep(_:)), name: .N2StepsDidAddStep, object: _steps)
            NotificationCenter.default.addObserver(self, selector: #selector(stepsWillRemoveStep(_:)), name: .N2StepsWillRemoveStep, object: _steps)

            if let steps = _steps, let content = steps.content as? NSArray {
                for step in content {
                    stepsDidAddStep(Notification(name: .N2StepsDidAddStep, object: steps, userInfo: [N2StepsNotificationStep: step]))
                }
            }

            n2Layout?.layOut()
        }
    }

    /// Unlike N2View's, sets the title color of the step views without
    /// formatting the subviews.
    public override var foreColor: NSColor? {
        get { super.foreColor }
        set {
            foreColorStorage = newValue
            for view in subviews {
                ((view as? N2DisclosureBox)?.titleCell as? N2DisclosureButtonCell)?.attributes?.setValue(foreColor, forKey: NSAttributedString.Key.foregroundColor.rawValue)
            }
        }
    }

    /// Unlike N2View's, sets the title font of the step views.
    public override var controlSize: NSControl.ControlSize {
        get { super.controlSize }
        set {
            controlSizeStorage = newValue
            for view in subviews {
                ((view as? N2DisclosureBox)?.titleCell as? N2DisclosureButtonCell)?.attributes?.setValue(NSFont.labelFont(ofSize: NSFont.systemFontSize(for: newValue)), forKey: NSAttributedString.Key.font.rawValue)
            }
        }
    }

    /*func recomputeSubviewFramesAndAdjustSizes() {
        let interStepViewYDelta: CGFloat = 1
        var frame = self.frame

        var h: CGFloat = 0
        for view in views.reversed() {
            h += view.frame.size.height + interStepViewYDelta
        }

        let window = self.window!
        let wf = window.frame
        var nwf = wf
        var nwc = window.contentRect(forFrameRect: wf)
        nwc.size.height = h + frame.origin.y * 2
        nwf.size = window.frameRect(forContentRect: nwc).size
        nwf.origin.y -= nwf.size.height - wf.size.height
        window.setFrame(nwf, display: true)

        // move StepViews
        var y: CGFloat = 0
        for stepView in views.reversed() {
            let stepSize = stepView.frame.size
            stepView.frame = NSRect(x: 0, y: y, width: frame.size.width, height: stepSize.height)
            y += stepSize.height + interStepViewYDelta
        }

        y -= interStepViewYDelta

        // resize N2StepsView
        frame.size.height = y
        self.frame = frame
    }*/

    @objc(stepsDidAddStep:) public func stepsDidAddStep(_ notification: Notification) {
        let step = notification.userInfo?[N2StepsNotificationStep] as? N2Step
        let view = N2StepView(step: step)

        let attributes = (view.titleCell as? N2DisclosureButtonCell)?.attributes
        // +[NSDictionary dictionaryWithObjectsAndKeys:] stopped at the first
        // nil: without a foreground color, neither attribute was added.
        var entries: [AnyHashable: Any] = [:]
        if let foreColor = foreColor {
            entries = [
                NSAttributedString.Key.foregroundColor.rawValue: foreColor,
                NSAttributedString.Key.font.rawValue: NSFont.labelFont(ofSize: NSFont.systemFontSize(for: controlSize)),
            ]
        }
        attributes?.addEntries(from: entries)

        view.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(stepViewFrameDidChange(_:)), name: NSView.frameDidChangeNotification, object: view)

        (n2Layout as? N2ColumnLayout)?.appendRow([view])

        layOut()
    }

    @objc(stepViewForStep:) public func stepView(for step: N2Step?) -> N2StepView? {
        for view in subviews {
            if let stepView = view as? N2StepView, stepView.step === step {
                return stepView
            }
        }
        return nil
    }

    @objc(stepsWillRemoveStep:) public func stepsWillRemoveStep(_ notification: Notification) {
        let step = notification.userInfo?[N2StepsNotificationStep] as? N2Step
        let view = stepView(for: step)

        view?.postsFrameChangedNotifications = false

        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: view)
        view?.removeFromSuperview()

        n2Layout?.layOut()
    }

    @objc(stepViewFrameDidChange:) public func stepViewFrameDidChange(_ notification: Notification) {
        n2Layout?.layOut()
    }

    @objc public func layOut() {
        n2Layout?.layOut()
    }

    public override func optimalSize() -> NSSize {
        let size = n2Layout?.optimalSize() ?? .zero
        return NSSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
    }

    public override func optimalSize(forWidth width: CGFloat) -> NSSize {
        let size = n2Layout?.optimalSize(forWidth: width) ?? .zero
        return NSSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
    }
}
