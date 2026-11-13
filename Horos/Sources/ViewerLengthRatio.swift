//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import IsiXROI

// ROI > Ratio of Two Lengths: one Length divided by another, shown in a text
// ROI that follows them. An Evans index, an Insall-Salvati or a
// Caton-Deschamps ratio are measured that way.
//
// The two Lengths are the two selected ones, on one image or on two images of
// the series; the one selected first is the numerator. The label is a text
// ROI like any other, saved with the ROIs. Each Length gets an identifier and
// the label names its two (ROIRatioLink, archived with the ROI): that tie,
// and not a group, is what the label follows, so that a Length can be in two
// ratios and ungrouping changes nothing. ROIRatioLabels writes the label
// again when one of its Lengths changes, and removes it with a Length that
// is deleted. The rules are IsiXROI's (ROILengthRatio).

/// A Length of a viewer's time point, and the index of the image it is on.
@MainActor struct ViewerRatioMember {
    let roi: ROI
    let slice: Int
}

@MainActor enum ViewerLengthRatio {

    // MARK: - Lengths

    /// What `roi` measures, when it is a Length: in cm, or in pixels on an
    /// image without pixel spacing. A Length between images measures the
    /// distance between its ends in the patient.
    static func measured(_ roi: ROI) -> ROILengthRatio.Length? {
        guard roi.type == .tMesure else { return nil }
        if let physical = roi as? HorosVolumeLengthROI {
            guard let payload = physical.volumeLength, HorosVolumeLengthROI.validPayload(payload) else { return nil }
            return ROILengthRatio.Length(value: physical.distanceMM / 10, unit: .centimetre)
        }
        guard (roi.points?.count ?? 0) >= 2 else { return nil }
        return ROILengthRatio.Length(value: Double(roi.mesureLength(nil)),
                                     unit: roi.pixelSpacingX != 0 && roi.pixelSpacingY != 0 ? .centimetre : .pixel)
    }

    /// A length as the label of its Length writes it.
    static func text(of length: ROILengthRatio.Length) -> String {
        length.unit == .centimetre ? LengthPresentation.string(centimetres: length.value) : LengthPresentation.string(pixels: length.value)
    }

    /// The text of the label of `numerator` over `denominator`, as they are
    /// now; nil when one of them measures nothing.
    static func labelText(numerator: ROI, denominator: ROI) -> String? {
        guard let n = measured(numerator), let d = measured(denominator) else { return nil }
        return ROILengthRatio.labelText(numerator: text(of: n), denominator: text(of: d), ratio: ROILengthRatio.value(of: n, over: d))
    }

    /// The Lengths of the time point `movie`, in the order of the images and,
    /// on each, of its list. One shown on several images (a Length between
    /// images) is there once, on the image it was made on.
    static func lengths(of viewer: ViewerController, movie: Int) -> [ViewerRatioMember] {
        guard let slices = ViewerROISlices(viewer, movie: movie) else { return [] }
        var seen = Set<ObjectIdentifier>()
        var members: [ViewerRatioMember] = []
        for slice in 0..<slices.count {
            for roi in slices.rois(at: slice) where roi.type == .tMesure {
                if (roi.isAliased || roi is HorosVolumeLengthROI) && slice != Int(roi.originalIndexForAlias) { continue }
                if seen.insert(ObjectIdentifier(roi)).inserted { members.append(ViewerRatioMember(roi: roi, slice: slice)) }
            }
        }
        return members
    }

    // MARK: - The command

    /// The two selected Lengths the command divides, the numerator first
    /// (ROILengthRatio.pair); nil when the selection does not name two.
    static func pair(in viewer: ViewerController) -> (numerator: ViewerRatioMember, denominator: ViewerRatioMember)? {
        let movie = Int(viewer.horos_curMovieIndex)
        let shown = ViewerShownROIs(viewer).rois
        let selected = lengths(of: viewer, movie: movie).filter { ROISelection.isSelected($0.roi.roImode) }
        let candidates = selected.map { member in
            ROILengthRatio.Selected(isShown: shown.contains { $0 === member.roi }, order: ROIRatioLabels.shared.selectionOrder(of: member.roi))
        }
        guard let pair = ROILengthRatio.pair(of: candidates) else { return nil }
        return (selected[pair.numerator], selected[pair.denominator])
    }

    /// Whether `numerator` over `denominator` is a ratio: two Lengths in one
    /// unit, the second longer than nothing.
    static func isRatio(_ numerator: ROI, over denominator: ROI) -> Bool {
        guard numerator !== denominator, let n = measured(numerator), let d = measured(denominator) else { return false }
        return ROILengthRatio.value(of: n, over: d) != nil
    }

    /// Whether the command applies: the menu item's enablement.
    static func canAdd(in viewer: ViewerController) -> Bool {
        guard let pair = pair(in: viewer) else { return false }
        return isRatio(pair.numerator.roi, over: pair.denominator.roi)
    }

    /// Adds the label of the ratio of the two selected Lengths.
    static func add(in viewer: ViewerController) {
        guard let pair = pair(in: viewer), add(numerator: pair.numerator, denominator: pair.denominator, in: viewer) != nil else {
            NSSound.beep()
            return
        }
    }

    /// Adds the label of `numerator` over `denominator`, two Lengths of the
    /// time point shown, as one undo step: on the image shown when one of the
    /// two is on it, otherwise on the numerator's. Answers the label; the one
    /// already there when that image has the label of this ratio; nil when
    /// the two are no ratio.
    @discardableResult
    static func add(numerator: ViewerRatioMember, denominator: ViewerRatioMember, in viewer: ViewerController) -> ROI? {
        guard isRatio(numerator.roi, over: denominator.roi), let view = viewer.horos_imageView else { return nil }
        let movie = Int(viewer.horos_curMovieIndex)
        guard let slices = ViewerROISlices(viewer, movie: movie) else { return nil }

        let shownIndex = Int(view.curImage)
        let shown = slices.rois(at: shownIndex)
        var anchor = numerator, slice = numerator.slice
        if shown.contains(where: { $0 === numerator.roi }) {
            slice = shownIndex
        } else if shown.contains(where: { $0 === denominator.roi }) {
            anchor = denominator
            slice = shownIndex
        }
        guard let list = slices.list(at: slice), let pix = viewer.horos_pixList(at: movie)?.object(at: slice) as? DCMPix else { return nil }

        if let n = numerator.roi.ratioLink.measureIdentifier, let d = denominator.roi.ratioLink.measureIdentifier,
           let existing = slices.rois(at: slice).first(where: { $0.ratioLink == .label(numerator: n, denominator: d) }) {
            return existing
        }

        viewer.add(toUndoQueue: "roi")
        let link = ROIRatioLink.label(numerator: identifier(of: numerator.roi), denominator: identifier(of: denominator.roi))
        guard let label = ROI(type: .tText, Float(pix.pixelSpacingX), Float(pix.pixelSpacingY),
                              DCMPix.originCorrected(accordingToOrientation: pix)) else { return nil }
        label.ratioLink = link
        label.rect = NSRect(origin: labelOrigin(beside: anchor.roi, on: pix, clearOf: slices.rois(at: slice)), size: .zero)
        label.pix = pix
        view.roiSet(label)
        label.name = labelText(numerator: numerator.roi, denominator: denominator.roi)
        viewerArrayAdd(label, to: list)
        ROIEventEmitter.added(label, to: view, slice: Int32(slice))
        ROIEventEmitter.changed(label)
        view.needsDisplay = true
        return label
    }

    /// The identifier of a Length, given to it now when it has none.
    private static func identifier(of roi: ROI) -> String {
        if let identifier = roi.ratioLink.measureIdentifier { return identifier }
        let identifier = ROIRatioLink.newIdentifier()
        roi.ratioLink = .measure(identifier)
        return identifier
    }

    /// Where the label goes: under the lower end of `roi`, a little below it,
    /// inside the image, and further down while a text of `others` is already
    /// there (a second ratio of the same Length). The middle of the image for
    /// a Length without points on it.
    private static func labelOrigin(beside roi: ROI, on pix: DCMPix, clearOf others: [ROI]) -> NSPoint {
        let width = CGFloat(pix.pwidth), height = CGFloat(pix.pheight)
        let points = (roi.points as? [Any] ?? []).compactMap { ($0 as? MyPoint)?.point }
        let gap = max(height * 0.04, 6)
        var origin = NSPoint(x: width / 2, y: height / 2)
        if let lowest = points.max(by: { $0.y < $1.y }) {
            origin = NSPoint(x: min(max(lowest.x, 0), max(width - 1, 0)), y: min(lowest.y + gap, max(height - gap, 0)))
        }
        let texts = others.filter { $0.type == .tText }.map(\.rect.origin)
        while origin.y + gap <= height - gap, texts.contains(where: { abs($0.x - origin.x) < 1 && abs($0.y - origin.y) < gap / 2 }) {
            origin.y += gap
        }
        return origin
    }

    // MARK: - The labels

    /// A label of a viewer, the list it is in and the two Lengths it means;
    /// nil for one whose Length is not in the time point.
    struct Label {
        let roi: ROI
        let list: NSMutableArray
        let numerator: ROI?
        let denominator: ROI?
    }

    /// The labels of the time point `movie`, each with the Lengths it means
    /// there: those that use the Length `identifier`, or all of them. A label
    /// means the Lengths it was last found to mean, while they are in the
    /// time point with their identifiers; otherwise those ROILengthRatio.resolve
    /// names, as when the study has just been opened.
    static func labels(of viewer: ViewerController, movie: Int, using identifier: String? = nil) -> [Label] {
        guard let slices = ViewerROISlices(viewer, movie: movie) else { return [] }
        var found: [(roi: ROI, slice: Int, numerator: String, denominator: String)] = []
        var measured: [ROI] = [], measures: [ROILengthRatio.Measure] = []
        for slice in 0..<slices.count {
            for roi in slices.rois(at: slice) {
                switch roi.ratioLink {
                case .none:
                    continue
                case let .measure(own):
                    guard roi.type == .tMesure else { continue }
                    measured.append(roi)
                    measures.append(ROILengthRatio.Measure(identifier: own, slice: slice))
                case let .label(numerator, denominator):
                    guard roi.type == .tText, identifier == nil || numerator == identifier || denominator == identifier else { continue }
                    found.append((roi, slice, numerator, denominator))
                }
            }
        }
        var labels: [Label] = []
        for label in found {
            guard let list = slices.list(at: label.slice) else { continue }
            let known = ROIRatioLabels.shared.lengths(of: label.roi)
            var lengths: [ROI?] = []
            for (identifier, known) in [(label.numerator, known.numerator), (label.denominator, known.denominator)] {
                if let known, known.ratioLink.measureIdentifier == identifier, measured.contains(where: { $0 === known }) {
                    lengths.append(known)
                } else {
                    lengths.append(ROILengthRatio.resolve(identifier, from: label.slice, among: measures).map { measured[$0] })
                }
            }
            ROIRatioLabels.shared.remember(numerator: lengths[0], denominator: lengths[1], of: label.roi)
            labels.append(Label(roi: label.roi, list: list, numerator: lengths[0], denominator: lengths[1]))
        }
        return labels
    }

    /// Writes again the labels of `viewer` that use the Length `identifier`,
    /// or all of them, from their Lengths as they are now. A label whose
    /// Length is not there keeps its text.
    static func refresh(in viewer: ViewerController, using identifier: String? = nil) {
        var changed = false
        for movie in 0..<max(Int(viewer.horos_maxMovieIndex), 1) {
            for label in labels(of: viewer, movie: movie, using: identifier) {
                guard let numerator = label.numerator, let denominator = label.denominator,
                      let text = labelText(numerator: numerator, denominator: denominator), label.roi.name != text else { continue }
                label.roi.name = text
                changed = true
            }
        }
        if changed { viewer.horos_imageView?.needsDisplay = true }
    }

    // MARK: - The menu

    static let action = #selector(ViewerStudyCommands.ratioOfSelectedLengths(_:))

    /// The object of the main menu that runs the command, which enables it
    /// by what it can do; nil until the menu item is installed.
    private(set) static var commands: ViewerStudyCommands?

    /// Adds the command to the ROI menu, after Create Points Between Two
    /// Points and sent to the same object, once.
    static func installMenuItem() {
        var owner: NSMenu?
        if ViewerROIInterchange.findItem(NSApp.mainMenu, action, &owner) != nil { return }
        guard let anchor = ViewerROIInterchange.findItem(NSApp.mainMenu, #selector(ViewerStudyCommands.createPointsBetweenTwoPoints(_:)), &owner),
              let owner, let target = anchor.target as? ViewerStudyCommands else {
            NSLog("Ratio of two lengths: its place in the ROI menu was not found; the item is not installed")
            return
        }
        commands = target
        let item = menuItem()
        item.keyEquivalent = "/"
        item.keyEquivalentModifierMask = [.command, .option]
        owner.insertItem(item, at: owner.index(of: anchor) + 1)
    }

    /// An item for the command, for a menu: sent to the object that runs it,
    /// which hides or dims it when the selection names no ratio.
    static func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = commands
        return item
    }

    static var title: String { NSLocalizedString("Ratio of Two Lengths", comment: "ROI menu: the ratio of the two selected Length ROIs") }
}

/// Keeps the labels of ratios true to their Lengths, in every 2D viewer.
///
/// A Length that changes has its labels written again; one that is deleted
/// takes its labels with it, since a ratio without one of its measures says
/// nothing that can be checked on the image. It also remembers in which order
/// the Lengths were selected, which the command asks for.
///
/// It listens to the ROI notifications, as the windows do, and does its work
/// only for a Length that carries an identifier: nothing is added to the
/// drawing of the ROIs.
@MainActor
@objc(HorosROIRatioLabels)
public final class ROIRatioLabels: NSObject {

    static let shared = ROIRatioLabels()

    /// Starts following the ROIs. Called once at launch.
    @objc public static func start() {
        _ = shared
    }

    /// When each selected Length was selected, counted from the launch.
    private let selected = NSMapTable<ROI, NSNumber>.weakToStrongObjects()
    /// The two Lengths each label was last found to mean. Copies of a Length
    /// carry its identifier: a label goes on meaning the one it meant.
    private let meant = NSMapTable<ROI, Lengths>.weakToStrongObjects()

    private final class Lengths {
        weak var numerator: ROI?
        weak var denominator: ROI?
    }
    private var selections = 0
    private var updating = false

    private override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(roiChanged(_:)), name: .OsirixROIChange, object: nil)
        center.addObserver(self, selector: #selector(roiWillBeRemoved(_:)), name: .OsirixRemoveROI, object: nil)
        center.addObserver(self, selector: #selector(lengthPresentationChanged(_:)),
                           name: Notification.Name(LengthPresentation.changedNotification), object: nil)
    }

    /// When the selected Length `roi` was selected: smaller is earlier. nil
    /// for one that was never seen to be selected.
    func selectionOrder(of roi: ROI) -> Int? {
        selected.object(forKey: roi)?.intValue
    }

    /// The Lengths the label `roi` was last found to mean, while they exist.
    func lengths(of roi: ROI) -> (numerator: ROI?, denominator: ROI?) {
        let lengths = meant.object(forKey: roi)
        return (lengths?.numerator, lengths?.denominator)
    }

    func remember(numerator: ROI?, denominator: ROI?, of roi: ROI) {
        let lengths = meant.object(forKey: roi) ?? Lengths()
        lengths.numerator = numerator
        lengths.denominator = denominator
        meant.setObject(lengths, forKey: roi)
    }

    private var viewers: [ViewerController] {
        ((ViewerController.getDisplayed2DViewers() as NSArray?) ?? NSArray()).compactMap { $0 as? ViewerController }
            .filter { !$0.windowWillClose() }
    }

    // MARK: Notifications

    @objc private func roiChanged(_ note: Notification) {
        guard let roi = note.object as? ROI, roi.type == .tMesure else { return }
        // Selecting a ROI changes its mode, which it announces as a change.
        if ROISelection.isSelected(roi.roImode) {
            if selected.object(forKey: roi) == nil {
                selections += 1
                selected.setObject(NSNumber(value: selections), forKey: roi)
            }
        } else {
            selected.removeObject(forKey: roi)
        }

        guard !updating, let identifier = roi.ratioLink.measureIdentifier else { return }
        updating = true
        defer { updating = false }
        for viewer in viewers { ViewerLengthRatio.refresh(in: viewer, using: identifier) }
    }

    /// A ROI is about to leave its list. The labels that mean it now are
    /// removed once it has left, unless it is then in another list of its
    /// viewer (moved, not deleted). A ROI being deallocated announces the
    /// same, when it is in no list: no label means it then, and nothing is
    /// done.
    @objc private func roiWillBeRemoved(_ note: Notification) {
        guard !updating, let roi = note.object as? ROI, roi.type == .tMesure,
              let identifier = roi.ratioLink.measureIdentifier else { return }
        var orphans: [(label: ROI, viewer: ViewerController)] = []
        for viewer in viewers {
            for movie in 0..<max(Int(viewer.horos_maxMovieIndex), 1) {
                for label in ViewerLengthRatio.labels(of: viewer, movie: movie, using: identifier)
                where label.numerator === roi || label.denominator === roi {
                    orphans.append((label.roi, viewer))
                }
            }
        }
        guard !orphans.isEmpty else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.removeOrphans(orphans, of: roi) }
        }
    }

    private func removeOrphans(_ orphans: [(label: ROI, viewer: ViewerController)], of length: ROI) {
        updating = true
        defer { updating = false }
        for orphan in orphans where !orphan.viewer.windowWillClose() {
            var removed = false
            for movie in 0..<max(Int(orphan.viewer.horos_maxMovieIndex), 1) {
                guard let slices = ViewerROISlices(orphan.viewer, movie: movie),
                      !slices.all.contains(where: { $0.contains { $0 === length } }) else { continue }
                for slice in 0..<slices.count {
                    guard let list = slices.list(at: slice), list.indexOfObjectIdentical(to: orphan.label) != NSNotFound else { continue }
                    ROIEventEmitter.willRemove(orphan.label)
                    list.removeObject(identicalTo: orphan.label)
                    removed = true
                }
            }
            if removed {
                ROIEventEmitter.removedFromList()
                orphan.viewer.horos_imageView?.needsDisplay = true
            }
        }
    }

    /// The labels repeat the lengths as their Lengths write them: with
    /// another unit or number of decimals, they are written again.
    @objc private func lengthPresentationChanged(_ note: Notification) {
        guard !updating else { return }
        updating = true
        defer { updating = false }
        for viewer in viewers { ViewerLengthRatio.refresh(in: viewer) }
    }
}
