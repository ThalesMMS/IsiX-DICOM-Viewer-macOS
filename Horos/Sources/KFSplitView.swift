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
//
// KFSplitView.m
// KFSplitView v. 1.3, 11/27/2004
// 
// Copyright (c) 2003-2004 Ken Ferry. Some rights reserved.
// http://homepage.mac.com/kenferry/software.html
//
// Other contributors: Kirk Baker, John Pannell
// 
// This work is licensed under a Creative Commons license:
// http://creativecommons.org/licenses/by-nc/1.0/
//
// Send me an email if you have any problems (after you've read what there is to read).
//
// You can reach me at kenferry at the domain mac.com.
// 
// Historical notices above are preserved for the replaced implementation and
// compatibility interface. The implementation below was written independently
// for this fork under LGPLv3; it does not translate the former layout engine.

import AppKit

@objc private protocol SplitDividerCallbacks {
    @objc(splitView:didDoubleClickInDivider:)
    optional func doubleClick(_ split: Any, divider: Int32)
    @objc(splitView:didFinishDragInDivider:)
    optional func finishedDrag(_ split: Any, divider: Int32)
}

@MainActor private var splitAutosaveOwners: [String: WeakSplitOwner] = [:]
private final class WeakSplitOwner {
    weak var view: KFSplitView?
    init(_ view: KFSplitView) { self.view = view }
}

@objc(KFSplitView)
public final class KFSplitView: NSSplitView {
    private var collapsed = Set<ObjectIdentifier>()
    private var dividers: [NSRect] = []
    // The share of the split each visible pane takes, the panes the shares are
    // for, and the lengths the last layout gave them. See adjustSubviews().
    private var shares: [CGFloat] = []
    private var sharedPanes: [ObjectIdentifier] = []
    private var laidOut: [CGFloat] = []
    private var savedName: String?
    private var resizing = false
    private weak var clientDelegate: NSSplitViewDelegate?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureFrameLayout()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureFrameLayout()
        if let state = coder.decodeObject(forKey: "HorosSplitPosition") {
            setPosition(fromPlistObject: state)
        }
    }

    public override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(plistObjectWithSavedPosition(), forKey: "HorosSplitPosition")
    }

    private func configureFrameLayout() {
        // PET-CT delegates copy frames between rows. AppKit's arranged-view
        // constraints would undo those frames on the next layout pass.
        arrangesAllSubviews = false
        for pane in arrangedSubviews { removeArrangedSubview(pane) }
    }

    public override func awakeFromNib() {
        MainActor.assumeIsolated {
            configureFrameLayout()
            kfRecalculateDividerRects()
        }
    }

    isolated deinit {
        if let name = savedName, splitAutosaveOwners[name]?.view === self {
            splitAutosaveOwners.removeValue(forKey: name)
        }
        if let delegate = clientDelegate {
            for name in Self.delegateNotifications {
                NotificationCenter.default.removeObserver(delegate, name: name, object: self)
            }
        }
    }

    private func length(_ rect: NSRect) -> CGFloat { isVertical ? rect.width : rect.height }
    private func origin(_ rect: NSRect) -> CGFloat { isVertical ? rect.minX : rect.minY }
    private func coordinate(_ point: NSPoint) -> CGFloat { isVertical ? point.x : point.y }
    private func rectangle(at position: CGFloat, length: CGFloat) -> NSRect {
        isVertical
            ? NSRect(x: position, y: bounds.minY, width: length, height: bounds.height)
            : NSRect(x: bounds.minX, y: position, width: bounds.width, height: length)
    }

    private func place(_ pane: NSView, at position: CGFloat, length: CGFloat) {
        // The split places its panes. A pane that also resizes itself with the
        // split - the rows of the PET-CT window are height sizable in the nib -
        // is given, between two layouts, the whole change of the split's
        // length, and the shares are then read from frames nobody chose: a
        // window that changes size by a lot at once, a few times, left a row
        // with no height.
        if pane.autoresizingMask != [] { pane.autoresizingMask = [] }
        if isSubviewCollapsed(pane) {
            pane.setFrameOrigin(NSPoint(x: 1_000_000, y: 1_000_000))
        } else {
            let rect = rectangle(at: position, length: max(0, length))
            if pane.frame != rect { pane.frame = rect; pane.needsDisplay = true }
        }
    }

    public override func isSubviewCollapsed(_ subview: NSView) -> Bool {
        collapsed.contains(ObjectIdentifier(subview))
    }

    @objc(setSubview:isCollapsed:)
    public func setSubview(_ subview: NSView, isCollapsed flag: Bool) {
        guard subviews.contains(subview), flag != isSubviewCollapsed(subview) else { return }
        if flag { collapsed.insert(ObjectIdentifier(subview)) }
        else { collapsed.remove(ObjectIdentifier(subview)) }
        NotificationCenter.default.post(name: Notification.Name(flag
            ? "KFSplitViewDidCollapseSubviewNotification" : "KFSplitViewDidExpandSubviewNotification"),
            object: self, userInfo: ["subview": subview])
    }

    public override func adjustSubviews() {
        guard !subviews.isEmpty else { dividers = []; return }
        var visible = subviews.indices.filter { !isSubviewCollapsed(subviews[$0]) }
        if visible.isEmpty {
            setSubview(subviews[0], isCollapsed: false)
            visible = [0]
        }
        let available = max(0, length(bounds) - CGFloat(subviews.count - 1) * dividerThickness)
        // The shares are taken from the frames only when something other than
        // this method set them: a divider moved, a saved position put back, a
        // delegate copying another row's frames, a pane collapsed or expanded.
        // Taking them from the frames the previous resize had rounded gave the
        // remainder of every step to the same pane: a window dragged smaller
        // and back ended with panes of other proportions, and a split that
        // passed through a few points of height lost them altogether.
        let panes = visible.map { ObjectIdentifier(subviews[$0]) }
        let lengths = visible.map { max(0, length(subviews[$0].frame)) }
        if panes != sharedPanes || lengths != laidOut {
            let total = lengths.reduce(0, +)
            shares = lengths.map { total > 0 ? $0 / total : 1 / CGFloat(lengths.count) }
            sharedPanes = panes
        }
        // Cumulative rounding gives every point to one pane, with no random
        // correction and no error carried from one pane to the next.
        var cumulative: CGFloat = 0
        var previous: CGFloat = 0
        var sizes = Array(repeating: CGFloat(0), count: subviews.count)
        for (offset, index) in visible.enumerated() {
            cumulative += shares[offset]
            let end = offset == visible.count - 1 ? available : min(available, max(previous, (available * cumulative).rounded()))
            sizes[index] = max(0, end - previous)
            previous = end
        }
        laidOut = visible.map { sizes[$0] }
        var cursor = origin(bounds)
        for (index, pane) in subviews.enumerated() {
            place(pane, at: cursor, length: sizes[index])
            cursor += sizes[index] + dividerThickness
        }
        kfRecalculateDividerRects()
    }

    public override func resizeSubviews(withOldSize oldBoundsSize: NSSize) {
        // Synchronized PET-CT rows can request another resize while the
        // notification is being delivered. Their frames are already copied.
        guard !resizing else { return }
        resizing = true
        defer { resizing = false }
        NotificationCenter.default.post(name: NSSplitView.willResizeSubviewsNotification, object: self)
        if let delegate = clientDelegate,
           delegate.responds(to: #selector(NSSplitViewDelegate.splitView(_:resizeSubviewsWithOldSize:))) {
            delegate.splitView?(self, resizeSubviewsWithOldSize: oldBoundsSize)
        } else { adjustSubviews() }
        for pane in subviews where isSubviewCollapsed(pane) {
            pane.setFrameOrigin(NSPoint(x: 1_000_000, y: 1_000_000))
        }
        kfRecalculateDividerRects()
        NotificationCenter.default.post(name: NSSplitView.didResizeSubviewsNotification, object: self)
        if let name = savedName { savePosition(usingName: name) }
    }

    @objc(kfRecalculateDividerRects)
    public func kfRecalculateDividerRects() {
        let live = Set(subviews.map(ObjectIdentifier.init))
        collapsed.formIntersection(live)
        dividers.removeAll(keepingCapacity: true)
        var cursor = origin(bounds)
        for (index, pane) in subviews.enumerated() {
            if !isSubviewCollapsed(pane) { cursor += length(pane.frame) }
            if index + 1 < subviews.count {
                dividers.append(rectangle(at: cursor, length: dividerThickness))
                cursor += dividerThickness
            }
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    public override func draw(_ dirtyRect: NSRect) {
        for divider in dividers where divider.intersects(dirtyRect) { drawDivider(in: divider) }
    }

    public override func resetCursorRects() {
        let cursor = isVertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown
        for divider in dividers { addCursorRect(divider, cursor: cursor) }
    }

    public override var isVertical: Bool {
        get { super.isVertical }
        set { super.isVertical = newValue; kfRecalculateDividerRects() }
    }

    private static let delegateNotifications: [Notification.Name] = [
        NSSplitView.willResizeSubviewsNotification, NSSplitView.didResizeSubviewsNotification,
        Notification.Name("KFSplitViewDidCollapseSubviewNotification"),
        Notification.Name("KFSplitViewDidExpandSubviewNotification")
    ]

    public override weak var delegate: NSSplitViewDelegate? {
        get { clientDelegate }
        set {
            if let old = clientDelegate {
                for name in Self.delegateNotifications {
                    NotificationCenter.default.removeObserver(old, name: name, object: self)
                }
            }
            clientDelegate = newValue
            let selectors = ["splitViewWillResizeSubviews:", "splitViewDidResizeSubviews:",
                             "splitViewDidCollapseSubview:", "splitViewDidExpandSubview:"]
            if let clientDelegate {
                for (name, selector) in zip(Self.delegateNotifications, selectors) {
                    let action = NSSelectorFromString(selector)
                    if clientDelegate.responds(to: action) {
                        NotificationCenter.default.addObserver(clientDelegate, selector: action, name: name, object: self)
                    }
                }
            }
        }
    }

    private var callbacks: SplitDividerCallbacks? {
        clientDelegate.map { unsafeBitCast($0 as AnyObject, to: SplitDividerCallbacks.self) }
    }

    // Frame layout remains authoritative, including when a plugin positions a
    // divider programmatically. Limits and collapse use the same path as drag.
    public override func setPosition(_ position: CGFloat, ofDividerAt index: Int) {
        moveDivider(index, to: position)
    }

    private func moveDivider(_ index: Int, to proposed: CGFloat) {
        guard proposed.isFinite, index >= 0, index < dividers.count,
              index + 1 < subviews.count else { return }
        let before = subviews[index], after = subviews[index + 1]
        let start = isSubviewCollapsed(before) ? origin(dividers[index]) : origin(before.frame)
        let end = isSubviewCollapsed(after) ? origin(dividers[index]) + dividerThickness
            : origin(after.frame) + length(after.frame)
        let upper = max(start, end - dividerThickness)
        var minimum = clientDelegate?.splitView?(self, constrainMinCoordinate: start, ofSubviewAt: index) ?? start
        var maximum = clientDelegate?.splitView?(self, constrainMaxCoordinate: upper, ofSubviewAt: index) ?? upper
        minimum = min(upper, max(start, minimum.isFinite ? minimum : start))
        maximum = max(start, min(upper, maximum.isFinite ? maximum : upper))
        if minimum > maximum { minimum = start; maximum = upper }
        let candidate = clientDelegate?.splitView?(self, constrainSplitPosition: proposed, ofSubviewAt: index) ?? proposed
        guard candidate.isFinite else { return }
        let collapseBefore = (clientDelegate?.splitView?(self, canCollapseSubview: before) ?? false)
            && candidate < (start + minimum) / 2
        let collapseAfter = !collapseBefore && (clientDelegate?.splitView?(self, canCollapseSubview: after) ?? false)
            && candidate > (upper + maximum) / 2
        let target = collapseBefore ? start : collapseAfter ? upper : min(maximum, max(minimum, candidate))
        let beforeFrame = rectangle(at: start, length: target - start)
        let afterFrame = rectangle(at: target + dividerThickness, length: end - target - dividerThickness)
        if isSubviewCollapsed(before) == collapseBefore && isSubviewCollapsed(after) == collapseAfter
            && (collapseBefore || before.frame == beforeFrame) && (collapseAfter || after.frame == afterFrame) { return }
        NotificationCenter.default.post(name: NSSplitView.willResizeSubviewsNotification, object: self)
        setSubview(before, isCollapsed: collapseBefore)
        setSubview(after, isCollapsed: collapseAfter)
        place(before, at: start, length: target - start)
        place(after, at: target + dividerThickness, length: end - target - dividerThickness)
        kfRecalculateDividerRects()
        NotificationCenter.default.post(name: NSSplitView.didResizeSubviewsNotification, object: self)
        if let name = savedName { savePosition(usingName: name) }
    }

    public override func mouseDown(with event: NSEvent) {
        kfRecalculateDividerRects()
        let point = convert(event.locationInWindow, from: nil)
        guard let index = dividers.firstIndex(where: { $0.contains(point) }) else { return }
        if event.clickCount > 1,
           clientDelegate?.responds(to: NSSelectorFromString("splitView:didDoubleClickInDivider:")) == true {
            callbacks?.doubleClick?(self, divider: Int32(index))
            return
        }
        let grabOffset = coordinate(point) - origin(dividers[index])
        while let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                        until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            moveDivider(index, to: coordinate(convert(next.locationInWindow, from: nil)) - grabOffset)
            if next.type == .leftMouseUp { break }
        }
        callbacks?.finishedDrag?(self, divider: Int32(index))
    }

    @objc(removePositionUsingName:)
    public class func removePosition(usingName name: String) {
        UserDefaults.standard.removeObject(forKey: "KFSplitView Position " + name)
    }

    @objc(savePositionUsingName:)
    public func savePosition(usingName name: String) {
        UserDefaults.standard.set(plistObjectWithSavedPosition(), forKey: "KFSplitView Position " + name)
    }

    @objc(setPositionUsingName:)
    @discardableResult public func setPosition(usingName name: String) -> Bool {
        guard let state = UserDefaults.standard.object(forKey: "KFSplitView Position " + name),
              validState(state) != nil else { return false }
        setPosition(fromPlistObject: state)
        return true
    }

    @objc(setPositionAutosaveName:)
    @discardableResult public func setPositionAutosaveName(_ name: String?) -> Bool {
        let name = name.flatMap { $0.isEmpty ? nil : $0 }
        if let name, let owner = splitAutosaveOwners[name]?.view, owner !== self { return false }
        if let old = savedName, splitAutosaveOwners[old]?.view === self { splitAutosaveOwners.removeValue(forKey: old) }
        savedName = name
        if let name {
            splitAutosaveOwners[name] = WeakSplitOwner(self)
            setPosition(usingName: name)
        }
        return true
    }

    @objc(positionAutosaveName)
    public func positionAutosaveName() -> String? { savedName }

    private func validState(_ object: Any) -> (Bool, [[String: Any]])? {
        guard let state = object as? [String: Any], (state["version"] as? NSNumber)?.intValue == 2,
              let vertical = state["isVertical"] as? NSNumber,
              let panes = state["subviews"] as? [[String: Any]] else { return nil }
        for pane in panes {
            guard let text = pane["frame"] as? String, pane["collapsed"] is NSNumber else { return nil }
            let rect = NSRectFromString(text)
            guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy({ $0.isFinite }),
                  rect.width >= 0, rect.height >= 0 else { return nil }
        }
        return (vertical.boolValue, panes)
    }

    @objc(setPositionFromPlistObject:)
    public func setPosition(fromPlistObject plistObject: Any?) {
        guard let object = plistObject, let (vertical, records) = validState(object) else { return }
        isVertical = vertical
        for (pane, record) in zip(subviews, records) {
            pane.frame = NSRectFromString(record["frame"] as! String)
            setSubview(pane, isCollapsed: (record["collapsed"] as! NSNumber).boolValue)
        }
        resizeSubviews(withOldSize: bounds.size)
    }

    @objc(plistObjectWithSavedPosition)
    public func plistObjectWithSavedPosition() -> Any {
        ["version": 2, "isVertical": isVertical, "subviews": subviews.map { pane -> [String: Any] in
            ["frame": NSStringFromRect(pane.frame), "collapsed": isSubviewCollapsed(pane)]
        }] as [String: Any]
    }
}
