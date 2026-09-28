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

import AppKit

// StudyView is implemented in Swift since #714. The Objective-C name, the
// selectors and <Horos/StudyView.h> are those of the former class.

/** \brief Study View for ViewerController */
@objc(StudyView)
public final class StudyView: NSView {
    private var seriesRows: Int32 = 0
    private var seriesColumns: Int32 = 0
    private var seriesViewsStorage: NSMutableArray?

    public override convenience init(frame: NSRect) {
        self.init(frame: frame, seriesRows: 1, seriesColumns: 1)
    }

    @objc(initWithFrame:seriesRows:seriesColumns:)
    public init(frame: NSRect, seriesRows rows: Int32, seriesColumns columns: Int32) {
        super.init(frame: frame)
        seriesRows = rows
        seriesColumns = columns
        //tag = theTag;
        let count = rows &* columns
        seriesViewsStorage = NSMutableArray()
        let bounds = self.bounds
        var i: Int32 = 0
        while i < count {
            let newWidth = Float(bounds.size.width / CGFloat(seriesColumns))
            let newHeight = Float(bounds.size.height / CGFloat(seriesRows))
            let newX = newWidth * Float(cQuotient(i, seriesColumns))
            let newY = newHeight * Float(cRemainder(i, seriesColumns))
            let newFrame = NSRect(x: CGFloat(newX), y: CGFloat(newY), width: CGFloat(newWidth), height: CGFloat(newHeight))
            let seriesView = SeriesView(frame: newFrame, seriesRows: seriesRows, seriesColumns: seriesColumns)
            seriesViewsStorage?.add(seriesView)
            seriesView.tag = Int(i)
            addSubview(seriesView)
            i += 1
        }
    }

    // The former class did not override -initWithCoder: and built no series
    // view there.
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        NSLog("studyView dealloc")
        NotificationCenter.default.removeObserver(self)
    }

    public override var acceptsFirstResponder: Bool {
        false
    }

    public override var isFlipped: Bool {
        true
    }

    public override var autoresizesSubviews: Bool {
        get { true }
        set { super.autoresizesSubviews = newValue }
    }

    @objc(seriesViews)
    public func seriesViews() -> NSMutableArray! {
        seriesViewsStorage
    }

    public override func resizeSubviews(withOldSize oldBoundsSize: NSSize) {
        super.resizeSubviews(withOldSize: oldBoundsSize)
    }

    @objc(setSeriesViewMatrixForRows:columns:)
    public func setSeriesViewMatrix(forRows rows: Int32, columns: Int32) {
    }
}

/// C's int division as arm64 performs it: a zero divisor gives 0 instead of trapping.
private func cQuotient(_ a: Int32, _ b: Int32) -> Int32 {
    b == 0 ? 0 : a.dividedReportingOverflow(by: b).partialValue
}

/// C's int remainder as arm64 performs it (a - (a / b) * b): a zero divisor gives a.
private func cRemainder(_ a: Int32, _ b: Int32) -> Int32 {
    b == 0 ? a : a.remainderReportingOverflow(dividingBy: b).partialValue
}
