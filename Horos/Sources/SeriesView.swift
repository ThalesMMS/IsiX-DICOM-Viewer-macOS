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

// SeriesView is implemented in Swift since #714. The Objective-C name, the
// selectors and <Horos/SeriesView.h> are those of the former class. The ivars
// the class never used (curRoiList, curImage, startImage and the movie times)
// are gone.

/// WindowLayoutManager, reached by its Objective-C selectors.
@objc private protocol SeriesViewLayoutManager {
    @objc(imagesRows) func imagesRows() -> Int32
    @objc(imagesColumns) func imagesColumns() -> Int32
}

/// The WindowLayoutManager class object, reached by its Objective-C selector.
@objc private protocol SeriesViewLayoutManagerClass {
    @objc(sharedWindowLayoutManager) func sharedWindowLayoutManager() -> SeriesViewLayoutManager?
}

/// The -tag every sender of the tool notifications answers.
@objc private protocol SeriesViewTagged {
    @objc(tag) var tag: Int { get }
}

/// The window controller of a viewer window: a ViewerController.
@objc private protocol SeriesViewTilingController {
    @objc(setUpdateTilingViewsValue:) func setUpdateTilingViewsValue(_ v: Bool)
}

/// `[view setPixels: pixels files: files rois: rois firstImage: … level: … reset: …]`
/// with the file list object itself: the [Any] Swift imports `files` as would hand
/// the view a copy, which the viewer's in-place reversal of its fileList leaves stale.
private func dcmViewSetPixels(_ view: DCMView?, _ pixels: NSMutableArray?, files: NSArray?, rois: NSMutableArray?,
                              firstImage: Int16, level: CChar, reset: Bool) {
    guard let view else { return }
    let selector = NSSelectorFromString("setPixels:files:rois:firstImage:level:reset:")
    typealias Send = @convention(c) (AnyObject, Selector, NSMutableArray?, NSArray?, NSMutableArray?, Int16, CChar, Bool) -> Void
    unsafeBitCast(view.method(for: selector), to: Send.self)(view, selector, pixels, files, rois, firstImage, level, reset)
}

private func sharedLayoutManager() -> SeriesViewLayoutManager? {
    unsafeBitCast(WindowLayoutManager.self as AnyObject, to: SeriesViewLayoutManagerClass.self).sharedWindowLayoutManager()
}

private func intValue(_ object: Any?) -> Int32 {
    (object as AnyObject?)?.intValue ?? 0
}

private func floatValue(_ object: Any?) -> Float {
    (object as AnyObject?)?.floatValue ?? 0
}

/// C's int division as arm64 performs it: a zero divisor gives 0 instead of trapping.
private func cQuotient(_ a: Int32, _ b: Int32) -> Int32 {
    b == 0 ? 0 : a.dividedReportingOverflow(by: b).partialValue
}

/// C's int remainder as arm64 performs it (a - (a / b) * b): a zero divisor gives a.
private func cRemainder(_ a: Int32, _ b: Int32) -> Int32 {
    b == 0 ? a : a.remainderReportingOverflow(dividingBy: b).partialValue
}

/** \brief Series View for ViewerControllerr */
@objc(SeriesView)
public final class SeriesView: NSView {
    private var seriesRows: Int32 = 0
    private var seriesColumns: Int32 = 0
    private var tagValue: Int32 = 0
    private var imageRowsValue: Int32 = 0
    private var imageColumnsValue: Int32 = 0
    /// nil when the view comes from -initWithCoder:, which the class did not override.
    private var imageViewsStorage: NSMutableArray?

    private var dcmPixList: NSMutableArray?
    private var dcmFilesList: NSArray?
    private var dcmRoiList: NSMutableArray?
    private var listType: CChar = 0

    public override convenience init(frame: NSRect) {
        self.init(frame: frame, seriesRows: 1, seriesColumns: 1)
    }

    @objc(initWithFrame:seriesRows:seriesColumns:)
    public init(frame: NSRect, seriesRows rows: Int32, seriesColumns columns: Int32) {
        super.init(frame: frame)
        seriesRows = rows
        seriesColumns = columns
        tagValue = 0

        let layoutManager = sharedLayoutManager()
        imageColumnsValue = layoutManager?.imagesColumns() ?? 0
        imageRowsValue = layoutManager?.imagesRows() ?? 0

//		NSLog(@"ImageRows %d imageColumns: %d", imageRows, imageColumns);

        if imageRowsValue == 0 {
            imageRowsValue = 1
        }

        if imageColumnsValue == 0 {
            imageColumnsValue = 1
        }

        let matrixSize = imageRowsValue &* imageColumnsValue
        imageViewsStorage = NSMutableArray()
        // The tag counts the views, and is left at their number.
        while tagValue < matrixSize {
            let dcmView = DCMView(frame: frame, imageRows: imageRowsValue, imageColumns: imageColumnsValue)
            if let dcmView { addSubview(dcmView) }
            dcmView?.tag = Int(tagValue)
            tagValue += 1
        }
        autoresizingMask = .minXMargin
        resizeSubviews(withOldSize: bounds.size)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(updateImageTiling(_:)),
                                               name: NSNotification.Name("DCMImageTilingHasChanged"),
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(defaultToolModified(_:)),
                                               name: .OsirixDefaultToolModified,
                                               object: nil)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(defaultRightToolModified(_:)),
                                               name: .OsirixDefaultRightToolModified,
                                               object: nil)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        NSLog("seriesView dealloc")
        NotificationCenter.default.removeObserver(self)
    }

    public override func draw(_ rect: NSRect) {
        // Fill the view, not the area needing redraw: since macOS 14 NSView no
        // longer clips drawing to its bounds, so an oversized dirty rectangle
        // painted over the surrounding views.
        let rect = bounds
        let backgroundColor = NSColor.black
        backgroundColor.setFill()
        NSBezierPath.fill(rect)
    }

    public override func resize(withOldSuperviewSize oldBoundsSize: NSSize) {
        let superFrame = superview?.bounds ?? .zero

        if superFrame.size.width == 0 || superFrame.size.height == 0 {
            return
        }

        let newWidth = Float(superFrame.size.width / CGFloat(seriesColumns))
        let newHeight = Float(superFrame.size.height / CGFloat(seriesRows))
        let newX = newWidth * Float(cQuotient(tagValue, seriesColumns))
        let newY = newHeight * Float(cRemainder(tagValue, seriesColumns))
        let newFrame = NSRect(x: CGFloat(newX), y: CGFloat(newY), width: CGFloat(newWidth), height: CGFloat(newHeight))
        frame = newFrame
        needsDisplay = true
    }

    public override func resizeSubviews(withOldSize oldBoundsSize: NSSize) {
        super.resizeSubviews(withOldSize: oldBoundsSize)
    }

    public override var isFlipped: Bool {
        true
    }

    public override var autoresizesSubviews: Bool {
        get { true }
        set { super.autoresizesSubviews = newValue }
    }

    public override var acceptsFirstResponder: Bool {
        false
    }

    /// Stored as an int, as before.
    public override var tag: Int {
        get { Int(tagValue) }
        set { tagValue = Int32(truncatingIfNeeded: newValue) }
    }

    @objc(firstView)
    public func firstView() -> DCMView! {
        imageViewsStorage?.object(at: 0) as? DCMView
    }

    @objc(imageViews)
    public func imageViews() -> NSMutableArray! {
        imageViewsStorage
    }

    public override func addSubview(_ aView: NSView) {
        super.addSubview(aView)
        if aView.isKind(of: DCMView.self) {
            imageViewsStorage?.add(aView)
        }
    }

    @objc(selectFirstTilingView)
    public func selectFirstTilingView() {
        let first = imageViewsStorage?.object(at: 0) as? NSResponder
        window?.makeFirstResponder(first)
    }

    @objc(setImageViewMatrixForRows:columns:)
    public func setImageViewMatrix(forRows rows: Int32, columns: Int32) {
        setImageViewMatrix(forRows: rows, columns: columns, rescale: true)
    }

    @objc(setImageViewMatrixForRows:columns:rescale:)
    public func setImageViewMatrix(forRows rows: Int32, columns: Int32, rescale: Bool) {
        NSDisableScreenUpdates()

        let currentSize = imageRowsValue &* imageColumnsValue
        let newSize = rows &* columns
        let imageViews = imageViewsStorage

        let tilingController = window?.windowController.map { unsafeBitCast($0, to: SeriesViewTilingController.self) }
        tilingController?.setUpdateTilingViewsValue(true)

        let wasVisible = window?.isVisible ?? false
        if wasVisible { window?.orderOut(self) }

        var imageLevel = false
        if rescale {
            for case let imageObj as NSObject in dcmFilesList ?? [] {
                let factor = Float(imageRowsValue) / Float(rows)

                let scale = floatValue(imageObj.value(forKey: "scale"))

                if scale != 0 {
                    imageObj.setValue(NSNumber(value: scale * factor), forKey: "scale")
                    imageLevel = true
                }

                let xOffset = floatValue(imageObj.value(forKey: "xOffset"))
                if xOffset != 0 {
                    imageObj.setValue(NSNumber(value: xOffset * factor), forKey: "xOffset")
                }

                let yOffset = floatValue(imageObj.value(forKey: "yOffset"))
                if yOffset != 0 {
                    imageObj.setValue(NSNumber(value: yOffset * factor), forKey: "yOffset")
                }
            }
        }

        // remove views
        if newSize < currentSize {
            window?.makeFirstResponder(imageViews?.object(at: 0) as? NSResponder)
            var i = currentSize - 1
            while i >= newSize {
                let view = imageViews?.lastObject as? DCMView
                view?.removeFromSuperview()
                view?.prepareToRelease()
                imageViews?.removeLastObject()
                i -= 1
            }
        }
        //add views
        else if newSize > currentSize {
            let csis = (imageViews?.lastObject as? DCMView)?.copysettingsinseries ?? false
            var i = Int32(truncatingIfNeeded: imageViews?.count ?? 0)
            while i < rows &* columns {
                let dcmView = DCMView(frame: bounds, imageRows: rows, imageColumns: columns)
                dcmView?.setCOPYSETTINGSINSERIESdirectly(csis)
                if let dcmView { addSubview(dcmView) }
                dcmView?.tag = Int(i)
                dcmViewSetPixels(dcmView, dcmPixList, files: dcmFilesList, rois: dcmRoiList, firstImage: 0, level: listType, reset: true)
                i += 1
            }
        }

        for case let view as DCMView in imageViews ?? [] {
            view.setRows(rows, columns: columns)
        }

        window?.makeFirstResponder(imageViews?.object(at: 0) as? NSResponder)
        tilingController?.setUpdateTilingViewsValue(false)

        resizeSubviews(withOldSize: bounds.size)
        // -makeObjectsPerformSelector:withObject:, which Swift does not offer.
        if let imageViews {
            let firstView = imageViews.object(at: 0)
            let setImageParamaters = NSSelectorFromString("setImageParamatersFromView:")
            for case let view as NSObject in imageViews {
                view.perform(setImageParamaters, with: firstView)
            }
        }

        if rescale {
            if !imageLevel {
                let factor = Float(imageRowsValue) / Float(rows)

                let first = imageViews?.object(at: 0) as? DCMView
                let origin = first?.origin ?? .zero
                first?.setOriginX(Float(origin.x * CGFloat(factor)), y: Float(origin.y * CGFloat(factor)))
                first?.scaleValue = (first?.scaleValue ?? 0) * factor
            } else {
                for case let view as DCMView in imageViews ?? [] {
                    view.updatePresentationState(fromSeriesOnlyImageLevel: false) // Apply the scale modifications
                }
            }
        }

        imageRowsValue = rows
        imageColumnsValue = columns

        if wasVisible { window?.makeKeyAndOrderFront(self) }

        NSEnableScreenUpdates()

        needsDisplay = true
    }

    @objc(updateImageTiling:)
    public func updateImageTiling(_ note: Notification!) {
        if window?.isMainWindow ?? false {
            let userInfo = note.userInfo as NSDictionary?
            let rows = intValue(userInfo?.object(forKey: "Rows"))
            let columns = intValue(userInfo?.object(forKey: "Columns"))
            setImageViewMatrix(forRows: rows, columns: columns)
        }
    }

    @objc(defaultToolModified:)
    func defaultToolModified(_ note: Notification) {
        let sender = note.object as AnyObject?

        let ctag: Int32

        if let matrix = sender as? NSMatrix {
            let theCell = matrix.selectedCell()
            ctag = Int32(truncatingIfNeeded: theCell?.tag ?? 0)
        } else if let sender {
            ctag = Int32(truncatingIfNeeded: unsafeBitCast(sender, to: SeriesViewTagged.self).tag)
        } else {
            ctag = intValue((note.userInfo as NSDictionary?)?.value(forKey: "toolIndex"))
        }
        if ctag >= 0 {
            for case let view as DCMView in imageViewsStorage ?? [] {
                view.currentTool = ToolMode(rawValue: Int16(truncatingIfNeeded: ctag))!
            }
        }
    }

    @objc(defaultRightToolModified:)
    func defaultRightToolModified(_ note: Notification) {
        let sender = note.object as AnyObject?
        let ctag: Int32

        if let matrix = sender as? NSMatrix {
            let theCell = matrix.selectedCell()
            ctag = Int32(truncatingIfNeeded: theCell?.tag ?? 0)
        } else if let sender {
            ctag = Int32(truncatingIfNeeded: unsafeBitCast(sender, to: SeriesViewTagged.self).tag)
        } else {
            // [nil tag] was 0.
            ctag = 0
        }

        if ctag >= 0 {
            for case let view as DCMView in imageViewsStorage ?? [] {
                view.currentToolRight = ToolMode(rawValue: Int16(truncatingIfNeeded: ctag))!
            }
        }
    }

    @objc(setPixels:files:rois:firstImage:level:reset:)
    public func setPixels(_ pixels: NSMutableArray!, files: NSArray!, rois: NSMutableArray!, firstImage: Int16, level: CChar, reset: Bool) {
        dcmPixList = pixels

        dcmFilesList = files

        dcmRoiList = rois

        listType = level

        var i = Int32(firstImage)
        for case let view as DCMView in imageViewsStorage ?? [] {
            // int against NSUInteger, as before: a negative index is never below the count.
            if UInt(bitPattern: Int(i)) < UInt(dcmPixList?.count ?? 0) {
                dcmViewSetPixels(view, pixels, files: files, rois: rois, firstImage: Int16(truncatingIfNeeded: i), level: level, reset: reset)
                i += 1
            } else {
                dcmViewSetPixels(view, pixels, files: files, rois: rois, firstImage: -1, level: level, reset: reset)
            }
        }
    }

    @objc(setDCM::::::)
    public func setDCM(_ c: NSMutableArray!, _ d: NSArray!, _ e: NSMutableArray!, _ firstImage: Int16, _ type: CChar, _ reset: Bool) {
        setPixels(c, files: d, rois: e, firstImage: firstImage, level: type, reset: reset)
    }

    @objc(setBlendingFactor:)
    public func setBlendingFactor(_ value: Float) {
        for case let view as DCMView in imageViewsStorage ?? [] {
            view.setBlendingFactor(value)
        }
    }

    @objc(setBlendingMode:)
    public func setBlendingMode(_ value: Int32) {
        for case let view as DCMView in imageViewsStorage ?? [] {
            view.blendingMode = Int(value)
        }
    }

    @objc(setFlippedData:)
    public func setFlippedData(_ value: Bool) {
        for case let view as DCMView in imageViewsStorage ?? [] {
            view.flippedData = value
        }
    }

    @objc(ActivateBlending:blendingFactor:)
    public func activateBlending(_ bC: ViewerController!, blendingFactor: Float) {
        for case let view as DCMView in imageViewsStorage ?? [] {
            if let bC {
                view.blending = bC.imageView()
            } else {
                view.blending = nil
            }

            view.setBlendingFactor(blendingFactor)
        }
    }

    @objc(imageRows)
    public func imageRows() -> Int32 {
        imageRowsValue
    }

    @objc(imageColumns)
    public func imageColumns() -> Int32 {
        imageColumnsValue
    }
}
