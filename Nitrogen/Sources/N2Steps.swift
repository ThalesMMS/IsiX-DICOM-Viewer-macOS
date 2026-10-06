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

/// The informal N2StepsDelegate protocol of N2Steps.h, to call the delegate's
/// methods after asking it `respondsToSelector:`, as the Objective-C code did.
@available(*, deprecated)
@objc private protocol N2StepsDelegateMethods {
    @objc(steps:willBeginStep:) func steps(_ steps: N2Steps, willBeginStep step: N2Step?)
    @objc(steps:valueChanged:) func steps(_ steps: N2Steps, valueChanged sender: Any?)
    @objc(steps:shouldValidateStep:) func steps(_ steps: N2Steps, shouldValidateStep step: N2Step?) -> Bool
    @objc(steps:validateStep:) func steps(_ steps: N2Steps, validateStep step: N2Step?)
}

/// The steps of an assistant, one of them current.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// `<Horos/N2Steps.h>` are those of the former class. The notification
/// names stay in N2Steps+CAPI.m, and the informal delegate protocol stays
/// in N2Steps.h.
@available(*, deprecated)
@objc(N2Steps)
public final class N2Steps: NSArrayController {
    //@IBOutlet var _view: N2StepsView?
    /// Not retained, as the former `assign` property.
    private weak var currentStepStorage: N2Step?
    @IBOutlet public var _delegate: AnyObject?

    @objc public dynamic var delegate: AnyObject? {
        get { _delegate }
        set { _delegate = newValue }
    }

    // MARK: The content, messaged as the Objective-C code did

    /// `[[self content] count]`, 0 without content.
    private var stepCount: Int {
        (content as? NSArray)?.count ?? 0
    }

    /// `[[self content] indexOfObject:step]` as an NSUInteger: NSNotFound when
    /// the step is nil or absent, 0 without content (a message to nil).
    private func contentIndex(of step: N2Step?) -> UInt {
        guard let content = content as? NSArray else { return 0 }
        guard let step = step else { return UInt(NSNotFound) }
        return UInt(content.index(of: step))
    }

    /// `[[self content] objectAtIndex:index]`, raising NSRangeException out of range.
    private func step(at index: UInt) -> N2Step? {
        (content as? NSArray)?.object(at: Int(bitPattern: index)) as? N2Step
    }

    private var stepsDelegate: N2StepsDelegateMethods? {
        _delegate.map { unsafeBitCast($0, to: N2StepsDelegateMethods.self) }
    }

    private func delegateResponds(to selector: String) -> Bool {
        _delegate?.responds(to: NSSelectorFromString(selector)) ?? false
    }

    // MARK: NSArrayController

    public override func addObject(_ object: Any) {
        assert(object is N2Step, "[N2Steps addObject:] only accepts objects inheriting from class N2Step")
        super.addObject(object)
        NotificationCenter.default.post(name: .N2StepsDidAddStep, object: self, userInfo: [N2StepsNotificationStep: object])
        if currentStepStorage == nil {
            currentStep = object as? N2Step
        }
    }

    public override func removeObject(_ object: Any) {
        NotificationCenter.default.post(name: .N2StepsWillRemoveStep, object: self, userInfo: [N2StepsNotificationStep: object])
        super.removeObject(object)
    }

    // MARK: Steps

    /// Enables the steps until a necessary and non done step is encountered.
    @objc public func enableDisableSteps() {
        var enable = true
        // The Objective-C loop counted with an `unsigned`: NSNotFound became
        // 0xFFFFFFFF, past any count, and the loop did nothing.
        var i = UInt(UInt32(truncatingIfNeeded: contentIndex(of: currentStepStorage)))
        while i < UInt(stepCount) {
            let step = self.step(at: i)
            step?.enabled = enable
            if (step?.necessary ?? false) && !(step?.done ?? false) {
                enable = false
            }
            i += 1
        }
    }

    @objc public dynamic var currentStep: N2Step? {
        get { currentStepStorage }
        set {
            let step = newValue
            //if step === currentStepStorage { return }

            guard let content = content as? NSArray, let candidate = step, content.contains(candidate) else {
                return
            }

            if currentStepStorage !== candidate {
                currentStepStorage?.active = false
            }

            currentStepStorage = candidate

            currentStepStorage?.active = true
            enableDisableSteps()

            if delegateResponds(to: "steps:willBeginStep:") {
                stepsDelegate?.steps(self, willBeginStep: currentStep)
            }
        }
    }

    @objc public func hasNextStep() -> Bool {
        // NSUInteger < (long)count-1, compared as unsigned: true without steps.
        contentIndex(of: currentStepStorage) < UInt(bitPattern: stepCount - 1)
    }

    @objc public func hasPreviousStep() -> Bool {
        contentIndex(of: currentStepStorage) > 0
    }

    @IBAction @objc(stepDone:) public func stepDone(_ sender: Any?) {
        var step: N2Step?
        if let sender = sender as? N2Step {
            step = sender
        }
        if let sender = sender as? NSView {
            var view: NSView? = sender
            while let candidate = view, !(candidate is N2StepView) {
                view = candidate.superview
            }
            step = (view as? N2StepView)?.step
        }

        guard let step = step else {
            NSLog("Warning: unidentified step done")
            return
        }

        if delegateResponds(to: "steps:shouldValidateStep:") && !(stepsDelegate?.steps(self, shouldValidateStep: step) ?? false) {
            return
        }

        if delegateResponds(to: "steps:validateStep:") {
            stepsDelegate?.steps(self, validateStep: step)
        }
        step.done = true

        if currentStepStorage === step && hasNextStep() {
            currentStep = self.step(at: contentIndex(of: step) &+ 1)
        }
    }

    @IBAction @objc(nextStep:) public func nextStep(_ sender: Any?) {
        stepDone(sender)
    }

    @IBAction @objc(previousStep:) public func previousStep(_ sender: Any?) {
        if !hasPreviousStep() {
            return
        }

        currentStep = step(at: contentIndex(of: currentStepStorage) &- 1)
    }

    @IBAction @objc(skipStep:) public func skipStep(_ sender: Any?) {
        if currentStep?.necessary ?? false {
            return
        }

        if !hasNextStep() {
            return
        }

        currentStep = step(at: contentIndex(of: currentStepStorage) &+ 1)
    }

    @IBAction @objc(stepValueChanged:) public func stepValueChanged(_ sender: Any?) {
        if delegateResponds(to: "steps:valueChanged:") {
            stepsDelegate?.steps(self, valueChanged: sender)
        }
    }

    @IBAction @objc(reset:) public func reset(_ sender: Any?) {
        var i: UInt = 0
        while i < UInt(stepCount) {
            step(at: i)?.done = false
            i += 1
        }

        currentStep = step(at: 0)
    }
}
