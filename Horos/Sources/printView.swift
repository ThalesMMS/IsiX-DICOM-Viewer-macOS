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

/// `[string stringByAppendingFormat: @"%@", object]`: "(null)" for nil.
private func printViewDescribe(_ object: Any?) -> String {
    guard let object = object else { return "(null)" }
    if let object = object as AnyObject as? NSObject {
        return NSString(format: "%@", object) as String
    }
    return String(describing: object)
}

/// A message without arguments sent to an object typed `id`, as the former
/// code sent -fileList and -pixList to the viewer and -acquisitionTime to a
/// DCMPix: nil answers nil.
private func printViewSend(_ receiver: Any?, _ selector: String) -> AnyObject? {
    guard let receiver = receiver as AnyObject? else { return nil }
    return receiver.perform(NSSelectorFromString(selector))?.takeUnretainedValue()
}

/// The acquisition instant, independent of the machine's preferred calendar.
private func printViewCalendarDate(_ interval: TimeInterval) -> NSDate {
    return NSDate(timeIntervalSinceReferenceDate: interval)
}

private func printViewYearOfCommonEra(_ date: NSDate) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = NSTimeZone.default
    return calendar.component(.year, from: date as Date)
}

/// View used for printing from ViewerController.
///
/// Implemented in Swift since #717: the Objective-C name, the selectors and
/// <Horos/printView.h> are those of the former class.
@objc(printView)
public final class printView: NSView {
    private var viewer: Any?
    private var settings: NSDictionary?
    private var filesToPrint: NSArray?
    private var columnsValue: Int32 = 0
    private var rowsValue: Int32 = 0
    private var ippValue: Int32 = 0
    private var headerHeight: Float = 0

    //-----------------------------------------------------------------------
    // called from ViewerController endPrint:
    //-----------------------------------------------------------------------

    @objc(initWithViewer:settings:files:printInfo:)
    public init(viewer v: Any!, settings s: NSDictionary!, files f: NSArray!, printInfo pi: NSPrintInfo!) {
        //imageablePageBounds gives the NSRect that is authorized for printing in a specific paper size for a specific printer. It respects custom margins of custom papersize as well.
        let imageablePageBounds = pi?.imageablePageBounds ?? .zero
        NSLog("imageablePageBounds origin.x=%f origin.y=%f size.width=%f size.height=%f", Double(imageablePageBounds.origin.x), Double(imageablePageBounds.origin.y), Double(imageablePageBounds.size.width), Double(imageablePageBounds.size.height))

        super.init(frame: pi?.imageablePageBounds ?? .zero)

        viewer = v
        settings = s
        filesToPrint = f
        columnsValue = (settings?.object(forKey: "columns") as AnyObject?)?.intValue ?? 0
        rowsValue = (settings?.object(forKey: "rows") as AnyObject?)?.intValue ?? 0
        ippValue = columnsValue &* rowsValue
    }

    /// -initWithFrame: of NSView, which the former class inherited.
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    /// -initWithCoder: of NSView, which the former class inherited.
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    //-----------------------------------------------------------------------
    // Accessors, mainly used for unit tests
    //-----------------------------------------------------------------------

    @objc public func columns() -> Int32 { return columnsValue }
    @objc public func rows() -> Int32 { return rowsValue }
    @objc public func ipp() -> Int32 { return ippValue }


    //-----------------------------------------------------------------------

    public override func drawPageBorder(with borderSize: NSSize) {
        super.drawPageBorder(with: borderSize)

        if self.frame.size.width > 0 && self.frame.size.height > 0 {
            // AppKit has already installed the printing context for this callback.

            let file = (printViewSend(viewer, "fileList") as? NSArray)?.object(at: 0) as AnyObject?
            var string2draw = ""
            headerHeight = 13 //leaves in all cases a white line at the end of the header


            var range = NSRange(location: 0, length: 0)
            _ = self.knowsPageRange(&range)
            if settings?.value(forKey: "comments") != nil {
                headerHeight += 13
                string2draw += String(format: "%@   (%d/%d)\r", printViewDescribe(settings?.value(forKey: "comments")) as NSString, Int32(truncatingIfNeeded: NSPrintOperation.current?.currentPage ?? 0), Int32(truncatingIfNeeded: range.length))
            }


            if settings?.value(forKey: "patientInfo") != nil {
                headerHeight += 13
                string2draw += NSLocalizedString("Patient", comment: "Print header label") + ": "
                if file?.value(forKeyPath: "series.study.name") != nil { string2draw += printViewDescribe(file?.value(forKeyPath: "series.study.name")) }
                if file?.value(forKeyPath: "series.study.patientID") != nil { string2draw += "  [" + printViewDescribe(file?.value(forKeyPath: "series.study.patientID")) + "]" }
                if file?.value(forKeyPath: "series.study.dateOfBirth") != nil { string2draw += "  " + printViewDescribe((file?.value(forKeyPath: "series.study.dateOfBirth") as? Date).map { UserDefaults.dateFormatter().string(from: $0) }) }
                string2draw += "\r"
            }


            if settings?.value(forKey: "studyInfo") != nil {
                headerHeight += 13
                string2draw += NSLocalizedString("Study", comment: "Print header label") + ": "

                var date: NSDate? = printViewCalendarDate((file?.value(forKey: "date") as AnyObject?)?.timeIntervalSinceReferenceDate ?? 0)
                if let studyDate = date, printViewYearOfCommonEra(studyDate) != 3000 {
                    var tempString: String? = UserDefaults.dateFormatter().string(from: studyDate as Date)
                    string2draw += printViewDescribe(tempString)

                    let pic = (printViewSend(viewer, "pixList") as? NSArray)?.object(at: 0)

                    if let acquisitionTime = printViewSend(pic, "acquisitionTime") {
                        date = printViewCalendarDate((acquisitionTime as? NSDate)?.timeIntervalSinceReferenceDate ?? 0)
                    }
                    if let timeDate = date, printViewYearOfCommonEra(timeDate) != 3000 {
                        tempString = BrowserController.timeFormat(timeDate as Date)
                        string2draw += " - " + printViewDescribe(tempString) + "    "
                    }
                }

                if let studyName = file?.value(forKeyPath: "series.study.studyName"), !((studyName as? NSString)?.isEqual(to: "unnamed") ?? false) { string2draw += printViewDescribe(studyName) + "  " }
                if let seriesName = file?.value(forKeyPath: "series.name"), !((seriesName as? NSString)?.isEqual(to: "unnamed") ?? false) { string2draw += printViewDescribe(seriesName) + "  " }
                string2draw += "\r"
            }

            var attribs = [NSAttributedString.Key: Any]()
            attribs[.font] = NSFont.systemFont(ofSize: 10)
            //
            let where2draw = NSMakePoint(20, borderSize.height - CGFloat(headerHeight + 15))
            (string2draw as NSString).draw(at: where2draw, withAttributes: attribs) //only invoke this method when an NSView object has focus
        }
    }

    //---------------------------------------------------------------------------

    public override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        //To provide a completely custom pagination scheme that does not use NSView’s built-in pagination support,
        //a view must override the knowsPageRange: method to return YES. It should also return by reference the page
        //range for the document.
        range.pointee.location = 1
        // The former unsigned long arithmetic, where a division by zero gives
        // zero on arm64.
        let count = UInt(filesToPrint?.count ?? 0)
        let ipp = UInt(bitPattern: Int(ippValue))
        range.pointee.length = ipp == 0 ? 0 : Int(bitPattern: (count &+ ipp &- 1) / ipp)
        return true
    }

    //---------------------------------------------------------------------------

    public override func rectForPage(_ page: Int) -> NSRect {
        //Before printing each page, the pagination machinery sends the view a rectForPage: message.
        //Your implementation of rectForPage: should use the supplied page number and the current printing information to
        //calculate an appropriate drawing rectangle in the view’s coordinate system.
        return self.bounds
    }

    //-----------------------------------------------------------------------

    public override func draw(_ dirtyRect: NSRect) {
        autoreleasepool {
            NSGraphicsContext.current?.imageInterpolation = .high

            let frameSize = self.frame.size

            let page = Int32(truncatingIfNeeded: NSPrintOperation.current?.currentPage ?? 0)


            if (settings?.value(forKey: "backgroundColor") as AnyObject?)?.boolValue ?? false {
                NSColor(deviceRed: CGFloat((settings?.value(forKey: "backgroundColorR") as AnyObject?)?.floatValue ?? 0),
                        green: CGFloat((settings?.value(forKey: "backgroundColorG") as AnyObject?)?.floatValue ?? 0),
                        blue: CGFloat((settings?.value(forKey: "backgroundColorB") as AnyObject?)?.floatValue ?? 0),
                        alpha: 1.0).set()
                // NSRectFill: NSCompositingOperationCopy.
                NSRect(x: 0, y: 0, width: frameSize.width, height: frameSize.height - CGFloat(headerHeight)).fill(using: .copy)
            }

            let headerHeight = CGFloat(self.headerHeight)
            var y: Int32 = 0
            while y < rowsValue {
                var x: Int32 = 0
                while x < columnsValue {
                    let index = (page &- 1) &* ippValue &+ y &* columnsValue &+ x

                    let rect = NSRect(x: CGFloat(x) * frameSize.width / CGFloat(columnsValue),
                                      y: CGFloat(rowsValue &- 1 &- y) * (frameSize.height - headerHeight) / CGFloat(rowsValue),
                                      width: frameSize.width / CGFloat(columnsValue),
                                      height: (frameSize.height - headerHeight) / CGFloat(rowsValue))

                    // index < [filesToPrint count], an unsigned comparison.
                    if index >= 0 && Int(index) < (filesToPrint?.count ?? 0) {
                        let im = NSImage(contentsOfFile: filesToPrint?.object(at: Int(index)) as? String ?? "")
                        let imSize = im?.size ?? .zero

                        let dstRect: NSRect

                        if rect.size.width / rect.size.height > imSize.width / imSize.height {
                            let ratio = Float(rect.size.height / imSize.height)
                            dstRect = NSRect(x: rect.origin.x + (rect.size.width - imSize.width * CGFloat(ratio)) / 2, y: rect.origin.y, width: imSize.width * CGFloat(ratio), height: rect.size.height)
                        } else {
                            let ratio = Float(rect.size.width / imSize.width)
                            dstRect = NSRect(x: rect.origin.x, y: rect.origin.y + (rect.size.height - imSize.height * CGFloat(ratio)) / 2, width: rect.size.width, height: imSize.height * CGFloat(ratio))
                        }

                        //NSZeroRect = complete image
                        //NSInsetRect(dstRect, 1, 1) leaves one pixel border separation around the image
                        im?.draw(in: NSInsetRect(dstRect, 1, 1), from: NSZeroRect, operation: .copy, fraction: 1.0)
                    }
                    x += 1
                }
                y += 1
            }
        }
    }
}
