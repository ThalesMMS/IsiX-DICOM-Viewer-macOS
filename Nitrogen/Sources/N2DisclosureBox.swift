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

/// A box whose title is a disclosure triangle that shows and hides its content.
///
/// Implemented in Swift since #709: the Objective-C name, the selectors and
/// `<Horos/N2DisclosureBox.h>` are those of the former class. The notification
/// names stay in N2DisclosureBox+CAPI.m.
///
/// The former class redeclared NSBox's `titleCell` as a read-write
/// N2DisclosureButtonCell whose getter returned `self.titleCell`, that is,
/// called itself, and NSBox has no `-setTitleCell:`: `-initWithTitle:content:`
/// never returned. NSBox shows its own title cell in an NSTextField, which
/// raises on a button cell, so the box now holds the disclosure cell and
/// draws it itself, and NSBox keeps its title cell with an empty title (#746).
@objc(N2DisclosureBox)
open class N2DisclosureBox: NSBox {
    private var showingExpanded = false
    @IBOutlet public var _content: NSView?
    /// The title cell, as the Objective-C code messaged it.
    private var disclosureCell = N2DisclosureButtonCell()

    @objc(initWithTitle:content:)
    public init(title: String?, content: NSView?) {
        super.init(frame: .zero)

        // NSBox
        titlePosition = .atTop
        // Primary boxes draw their standard border; borderType only affected
        // the deprecated old-style box and never configured this box.
        boxType = .primary
        autoresizesSubviews = true

        setUpDisclosureCell(title: title ?? "")

        _content = content
        NotificationCenter.default.addObserver(self, selector: #selector(contentViewFrameDidChange(_:)), name: NSView.frameDidChangeNotification, object: content)
        setFrameFromContentFrame(.zero)
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpDisclosureCell(title: super.title)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpDisclosureCell(title: super.title)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// The disclosure cell takes the title, and NSBox's own title cell, which
    /// still sets the room above the border, shows nothing (#746).
    private func setUpDisclosureCell(title: String) {
        disclosureCell.title = title
        disclosureCell.state = .off
        disclosureCell.target = self
        disclosureCell.action = #selector(toggle(_:))
        super.title = ""
    }

    open override func mouseDown(with event: NSEvent) {
        if NSPointInRect(event.locationInWindow, convert(titleRect, to: nil)) {
            disclosureCell.trackMouse(with: event, in: titleRect, of: self, untilMouseUp: true)
        } else {
            super.mouseDown(with: event)
        }
    }

    @objc open var enabled: Bool {
        get { disclosureCell.isEnabled }
        set { disclosureCell.isEnabled = newValue }
    }

    @objc open func isExpanded() -> Bool {
        disclosureCell.state == .on
    }

    /// N2DisclosureButtonCell in the former header: the box's disclosure cell,
    /// not NSBox's title cell (see the class comment).
    open override var titleCell: Any {
        get { disclosureCell }
        set {
            disclosureCell = newValue as! N2DisclosureButtonCell
            needsDisplay = true
        }
    }

    /// The disclosure triangle and its title, where NSBox puts its own title.
    open override var titleRect: NSRect {
        let rect = super.titleRect
        let width = disclosureCell.cellSize.width + disclosureCell.textSize().width
        return NSRect(x: rect.origin.x, y: rect.origin.y, width: width.rounded(.up), height: rect.size.height)
    }

    open override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // The cell draws its title on the right of the triangle.
        let rect = titleRect
        let size = disclosureCell.cellSize
        disclosureCell.draw(withFrame: NSRect(x: rect.origin.x, y: rect.midY - size.height / 2, width: size.width, height: size.height), in: self)
    }

    @objc(toggle:) open func toggle(_ sender: Any?) {
        if isExpanded() {
            expand(sender)
        } else {
            collapse(sender)
        }
        NotificationCenter.default.post(name: .N2DisclosureBoxDidToggle, object: self)
    }

    @objc(expand:) open func expand(_ sender: Any?) {
        if showingExpanded { return }
        NotificationCenter.default.post(name: .N2DisclosureBoxWillExpand, object: self)
        showingExpanded = true

        setFrameFromContentFrame(_content?.frame ?? .zero)
        if let content = _content {
            addSubview(content)
        }

        disclosureCell.state = .on
        NotificationCenter.default.post(name: .N2DisclosureBoxDidExpand, object: self)
    }

    @objc(collapse:) open func collapse(_ sender: Any?) {
        if !showingExpanded { return }
        showingExpanded = false

        _content?.removeFromSuperview()
        setFrameFromContentFrame(.zero)

        disclosureCell.state = .off
        NotificationCenter.default.post(name: .N2DisclosureBoxDidCollapse, object: self)
    }

    @objc(contentViewFrameDidChange:) open func contentViewFrameDidChange(_ notification: Notification) {
        setFrameFromContentFrame(_content?.frame ?? .zero)
    }

    open override func setFrameFromContentFrame(_ contentFrame: NSRect) {
        let margins = contentViewMargins
        let size = NSSize(width: contentFrame.size.width + margins.width * 2,
                          height: contentFrame.size.height + disclosureCell.textSize().height + margins.height * 2)
        if size != frame.size {
            setFrameSize(size)
        }
    }

    open override func resizeSubviews(withOldSize oldBoundsSize: NSSize) {
        super.resizeSubviews(withOldSize: oldBoundsSize)
        //if isExpanded() { _content.setFrameSize(...) }
        disclosureCell.calcDrawInfo(frame)
    }

    open override var title: String {
        get { disclosureCell.title }
        set {
            disclosureCell.title = newValue
            disclosureCell.alternateTitle = newValue
            needsDisplay = true
        }
    }

    /// Called by the layouts through `respondsToSelector:` (N2CellDescriptor).
    @objc(optimalSizeForWidth:) open func optimalSize(forWidth width: CGFloat) -> NSSize {
        var size = frame.size
        size.width = width
        return NSSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
    }

    /// Called by -[N2View formatSubview:] through `performSelector:`.
    /// +[NSArray arrayWithObject:nil] raised; so does the unwrapping.
    @objc open func additionalSubviews() -> [NSView] {
        [_content!]
    }
}
