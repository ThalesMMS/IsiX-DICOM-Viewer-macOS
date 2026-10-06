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

/// The grid of the anonymization panel: for each DICOM tag a check box, a
/// value field and a remove button, in two columns, then the tags menu and an
/// add button.
///
/// Implemented in Swift: the Objective-C name, the selectors
/// and <Horos/AnonymizationTagsView.h> are those of the former class.
@objc(AnonymizationTagsView)
public final class AnonymizationTagsView: NSView {
    /// One array per tag: check box, text field, remove button, DICOM tag.
    private var viewGroups = NSMutableArray()
    private var intercellSpacing = NSSize.zero
    private var cellSize = NSSize.zero
    /// An IBOutlet instance variable in the former class, which did not retain
    /// it. The view controller owns this view, so the reference is weak.
    @IBOutlet weak var anonymizationViewController: AnonymizationViewController?
    private var dcmTagsPopUpButton: AnonymizationTagsPopUpButton?
    private var dcmTagAddButton: NSButton?

    private static let kMaxTextFieldWidth: CGFloat = 200
    private static let kButtonSpace: CGFloat = 15
    /// The former function-level static, made on first use.
    private static let tagFont = NSFont.labelFont(ofSize: NSFont.smallSystemFontSize - 1)

    /// The nib makes this view (a custom view) with -initWithFrame:.
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        intercellSpacing = NSSize(width: 13, height: 1)

        let popUpButton = AnonymizationTagsPopUpButton(frame: .zero)
        popUpButton.cell?.controlSize = .mini
        popUpButton.font = NSFont.labelFont(ofSize: NSFont.smallSystemFontSize - 2)
        dcmTagsPopUpButton = popUpButton
        addSubview(popUpButton)

        let addButtonCell = N2HighlightImageButtonCell(image: NSImage(named: "PlusButton"))
        let addButton = NSButton(frame: .zero)
        addButton.cell = addButtonCell
        addButton.target = self
        addButton.action = #selector(addButtonAction(_:))
        dcmTagAddButton = addButton
        addSubview(addButton)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc(groupForObject:)
    func group(forObject object: Any?) -> NSArray? {
        let object = object as AnyObject?
        for case let group as NSArray in viewGroups {
            for obj in group {
                if (obj as AnyObject) === object || (obj as? NSObject)?.isEqual(object) == true {
                    return group
                }
            }
        }
        return nil
    }

    @objc(addButtonAction:)
    func addButtonAction(_ sender: NSButton) {
        anonymizationViewController?.addTag(dcmTagsPopUpButton?.selectedDCMAttributeTag)
        anonymizationViewController?.tagsView?.checkBox(forObject: dcmTagsPopUpButton?.selectedDCMAttributeTag)?.state = .on
        window?.makeFirstResponder(anonymizationViewController?.tagsView?.textField(forObject: dcmTagsPopUpButton?.selectedDCMAttributeTag))
        dcmTagsPopUpButton?.selectedDCMAttributeTag = nil
    }

    @objc(rmButtonAction:)
    func rmButtonAction(_ sender: NSButton) {
        anonymizationViewController?.removeTag(group(forObject: sender)?.object(at: 3) as? DCMAttributeTag)
    }

    public override func awakeFromNib() {
        MainActor.assumeIsolated {
            resizeSubviews(withOldSize: frame.size)
        }
    }

    public override var isFlipped: Bool {
        return true
    }

    @objc func columnCount() -> Int {
        return 2
    }

    @objc func rowCount() -> Int {
        return Int(ceil(CGFloat(viewGroups.count + 1) / CGFloat(columnCount())))
    }

    @objc(cellFrameForIndex:)
    func cellFrame(forIndex index: Int) -> NSRect {
        let column = index % columnCount(), row = Int(floor(CGFloat(index) / CGFloat(columnCount())))
        return NSRect(x: (cellSize.width + intercellSpacing.width) * CGFloat(column),
                      y: (cellSize.height + intercellSpacing.height) * CGFloat(row),
                      width: cellSize.width, height: cellSize.height)
    }

    @objc(checkBoxFrameForCellFrame:)
    func checkBoxFrame(forCellFrame frame: NSRect) -> NSRect {
        var frame = frame
        let textFieldWidth: CGFloat
        if (frame.size.width - AnonymizationTagsView.kButtonSpace) / 2 < AnonymizationTagsView.kMaxTextFieldWidth {
            textFieldWidth = (frame.size.width - AnonymizationTagsView.kButtonSpace) / 2
        } else {
            textFieldWidth = AnonymizationTagsView.kMaxTextFieldWidth
        }
        frame.size.width -= frame.size.height + textFieldWidth
        return frame
    }

    @objc(textFieldFrameForCellFrame:)
    func textFieldFrame(forCellFrame frame: NSRect) -> NSRect {
        var frame = frame
        let textFieldWidth: CGFloat
        if (frame.size.width - AnonymizationTagsView.kButtonSpace) / 2 < AnonymizationTagsView.kMaxTextFieldWidth {
            textFieldWidth = (frame.size.width - AnonymizationTagsView.kButtonSpace) / 2
        } else {
            textFieldWidth = AnonymizationTagsView.kMaxTextFieldWidth
        }
        frame.origin.x += frame.size.width - textFieldWidth - frame.size.height
        frame.size.width = textFieldWidth
        return frame
    }

    @objc(buttonFrameForCellFrame:)
    func buttonFrame(forCellFrame frame: NSRect) -> NSRect {
        var frame = frame
        frame.origin.x += frame.size.width - 10
        frame.origin.y += 4
        frame.size = NSSize(width: 10, height: 10)
        return frame
    }

    @objc(popUpButtonFrameForCellFrame:)
    func popUpButtonFrame(forCellFrame frame: NSRect) -> NSRect {
        var frame = frame
        frame.size.width -= AnonymizationTagsView.kButtonSpace
        return frame
    }

    @objc(repositionGroupViews:)
    func repositionGroupViews(_ group: NSArray) {
        let cellFrame = self.cellFrame(forIndex: viewGroups.index(of: group))
        (group.object(at: 0) as? NSView)?.frame = checkBoxFrame(forCellFrame: cellFrame)
        (group.object(at: 1) as? NSView)?.frame = textFieldFrame(forCellFrame: cellFrame)
        (group.object(at: 2) as? NSView)?.frame = buttonFrame(forCellFrame: cellFrame)
    }

    @objc func repositionAddTagInterface() {
        let cellFrame = self.cellFrame(forIndex: viewGroups.count)
        dcmTagsPopUpButton?.frame = popUpButtonFrame(forCellFrame: cellFrame)
        dcmTagAddButton?.frame = buttonFrame(forCellFrame: cellFrame)
    }

    @objc(addTag:)
    public func addTag(_ tag: DCMAttributeTag!) {
        let font = AnonymizationTagsView.tagFont

        let checkBox = NSButton(frame: .zero)
        checkBox.cell?.controlSize = .mini
        checkBox.font = font
        checkBox.cell?.lineBreakMode = .byTruncatingMiddle
        checkBox.setButtonType(.switch)
        // -setTitle: took the nil name of a tag missing from the dictionary as "".
        checkBox.title = tag?.name ?? ""
        addSubview(checkBox)

        let textField = N2TextField(frame: .zero)
        textField.cell?.controlSize = .mini
        textField.font = font
        textField.isBezeled = true
        textField.bezelStyle = .squareBezel
        textField.drawsBackground = true
        (textField.cell as? NSTextFieldCell)?.placeholderString = NSLocalizedString("Reset", comment: "Placeholder string for Anonymization Tag cells")
        textField.stringValue = ""
        addSubview(textField)

        let vr = tag?.vr
        if vr == "DA" || vr == "TM" || vr == "DT" {
            let df = DateFormatter()
            textField.cell?.formatter = df
            df.formatterBehavior = .behavior10_4
            if vr == "DA" { //Date String
                df.timeStyle = .none
                df.dateStyle = .short
            } else if vr == "TM" { //Time String
                df.timeStyle = .short
                df.dateStyle = .none
            } else if vr == "DT" { //Date Time
                df.timeStyle = .short
                df.dateStyle = .short
            }

            if (df.dateFormat as NSString).range(of: "yyyy").location == NSNotFound && (df.dateFormat as NSString).range(of: "yy").location != NSNotFound {
                let fourDigitYearFormat = (df.dateFormat as NSString).replacingOccurrences(of: "yy", with: "yyyy")
                df.dateFormat = fourDigitYearFormat
            }

            textField.toolTip = String(format: NSLocalizedString("Required format: %@", comment: ""), df.dateFormat)

        } else if vr == "DS" || vr == "IS" || vr == "SL" || vr == "SS" || vr == "UL" || vr == "US" || vr == "FL" || vr == "FD" {
            var nf = NumberFormatter()
            textField.cell?.formatter = nf
            nf.formatterBehavior = .behavior10_4
            nf.numberStyle = .decimal
            if vr == "DS" { //Decimal String representing floating point
                nf.maximumSignificantDigits = 16
                textField.toolTip = NSLocalizedString("Required format: floating point number", comment: "")
            } else if vr == "IS" { //Integer String
                nf.maximumSignificantDigits = 12
                nf.allowsFloats = false
                textField.toolTip = NSLocalizedString("Required format: integer number", comment: "")
            } else if vr == "SL" { //signed long
                nf.allowsFloats = false
                // The former [NSNumber numberWithInteger:-0x80000000] was
                // +2147483648: 0x80000000 is unsigned in C.
                nf.minimum = NSNumber(value: Int32.min)
                nf.maximum = NSNumber(value: 0x7FFFFFFF as Int)
                textField.toolTip = NSLocalizedString("Required format: integer number", comment: "")
            } else if vr == "SS" { //signed short
                nf.allowsFloats = false
                nf.minimum = NSNumber(value: -0x8000 as Int)
                nf.maximum = NSNumber(value: 0x7FFF as Int)
                textField.toolTip = NSLocalizedString("Required format: integer number", comment: "")
            } else if vr == "UL" { //unsigned long
                // As before, a second formatter, without the decimal style.
                nf = NumberFormatter()
                textField.cell?.formatter = nf
                nf.allowsFloats = false
                nf.minimum = NSNumber(value: 0 as Int)
                nf.maximum = NSNumber(value: 0xFFFFFFFF as Int)
                textField.toolTip = NSLocalizedString("Required format: integer number", comment: "")
            } else if vr == "US" { //unsigned short
                nf.allowsFloats = false
                nf.minimum = NSNumber(value: 0 as Int)
                nf.maximum = NSNumber(value: 0xFFFF as Int)
                textField.toolTip = NSLocalizedString("Required format: integer number", comment: "")
            } else if vr == "FL" { //float
                textField.toolTip = NSLocalizedString("Required format: floating point number", comment: "")
            } else if vr == "FD" { //double
                textField.toolTip = NSLocalizedString("Required format: floating point number", comment: "")
            }
        }

        let rmButtonCell = N2HighlightImageButtonCell(image: NSImage(named: "MinusButton"))
        let rmButton = NSButton(frame: .zero)
        rmButton.cell = rmButtonCell
        rmButton.target = self
        rmButton.action = #selector(rmButtonAction(_:))
        addSubview(rmButton)

        let textFieldContext = Unmanaged.passUnretained(textField).toOpaque()
        textField.bind(.enabled, to: checkBox.cell!, withKeyPath: "state", options: nil)
        checkBox.cell?.addObserver(self, forKeyPath: "state", options: .initial, context: textFieldContext)
        textField.addObserver(self, forKeyPath: "formatIsOk", options: .initial, context: textFieldContext)

        // +arrayWithObjects: stopped at a nil tag.
        let group: NSArray = tag.map { NSArray(objects: checkBox, textField, rmButton, $0) } ?? NSArray(objects: checkBox, textField, rmButton)
        viewGroups.add(group)
        resizeSubviews(withOldSize: frame.size)
    }

    @objc(removeTag:)
    public func removeTag(_ tag: DCMAttributeTag!) {
        guard let group = group(forObject: tag) else {
            return
        }

        (group.object(at: 0) as? NSControl)?.cell?.removeObserver(self, forKeyPath: "state")
        (group.object(at: 1) as? NSObject)?.removeObserver(self, forKeyPath: "formatIsOk")
        (group.object(at: 0) as? NSView)?.removeFromSuperview()
        (group.object(at: 1) as? NSView)?.removeFromSuperview()
        (group.object(at: 2) as? NSView)?.removeFromSuperview()

        viewGroups.remove(group)

        resizeSubviews(withOldSize: frame.size)
    }

    /// The context is the text field the observation was registered for.
    public override func observeValue(forKeyPath keyPath: String?, of obj: Any?,
                                      change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        assumeMainActor(context) { context in
            guard let context = context,
                  let textField = Unmanaged<AnyObject>.fromOpaque(context).takeUnretainedValue() as? N2TextField else {
                return
            }

            let checkBox = self.checkBox(forObject: textField)
            let highlighted = (checkBox?.state.rawValue ?? 0) != 0 && !textField.stringValue.isEmpty && !textField.formatIsOk
            textField.backgroundColor = highlighted ? NSColor(calibratedHue: NSColor.orange.hueComponent, saturation: 0.25, brightness: 1, alpha: 1) : NSColor.white
        }
    }

    @objc(observeTextDidChange:)
    func observeTextDidChange(_ notification: Notification) {
        let textField = notification.object as AnyObject?
        observeValue(forKeyPath: nil, of: nil, change: nil, context: textField.map { Unmanaged.passUnretained($0).toOpaque() })
    }

    @objc(checkBoxForObject:)
    public func checkBox(forObject object: Any!) -> NSButton! {
        return group(forObject: object)?.object(at: 0) as? NSButton
    }

    @objc(textFieldForObject:)
    public func textField(forObject object: Any!) -> N2TextField! {
        return group(forObject: object)?.object(at: 1) as? N2TextField
    }

    @objc(idealSize)
    public func idealSize() -> NSSize {
        let columnCount = self.columnCount(), rowCount = self.rowCount()
        var rC = Float(rowCount - 1)
        if rC < 0 { rC = 0 }
        var cC = Float(columnCount - 1)
        if cC < 0 { cC = 0 }

        return NSSize(width: cellSize.width * CGFloat(columnCount) + intercellSpacing.width * CGFloat(cC),
                      height: cellSize.height * CGFloat(rowCount) + intercellSpacing.height * CGFloat(rC))
    }

    public override func resizeSubviews(withOldSize oldSize: NSSize) {
        cellSize = NSSize(width: (frame.size.width - intercellSpacing.width * CGFloat(columnCount() - 1)) / 2, height: 17)
        for case let group as NSArray in viewGroups {
            repositionGroupViews(group)
        }
        repositionAddTagInterface()
    }
}
