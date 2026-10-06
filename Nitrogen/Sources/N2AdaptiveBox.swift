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

/// A box that resizes its containers, up to the window or the enclosing scroll
/// view's document, when its content view changes size.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// `<Horos/N2AdaptiveBox.h>` are those of the former class and of its
/// NSWindowController (N2AdaptiveBox) category.
@objc(N2AdaptiveBox)
public final class N2AdaptiveBox: NSBox {
    private var idealContentSize = NSSize.zero

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override func awakeFromNib() {
        MainActor.assumeIsolated {
            idealContentSize = .zero
        }
    }

    @objc(adaptContainersToIdealSize:) @discardableResult
    public func adaptContainers(toIdealSize size: NSSize) -> NSAnimation? {
        idealContentSize = size
        return adaptContainersToIdealSize()
    }

    @objc(adaptContainersToIdealSize) @discardableResult
    public func adaptContainersToIdealSize() -> NSAnimation? {
        var ret: NSAnimation?

        let view = contentView
        let contentSize = view?.frame.size ?? .zero
        let sizeDelta = NSSize(width: idealContentSize.width-contentSize.width,
                               height: idealContentSize.height-contentSize.height)

        // NSLog(@"adaptContainersToIdealSize with contentSize [%f,%f], idealContentSize [%f,%f], sizeDelta [%f,%f]", contentSize.width, contentSize.height, idealContentSize.width, idealContentSize.height, sizeDelta.width, sizeDelta.height);

        idealContentSize = .zero

        let animations = windowControllerAnimations()

        // The masks to restore, by view.
        var autoresizingMasks: [ObjectIdentifier: (view: NSView, mask: NSView.AutoresizingMask)] = [:]

        var parentScrollView: NSScrollView?
        var parentChildView: NSView = self
        var parentView = superview
        while parentScrollView == nil, let currentParent = parentView {
            let parentChildViewCenter = rectCenter(parentChildView.frame)

            if let scrollView = currentParent as? NSScrollView {
                parentScrollView = scrollView
            } else {
                for view in currentParent.subviews {
                    autoresizingMasks[ObjectIdentifier(view)] = (view, view.autoresizingMask)
                    if view === parentChildView {
                        view.autoresizingMask = [.width, .height]
                    } else {
                        let viewCenter = rectCenter(view.frame)
                        var autoresizingMask = view.autoresizingMask.intersection([.minXMargin, .width, .maxXMargin])
                        if viewCenter.y < parentChildViewCenter.y {
                            autoresizingMask.insert(.maxYMargin)
                        }
                        if viewCenter.y > parentChildViewCenter.y {
                            autoresizingMask.insert(.minYMargin)
                        }
                        //	if (viewCenter.x < parentChildViewCenter.x)
                        //		autoresizingMask |= NSViewMaxXMargin;
                        //	if (viewCenter.x > parentChildViewCenter.x)
                        //		autoresizingMask |= NSViewMinXMargin;
                        view.autoresizingMask = autoresizingMask
                    }
                }
            }

            parentChildView = currentParent
            parentView = currentParent.superview
        }

        if let parentScrollView {
            let documentView = parentScrollView.documentView
            var df = documentView?.frame ?? .zero
            df.size.width += sizeDelta.width
            df.size.height += sizeDelta.height
            // df.origin.y -= sizeDelta.height;

            if let animations {
                // dictionaryWithObjectsAndKeys: stopped at a nil document view.
                let animation: NSDictionary = documentView.map {
                    [NSViewAnimation.Key.target: $0, NSViewAnimation.Key.endFrame: NSValue(rect: df)] as NSDictionary
                } ?? NSDictionary()
                animations.add(animation)
            } else {
                documentView?.frame = df
            }

            ret = window?.windowController?.synchronizeSizeWithContent()
        } else if let window {
            var wf = window.frame
            wf.size.width += sizeDelta.width
            wf.size.height += sizeDelta.height
            wf.origin.y -= sizeDelta.height
            window.setFrame(wf, display: true)
        }

        // NSLog(@"\tsize is now [%f,%f]", view.frame.size.width, view.frame.size.height);

        for (view, mask) in autoresizingMasks.values {
            view.autoresizingMask = mask
        }

        return ret
    }

    public override var contentView: NSView? {
        get { super.contentView }
        set {
            // Read as before; only the commented-out fade animations used it.
            _ = windowControllerAnimations()

            idealContentSize = newValue?.frame.size ?? .zero
            /*[animations addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                                   self.contentView, NSViewAnimationTargetKey,
                                   NSViewAnimationFadeOutEffect, NSViewAnimationEffectKey,
                                   NULL]];*/

            super.contentView = NSView(frame: newValue?.frame ?? .zero)

            if window != nil {
                adaptContainersToIdealSize()
            }

            super.contentView = newValue

            // [[NSNotificationCenter defaultCenter] removeObserver:self name:NSViewFrameDidChangeNotification object:self.contentView];
            // [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(tempFrameDidChange:) name:NSViewFrameDidChangeNotification object:self.contentView];

            /*[animations addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                                   self, NSViewAnimationTargetKey,
                                   NSViewAnimationFadeInEffect, NSViewAnimationEffectKey,
                                   NULL]];*/
        }
    }

    public override func viewDidMoveToWindow() {
        // NSLog(@"%@ viewDidMoveToWindow:%@ sized [%f,%f]", self, self.window, self.window.frame.size.width, self.window.frame.size.height);
        if window != nil && !NSEqualSizes(idealContentSize, .zero) {
            adaptContainersToIdealSize()
        }
        super.viewDidMoveToWindow()
    }

    /// The window controller's `animations` array, when it has one, as
    /// PreferencesWindowController does.
    private func windowControllerAnimations() -> NSMutableArray? {
        guard let windowController = window?.windowController,
              windowController.responds(to: NSSelectorFromString("animations")) else { return nil }
        return windowController.value(forKey: "animations") as? NSMutableArray
    }
}

public extension NSWindowController {
    /// Dynamic, so that a window controller of the app or of a plugin can
    /// override it.
    @objc(synchronizeSizeWithContent) @discardableResult
    dynamic func synchronizeSizeWithContent() -> NSAnimation? {
        nil
    }
}

/// NSRectCenter of the former file: the rect's origin plus half its size.
private func rectCenter(_ rect: NSRect) -> NSPoint {
    NSPoint(x: rect.origin.x+rect.size.width/2, y: rect.origin.y+rect.size.height/2)
}
