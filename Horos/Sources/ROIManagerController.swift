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

/// The checks of each ROI: shown, locked, selectable.
private enum ROIManagerCheck: String {
    case visible, locked, selectable
}

/// The values a background volume needs of one slice of a group.
private struct ROIManagerVolumeSlice: Sendable {
    let area: Double
    let origin: (Double, Double, Double)
    let normal: (Double, Double, Double)
    let count: Int
    let spacing: Double
}

/// Window Controller for ROI management
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/ROIManagerController.h> are those of the former class.
///
/// As before, the controller owns itself while its window is open: code that
/// makes one does not release it, and -windowWillClose: autoreleases it.
///
/// The window lists the ROIs of the slice on screen or of the whole series,
/// grouped by name (ROIManagerModel), filtered by text and by state, with an
/// inspector for the selected ROIs on the right. It reads the viewer only
/// when it is visible, and once for a burst of changes: a reslice or a plugin
/// import changes thousands of ROIs. Volumes are computed off the main thread
/// and areas are kept per ROI until it changes.
@objc(ROIManagerController)
public final class ROIManagerController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate,
                                         NSMenuDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    /// Not retained, as before. `unowned(unsafe)` and not `weak`: the viewer
    /// is compared by identity with the object of its close notification.
    private unowned(unsafe) var viewer: ViewerController?
    /// The xib's table; the window shows `outline` in its place.
    @IBOutlet var tableView: NSTableView!
    /// YES from -windowWillClose: on, as the flag of OSIWindowController: the
    /// lookups by nib name that reuse this window skip it, since its
    /// -windowWillClose: autoreleased it.
    @objc(windowWillClose) public private(set) var closing = false

    static let scopeDefaultsKey = "ROIManagerScope"

    private var outline: NSOutlineView!
    private var scopeControl: NSSegmentedControl!
    private var selectedOnlyButton: NSButton!
    private var visibleOnlyButton: NSButton!
    private var lockedOnlyButton: NSButton!
    private var groupButton: NSButton!
    private var searchField: NSSearchField!
    private var summaryLabel: NSTextField!
    private var split: NSSplitView!
    private var inspector: NSView!
    private var inspectorTitle: NSTextField!
    private var nameField: NSTextField!
    private var colorWell: NSColorWell!
    private var opacitySlider: NSSlider!
    private var thicknessSlider: NSSlider!
    private var visibleCheck: NSButton!
    private var lockedCheck: NSButton!
    private var selectableCheck: NSButton!
    private var commentsView: NSTextView!
    private var infoButton: NSButton!

    private var items: [AnyObject] = []
    private var scope = ROIManagerScope.slice
    private var filter = ROIManagerFilter()
    private var groupByName = true
    private var expandedNames = Set<String>()
    private let coalescer = ROIManagerCoalescer()
    private var syncingSelection = false
    /// A ROI the viewer selected, to show once the list is rebuilt.
    private weak var revealROI: ROI?
    /// cm² of each ROI, until it changes.
    private let areas = NSMapTable<ROI, NSNumber>.weakToStrongObjects()
    /// cm³ of each group, by name, for the current list; NaN while computed.
    private var volumes: [String: Double] = [:]
    private var volumeGeneration = 0

    /// Overridden so that -initWithWindowNibName: is inherited, unchanged.
    public override init(window: NSWindow?) {
        super.init(window: window)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// Default initializer
    @objc(initWithViewer:)
    public convenience init(viewer v: ViewerController!) {
        self.init(windowNibName: "ROIManager")
        viewer = nil
        scope = ROIManagerScope(rawValue: UserDefaults.standard.integer(forKey: Self.scopeDefaultsKey)) ?? .slice

        window?.setFrameAutosaveName("ROIManagerWindow")

        // register to notification
        let nc = NotificationCenter.default
        nc.addObserver(self,
                       selector: #selector(CloseViewerNotification(_:)),
                       name: NSNotification.Name.OsirixCloseViewer,
                       object: nil)
        nc.addObserver(self,
                       selector: #selector(roiListModification(_:)),
                       name: NSNotification.Name.OsirixROIChange,
                       object: nil)
        nc.addObserver(self,
                       selector: #selector(fireUpdate(_:)),
                       name: NSNotification.Name.OsirixRemoveROI,
                       object: nil)
        nc.addObserver(self,
                       selector: #selector(currentImageChanged(_:)),
                       name: NSNotification.Name.OsirixDCMUpdateCurrentImage,
                       object: nil)
        nc.addObserver(self,
                       selector: #selector(roiSelected(_:)),
                       name: NSNotification.Name.OsirixROISelected,
                       object: nil)
        nc.addObserver(self,
                       selector: #selector(windowOcclusionChanged(_:)),
                       name: NSWindow.didChangeOcclusionStateNotification,
                       object: window)

        viewer = v

        fireUpdate(nil)
    }

    // MARK: - Window

    public override func windowDidLoad() {
        super.windowDidLoad()
        guard let window else { return }
        window.minSize = NSSize(width: 640, height: 320)
        if window.frame.width < 640 || window.frame.height < 320 {
            window.setContentSize(NSSize(width: 820, height: 460))
        }
        buildContent(in: window)
    }

    private func button(_ title: String, _ action: Selector, toggle: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        if toggle {
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .accessoryBarAction
        }
        return button
    }

    private func buildContent(in window: NSWindow) {
        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = content

        scopeControl = NSSegmentedControl(labels: [NSLocalizedString("This Slice", comment: "ROI Manager: list the ROIs of the image on screen"),
                                                   NSLocalizedString("Series", comment: "ROI Manager: list the ROIs of every image")],
                                          trackingMode: .selectOne, target: self, action: #selector(scopeChanged(_:)))
        scopeControl.controlSize = .small
        scopeControl.selectedSegment = scope.rawValue
        selectedOnlyButton = button(NSLocalizedString("Selected", comment: "ROI Manager filter"), #selector(filterChanged(_:)), toggle: true)
        visibleOnlyButton = button(NSLocalizedString("Visible", comment: "ROI Manager filter"), #selector(filterChanged(_:)), toggle: true)
        lockedOnlyButton = button(NSLocalizedString("Locked", comment: "ROI Manager filter"), #selector(filterChanged(_:)), toggle: true)
        groupButton = button(NSLocalizedString("Group by Name", comment: "ROI Manager"), #selector(filterChanged(_:)), toggle: true)
        groupButton.state = .on
        searchField = NSSearchField()
        searchField.controlSize = .small
        searchField.placeholderString = NSLocalizedString("Filter by name", comment: "ROI Manager")
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(filterChanged(_:))
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        let top = NSStackView(views: [scopeControl, selectedOnlyButton, visibleOnlyButton, lockedOnlyButton, groupButton, searchField])
        top.spacing = 6
        top.setHuggingPriority(.defaultLow, for: .horizontal)

        outline = NSOutlineView()
        outline.headerView = NSTableHeaderView()
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = true
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.autosaveName = "ROIManagerOutline"
        outline.autosaveTableColumns = true
        func column(_ id: String, _ title: String, _ width: CGFloat, cell: NSCell? = nil) -> NSTableColumn {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = min(width, 20)
            if let cell { column.dataCell = cell }
            outline.addTableColumn(column)
            return column
        }
        let swatch = NSImageCell()
        swatch.imageScaling = .scaleNone
        _ = column("color", "", 18, cell: swatch)
        let name = column("name", NSLocalizedString("Name", comment: ""), 220)
        (name.dataCell as? NSTextFieldCell)?.lineBreakMode = .byTruncatingTail
        name.isEditable = true
        name.minWidth = 80
        outline.outlineTableColumn = name
        _ = column("slice", NSLocalizedString("Slice", comment: "ROI Manager column"), 70)
        _ = column("count", "#", 40)
        _ = column("measure", NSLocalizedString("Measure", comment: "ROI Manager column: area of a ROI, volume of a group"), 110)
        for (check, title) in [(ROIManagerCheck.visible, NSLocalizedString("Visible", comment: "")),
                               (.locked, NSLocalizedString("Locked", comment: "")),
                               (.selectable, NSLocalizedString("Selectable", comment: ""))] {
            let cell = NSButtonCell()
            cell.setButtonType(.switch)
            cell.allowsMixedState = true
            cell.title = ""
            cell.controlSize = .small
            let c = column(check.rawValue, title, 64, cell: cell)
            c.headerCell.alignment = .center
        }
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(goToSlice(_:))
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        tableView = outline
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder

        inspector = buildInspector()
        split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(scroll)
        split.addArrangedSubview(inspector)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        split.autosaveName = "ROIManagerSplit"

        let remove = NSButton(image: NSImage(named: NSImage.removeTemplateName)!, target: self, action: #selector(deleteROI(_:)))
        remove.bezelStyle = .smallSquare
        remove.toolTip = NSLocalizedString("Delete the selected ROIs", comment: "ROI Manager")
        let export = NSPopUpButton(frame: .zero, pullsDown: true)
        export.controlSize = .small
        export.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        export.addItem(withTitle: NSLocalizedString("Export", comment: "ROI Manager: the export menu"))
        export.addItem(withTitle: NSLocalizedString("Save as CSV…", comment: "ROI Manager"))
        export.lastItem?.target = self
        export.lastItem?.action = #selector(saveCSV(_:))
        let inspectorToggle = NSButton(image: NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: NSLocalizedString("Inspector", comment: "")) ?? NSImage(),
                                       target: self, action: #selector(toggleInspector(_:)))
        inspectorToggle.bezelStyle = .smallSquare
        inspectorToggle.toolTip = NSLocalizedString("Show or hide the inspector", comment: "ROI Manager")
        summaryLabel = NSTextField(labelWithString: "")
        summaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bottom = NSStackView(views: [remove, export, summaryLabel, inspectorToggle])
        bottom.spacing = 8
        bottom.setCustomSpacing(4, after: remove)

        for view in [top, split, bottom] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            top.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -10),
            split.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 8),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottom.topAnchor.constraint(equalTo: split.bottomAnchor, constant: 6),
            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
            inspector.widthAnchor.constraint(greaterThanOrEqualToConstant: 230),
            scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])
        updateInspector()
    }

    private func buildInspector() -> NSView {
        inspectorTitle = NSTextField(labelWithString: "")
        inspectorTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        inspectorTitle.lineBreakMode = .byTruncatingTail
        nameField = NSTextField(string: "")
        nameField.placeholderString = NSLocalizedString("Name", comment: "")
        nameField.target = self
        nameField.action = #selector(nameEdited(_:))
        colorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        opacitySlider = NSSlider(value: 1, minValue: 0.05, maxValue: 1, target: self, action: #selector(opacityChanged(_:)))
        opacitySlider.controlSize = .small
        thicknessSlider = NSSlider(value: 2, minValue: 1, maxValue: 20, target: self, action: #selector(thicknessChanged(_:)))
        thicknessSlider.controlSize = .small
        func check(_ title: String, _ action: Selector) -> NSButton {
            let button = NSButton(checkboxWithTitle: title, target: self, action: action)
            button.allowsMixedState = true
            return button
        }
        visibleCheck = check(NSLocalizedString("Visible", comment: ""), #selector(inspectorCheckChanged(_:)))
        lockedCheck = check(NSLocalizedString("Locked", comment: ""), #selector(inspectorCheckChanged(_:)))
        selectableCheck = check(NSLocalizedString("Selectable", comment: ""), #selector(inspectorCheckChanged(_:)))
        commentsView = NSTextView()
        commentsView.isRichText = false
        commentsView.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        commentsView.delegate = self
        let comments = NSScrollView()
        comments.documentView = commentsView
        comments.hasVerticalScroller = true
        comments.borderType = .bezelBorder
        commentsView.autoresizingMask = [.width]
        comments.heightAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        infoButton = NSButton(title: NSLocalizedString("Full Info…", comment: "ROI Manager: open the ROI window"), target: self, action: #selector(showInfo(_:)))
        infoButton.controlSize = .small

        func row(_ label: String, _ control: NSView) -> NSView {
            let text = NSTextField(labelWithString: label)
            text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            text.alignment = .right
            text.widthAnchor.constraint(equalToConstant: 70).isActive = true
            let stack = NSStackView(views: [text, control])
            stack.spacing = 6
            return stack
        }
        let stack = NSStackView(views: [
            inspectorTitle,
            row(NSLocalizedString("Name:", comment: ""), nameField),
            row(NSLocalizedString("Color:", comment: ""), colorWell),
            row(NSLocalizedString("Opacity:", comment: ""), opacitySlider),
            row(NSLocalizedString("Thickness:", comment: ""), thicknessSlider),
            visibleCheck, lockedCheck, selectableCheck,
            NSTextField(labelWithString: NSLocalizedString("Comments:", comment: "")),
            comments,
            infoButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        for view in stack.arrangedSubviews where view is NSStackView || view === comments {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        }
        return stack
    }

    // MARK: - Reading the viewer

    /// `[[viewer roiList] objectAtIndex: [[viewer imageView] curImage]]`.
    private func currentROIList() -> NSMutableArray? {
        guard let viewer = viewer, let roiList = viewer.roiList() else { return nil }
        return roiList.object(at: Int(viewer.imageView()?.curImage ?? 0)) as? NSMutableArray
    }

    /// The image number the viewer shows for a slice of its lists, from 0:
    /// a series shown flipped counts its images from the other end.
    private func displayed(_ slice: Int) -> Int {
        guard let viewer, viewer.imageView()?.flippedData == true else { return slice }
        return Int(viewer.getNumberOfImages()) - 1 - slice
    }

    /// Shows a slice of the viewer's lists.
    private func show(slice: Int) {
        viewer?.setImageIndex(displayed(slice))
    }

    private func slices() -> [[AnyObject]] {
        guard let roiList = viewer?.roiList() else { return [] }
        return (0..<roiList.count).map { (roiList.object(at: $0) as? NSArray as? [AnyObject]) ?? [] }
    }

    private static let reader = ROIManagerReader(
        name: { ($0 as? ROI)?.name ?? "" },
        hidden: { ($0 as? ROI)?.hidden ?? false },
        locked: { ($0 as? ROI)?.locked ?? false },
        selected: { roi in
            let mode = (roi as? ROI)?.roImode ?? 0
            return mode == Int(ROI_selected) || mode == Int(ROI_selectedModify) || mode == Int(ROI_drawing)
        },
        unnamed: { ROIObjectJoin.isUnnamed($0) })

    /// Changes come in bursts: one rebuild for each, and none while hidden.
    private func scheduleRebuild() {
        guard coalescer.changed(visible: window?.isVisible == true) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.coalescer.fired()
                self.rebuild()
            }
        }
    }

    private func rebuild() {
        guard let outline, viewer != nil, !closing else { return }
        coalescer.rebuilt()
        let selected = Set(selectedROIs().map(ObjectIdentifier.init))
        let current = Int(viewer?.imageView()?.curImage ?? 0)
        items = ROIManagerModel.items(slices: slices(), currentSlice: current, scope: scope, filter: filter,
                                      groupByName: groupByName, reader: Self.reader)
        syncingSelection = true
        outline.reloadData()
        for case let group as ROIManagerGroup in items where expandedNames.contains(group.name) {
            outline.expandItem(group)
        }
        var rows = IndexSet()
        for row in 0..<outline.numberOfRows {
            if let item = outline.item(atRow: row) as? ROIManagerRow, let roi = item.roi as? ROI,
               selected.contains(ObjectIdentifier(roi)) || roi === revealROI {
                rows.insert(row)
            }
        }
        if let reveal = revealROI, !rows.contains(where: { (outline.item(atRow: $0) as? ROIManagerRow)?.roi === reveal }) {
            for case let group as ROIManagerGroup in items where group.rows.contains(where: { $0.roi === reveal }) {
                outline.expandItem(group)
                expandedNames.insert(group.name)
            }
            for row in 0..<outline.numberOfRows where (outline.item(atRow: row) as? ROIManagerRow)?.roi === reveal { rows.insert(row) }
        }
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        if revealROI != nil, let first = rows.first { outline.scrollRowToVisible(first) }
        revealROI = nil
        syncingSelection = false
        let all = ROIManagerModel.rows(of: items)
        let groups = items.filter { $0 is ROIManagerGroup }.count
        summaryLabel.stringValue = String(format: NSLocalizedString("%ld ROIs, %ld groups", comment: "ROI Manager footer"), all.count, groups)
        updateInspector()
        computeVolumes()
    }

    /// The volume of each group, from the areas on its slices, off the main thread.
    private func computeVolumes() {
        volumeGeneration += 1
        let generation = volumeGeneration
        guard let pixList = viewer?.pixList() else { return }
        func geometry(_ slice: Int) -> ((Double, Double, Double), (Double, Double, Double), Double)? {
            guard slice < pixList.count, let pix = pixList.object(at: slice) as? DCMPix else { return nil }
            var o = [Double](repeating: 0, count: 9)
            pix.orientationDouble(&o)
            return ((pix.originX, pix.originY, pix.originZ), (o[6], o[7], o[8]), pix.spacingBetweenSlices)
        }
        var jobs: [String: [ROIManagerVolumeSlice]] = [:]
        for case let group as ROIManagerGroup in items where group.sliceCount >= 2 {
            var bySlice: [Int: (Double, Int)] = [:]
            for row in group.rows {
                guard let roi = row.roi as? ROI, roi.isValidForVolume() else { continue }
                let area = self.area(of: roi)
                bySlice[row.slice] = ((bySlice[row.slice]?.0 ?? 0) + area, (bySlice[row.slice]?.1 ?? 0) + 1)
            }
            jobs[group.name] = bySlice.sorted { $0.key < $1.key }.compactMap { slice, value in
                guard let g = geometry(slice) else { return nil }
                return ROIManagerVolumeSlice(area: value.0, origin: g.0, normal: g.1, count: value.1, spacing: g.2)
            }
            if volumes[group.name] == nil { volumes[group.name] = .nan }
        }
        var origins: [(Double, Double, Double)] = []
        for slice in 0..<pixList.count { if let g = geometry(slice) { origins.append(g.0) } }
        let seriesOrigins = origins
        let volumeJobs = jobs
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var results: [String: Double] = [:]
            for (name, slices) in volumeJobs {
                let volumeSlices = slices.map {
                    ROIVolumeSlice(areaCm2: $0.area, originX: $0.origin.0, originY: $0.origin.1, originZ: $0.origin.2,
                                   normalX: $0.normal.0, normalY: $0.normal.1, normalZ: $0.normal.2,
                                   componentCount: $0.count, maskPixelCount: 0, pixelAreaMm2: 0, spacingBetweenSlicesMm: $0.spacing)
                }
                let points = seriesOrigins.map { ROIPatientPoint(x: $0.0, y: $0.1, z: $0.2) }
                let result = ROIVolumeGeometry.volume(from: volumeSlices, seriesOrigins: points, interpolateMissing: false, meshPointCount: 0)
                results[name] = result.map { $0.occupiedPlaneCount >= 2 ? $0.volumeCm3 : 0 } ?? 0
            }
            let done = results
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.volumeGeneration, let outline = self.outline else { return }
                    self.volumes.merge(done) { _, new in new }
                    let column = outline.column(withIdentifier: NSUserInterfaceItemIdentifier("measure"))
                    if column >= 0 { outline.reloadData(forRowIndexes: IndexSet(0..<outline.numberOfRows), columnIndexes: IndexSet(integer: column)) }
                }
            }
        }
    }

    private func area(of roi: ROI) -> Double {
        if let area = areas.object(forKey: roi) { return area.doubleValue }
        let area = Double(roi.roiArea())
        areas.setObject(NSNumber(value: area), forKey: roi)
        return area
    }

    // MARK: - Notifications

    /// Also the action of the timer -fireUpdate: scheduled, which passed the
    /// timer: the parameter is not bridged to Notification.
    @objc(roiListModification:)
    public func roiListModification(_ note: NSNotification!) {
        if let roi = note?.object as? ROI { areas.removeObject(forKey: roi) } else if note?.object == nil { areas.removeAllObjects() }
        scheduleRebuild()
    }

    @objc(fireUpdate:)
    public func fireUpdate(_ note: NSNotification!) {
        scheduleRebuild()
    }

    @objc(currentImageChanged:)
    func currentImageChanged(_ note: NSNotification!) {
        // The series list does not change with the image on screen.
        if scope == .slice { scheduleRebuild() }
    }

    @objc(roiSelected:)
    func roiSelected(_ note: NSNotification!) {
        guard !syncingSelection else { return }
        if let roi = note?.object as? ROI { revealROI = roi }
        scheduleRebuild()
    }

    @objc(windowOcclusionChanged:)
    func windowOcclusionChanged(_ note: NSNotification!) {
        if window?.occlusionState.contains(.visible) == true && coalescer.dirty { scheduleRebuild() }
    }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if coalescer.dirty { scheduleRebuild() }
    }

    // MARK: - Controls

    @objc func scopeChanged(_ sender: Any?) {
        scope = ROIManagerScope(rawValue: scopeControl.selectedSegment) ?? .slice
        UserDefaults.standard.set(scope.rawValue, forKey: Self.scopeDefaultsKey)
        rebuild()
    }

    @objc func filterChanged(_ sender: Any?) {
        filter.text = searchField.stringValue
        filter.selectedOnly = selectedOnlyButton.state == .on
        filter.visibleOnly = visibleOnlyButton.state == .on
        filter.lockedOnly = lockedOnlyButton.state == .on
        groupByName = groupButton.state == .on
        rebuild()
    }

    @objc func toggleInspector(_ sender: Any?) {
        inspector.isHidden.toggle()
        split.adjustSubviews()
    }

    // MARK: - Selection

    private func selectedItems() -> [AnyObject] {
        guard let outline else { return [] }
        return outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as AnyObject? }
    }

    private func selectedRows() -> [ROIManagerRow] {
        var seen = Set<ObjectIdentifier>()
        return ROIManagerModel.rows(of: selectedItems()).filter { seen.insert(ObjectIdentifier($0.roi)).inserted }
    }

    private func selectedROIs() -> [ROI] {
        selectedRows().compactMap { $0.roi as? ROI }
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        updateInspector()
        guard !syncingSelection, let viewer, let view = viewer.imageView() else { return }
        let rows = selectedRows()
        guard !rows.isEmpty else { return }
        syncingSelection = true
        defer { syncingSelection = false }
        // One slice chosen: go there, and select its ROIs on it.
        let slices = Set(rows.map(\.slice))
        if slices.count == 1, let slice = slices.first, slice != Int(view.curImage) {
            show(slice: slice)
        }
        let chosen = Set(rows.filter { $0.slice == Int(view.curImage) }.compactMap { ($0.roi as? ROI).map(ObjectIdentifier.init) })
        for case let roi as ROI in (currentROIList() as? [Any]) ?? [] where !roi.hidden {
            roi.roImode = chosen.contains(ObjectIdentifier(roi)) && roi.selectable ? Int(ROI_selected) : Int(ROI_sleep)
        }
        view.setNeedsDisplay(view.bounds)
    }

    public func outlineViewItemDidExpand(_ notification: Notification) {
        if let group = notification.userInfo?["NSObject"] as? ROIManagerGroup { expandedNames.insert(group.name) }
    }

    public func outlineViewItemDidCollapse(_ notification: Notification) {
        if let group = notification.userInfo?["NSObject"] as? ROIManagerGroup { expandedNames.remove(group.name) }
    }

    @objc func goToSlice(_ sender: Any?) {
        guard let outline, outline.clickedRow >= 0 || outline.selectedRow >= 0 else { return }
        let item = outline.item(atRow: outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow)
        let slice = (item as? ROIManagerRow)?.slice ?? (item as? ROIManagerGroup)?.firstSlice
        if let slice { show(slice: slice) }
    }

    // MARK: - Data source

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return items.count }
        return (item as? ROIManagerGroup)?.rows.count ?? 0
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return items[index] }
        return (item as! ROIManagerGroup).rows[index]
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is ROIManagerGroup
    }

    private func rois(of item: Any?) -> [ROI] {
        if let row = item as? ROIManagerRow { return (row.roi as? ROI).map { [$0] } ?? [] }
        if let group = item as? ROIManagerGroup { return group.rows.compactMap { $0.roi as? ROI } }
        return []
    }

    private static var swatches: [UInt64: NSImage] = [:]

    private func swatch(_ roi: ROI) -> NSImage {
        let rgb = roi.rgbcolor
        let key = UInt64(rgb.red) << 32 | UInt64(rgb.green) << 16 | UInt64(rgb.blue)
        if let image = Self.swatches[key] { return image }
        let color = NSColor(calibratedRed: CGFloat(rgb.red) / 65535, green: CGFloat(rgb.green) / 65535, blue: CGFloat(rgb.blue) / 65535, alpha: 1)
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2).fill()
            return true
        }
        Self.swatches[key] = image
        return image
    }

    private static func areaText(_ cm2: Double) -> String {
        if cm2 <= 0 { return "—" }
        return cm2 < 1 ? String(format: "%.1f mm²", cm2 * 100) : String(format: "%.2f cm²", cm2)
    }

    private static func volumeText(_ cm3: Double) -> String {
        if cm3.isNaN { return "…" }
        if cm3 <= 0 { return "—" }
        return cm3 < 10 ? String(format: "%.3f cm³", cm3) : String(format: "%.1f cm³", cm3)
    }

    private func checkValue(_ check: ROIManagerCheck, _ roi: ROI) -> Bool {
        switch check {
        case .visible: return !roi.hidden
        case .locked: return roi.locked
        case .selectable: return roi.selectable
        }
    }

    public func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?) -> Any? {
        let column = tableColumn?.identifier.rawValue ?? ""
        if let check = ROIManagerCheck(rawValue: column) {
            return NSNumber(value: ROIManagerModel.state(of: rois(of: item).map { checkValue(check, $0) }))
        }
        if let row = item as? ROIManagerRow, let roi = row.roi as? ROI {
            switch column {
            case "color": return swatch(roi)
            case "name": return roi.name
            case "slice": return "\(displayed(row.slice) + 1)"
            case "measure": return Self.areaText(area(of: roi))
            default: return nil
            }
        }
        if let group = item as? ROIManagerGroup {
            switch column {
            case "color": return (group.rows.first?.roi as? ROI).map(swatch)
            case "name": return group.name
            case "slice":
                let ends = [displayed(group.firstSlice) + 1, displayed(group.lastSlice) + 1].sorted()
                return ends[0] == ends[1] ? "\(ends[0])" : "\(ends[0])–\(ends[1])"
            case "count": return "\(group.rows.count)"
            case "measure":
                if group.sliceCount >= 2 { return Self.volumeText(volumes[group.name] ?? .nan) }
                return Self.areaText(group.rows.compactMap { $0.roi as? ROI }.reduce(0) { $0 + area(of: $1) })
            default: return nil
            }
        }
        return nil
    }

    public func outlineView(_ outlineView: NSOutlineView, setObjectValue anObject: Any?, for tableColumn: NSTableColumn?, byItem item: Any?) {
        let column = tableColumn?.identifier.rawValue ?? ""
        if let check = ROIManagerCheck(rawValue: column) {
            let rois = rois(of: item)
            set(check, to: ROIManagerModel.state(of: rois.map { checkValue(check, $0) }) != 1, for: rois)
            return
        }
        guard column == "name" else { return }
        let editedROI = (item as? ROIManagerRow)?.roi as? ROI

        // ROIs that share a name are one object, renamed together on every
        // slice. "Unnamed" ones were never grouped by the user: only the
        // edited ROI takes the new name.
        if let editedROI = editedROI, ROIObjectJoin.isUnnamed(editedROI.name) {
            editedROI.name = anObject as? String
            NotificationCenter.default.post(name: NSNotification.Name.OsirixROIChange, object: editedROI, userInfo: nil)
        } else {
            viewer?.renameSeriesROIwithName(editedROI?.name ?? (item as? ROIManagerGroup)?.name, newName: anObject as? String)
        }

        scheduleRebuild()
    }

    public func outlineView(_ outlineView: NSOutlineView, shouldEdit tableColumn: NSTableColumn?, item: Any) -> Bool {
        let column = tableColumn?.identifier.rawValue ?? ""
        return column == "name" || ROIManagerCheck(rawValue: column) != nil
    }

    // MARK: - Changing ROIs

    private func set(_ check: ROIManagerCheck, to value: Bool, for rois: [ROI]) {
        guard !rois.isEmpty else { return }
        for roi in rois {
            switch check {
            case .visible: roi.hidden = !value
            case .locked: roi.locked = value
            case .selectable: roi.selectable = value
            }
        }
        viewer?.imageView()?.needsDisplay = true
        rebuild()
    }

    @objc func inspectorCheckChanged(_ sender: NSButton) {
        // A mixed check, clicked, turns on.
        let value = sender.state != .off
        sender.state = value ? .on : .off
        let check: ROIManagerCheck = sender === visibleCheck ? .visible : sender === lockedCheck ? .locked : .selectable
        set(check, to: value, for: selectedROIs())
    }

    @objc func nameEdited(_ sender: Any?) {
        let rois = selectedROIs()
        guard !rois.isEmpty, !nameField.stringValue.isEmpty else { return }
        let names = Set(rois.map { $0.name ?? "" })
        if rois.count == 1, let roi = rois.first, ROIObjectJoin.isUnnamed(roi.name) {
            roi.name = nameField.stringValue
            NotificationCenter.default.post(name: NSNotification.Name.OsirixROIChange, object: roi, userInfo: nil)
        } else if names.count == 1, let name = names.first, !ROIObjectJoin.isUnnamed(name) {
            viewer?.renameSeriesROIwithName(name, newName: nameField.stringValue)
        } else {
            for roi in rois { roi.name = nameField.stringValue }
            NotificationCenter.default.post(name: NSNotification.Name.OsirixROIChange, object: rois.first, userInfo: nil)
        }
        scheduleRebuild()
    }

    @objc func colorChanged(_ sender: Any?) {
        guard let color = colorWell.color.usingColorSpace(.genericRGB) else { return }
        let rgb = RGBColor(red: UInt16(color.redComponent * 65535), green: UInt16(color.greenComponent * 65535), blue: UInt16(color.blueComponent * 65535))
        for roi in selectedROIs() { roi.setColor(rgb, globally: false) }
        viewer?.imageView()?.needsDisplay = true
        outline.reloadData(forRowIndexes: IndexSet(0..<outline.numberOfRows), columnIndexes: IndexSet(integer: 0))
    }

    @objc func opacityChanged(_ sender: Any?) {
        for roi in selectedROIs() { roi.setOpacity(opacitySlider.floatValue, globally: false) }
        viewer?.imageView()?.needsDisplay = true
    }

    @objc func thicknessChanged(_ sender: Any?) {
        for roi in selectedROIs() { roi.setThickness(thicknessSlider.floatValue, globally: false) }
        viewer?.imageView()?.needsDisplay = true
    }

    public func textDidEndEditing(_ notification: Notification) {
        guard (notification.object as AnyObject?) === commentsView else { return }
        for roi in selectedROIs() { roi.comments = commentsView.string }
    }

    private func updateInspector() {
        guard inspectorTitle != nil else { return }
        let rois = selectedROIs()
        let controls: [NSControl] = [nameField, colorWell, opacitySlider, thicknessSlider, visibleCheck, lockedCheck, selectableCheck, infoButton]
        for control in controls { control.isEnabled = !rois.isEmpty }
        commentsView.isEditable = !rois.isEmpty
        guard let first = rois.first else {
            inspectorTitle.stringValue = NSLocalizedString("No ROI selected", comment: "ROI Manager inspector")
            nameField.stringValue = ""
            commentsView.string = ""
            return
        }
        let names = Set(rois.map { $0.name ?? "" })
        inspectorTitle.stringValue = rois.count == 1 ? (first.name ?? "")
            : String(format: NSLocalizedString("%ld ROIs", comment: "ROI Manager inspector: how many are selected"), rois.count)
        nameField.stringValue = names.count == 1 ? (names.first ?? "") : ""
        nameField.placeholderString = names.count == 1 ? NSLocalizedString("Name", comment: "") : NSLocalizedString("Several names", comment: "ROI Manager inspector")
        let rgb = first.rgbcolor
        colorWell.color = NSColor(calibratedRed: CGFloat(rgb.red) / 65535, green: CGFloat(rgb.green) / 65535, blue: CGFloat(rgb.blue) / 65535, alpha: 1)
        opacitySlider.floatValue = first.opacity
        thicknessSlider.floatValue = first.thickness
        visibleCheck.state = NSControl.StateValue(rawValue: ROIManagerModel.state(of: rois.map { !$0.hidden }))
        lockedCheck.state = NSControl.StateValue(rawValue: ROIManagerModel.state(of: rois.map(\.locked)))
        selectableCheck.state = NSControl.StateValue(rawValue: ROIManagerModel.state(of: rois.map(\.selectable)))
        commentsView.string = Set(rois.map { $0.comments ?? "" }).count == 1 ? (first.comments ?? "") : ""
    }

    @objc func showInfo(_ sender: Any?) {
        guard let roi = selectedROIs().first, let viewer else { return }
        for window in NSApp.windows where window.windowController?.windowNibName == "ROI" && !horosWindowControllerIsClosing(window.windowController) {
            if ((window.windowController as AnyObject?)?.curROI?() as AnyObject?) === roi {
                window.makeKeyAndOrderFront(self)
                return
            }
        }
        let roiWin = ROIWindow(roi: roi, viewer)
        // The ROI window releases itself when it closes.
        _ = Unmanaged.passRetained(roiWin)
        roiWin.showWindow(self)
    }

    @objc func setVisibleFromMenu(_ sender: NSMenuItem) { set(.visible, to: sender.tag == 1, for: selectedROIs()) }
    @objc func setLockedFromMenu(_ sender: NSMenuItem) { set(.locked, to: sender.tag == 1, for: selectedROIs()) }

    @objc func setGroupedFromMenu(_ sender: NSMenuItem) {
        // A group is selected and deleted together, as -setSelectedROIsGrouped: makes it.
        let groupID: TimeInterval = sender.tag == 1 ? Date.timeIntervalSinceReferenceDate : 0
        for roi in selectedROIs() { roi.groupID = groupID }
        NotificationCenter.default.post(name: NSNotification.Name.OsirixROIChange, object: nil, userInfo: nil)
    }

    public override func keyDown(with event: NSEvent) {
        guard let characters = event.characters, (characters as NSString).length > 0 else { return }

        let c = Int((characters as NSString).character(at: 0))

        if c == NSDeleteFunctionKey || c == NSDeleteCharacter || c == NSBackspaceCharacter || c == NSDeleteCharFunctionKey {
            deleteROI(self)
        } else if event.modifierFlags.contains(.command), characters == "i" {
            showInfo(self)
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Context menu

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let rois = outline.clickedRow >= 0 && !outline.selectedRowIndexes.contains(outline.clickedRow)
            ? rois(of: outline.item(atRow: outline.clickedRow)) : selectedROIs()
        if outline.clickedRow >= 0 && !outline.selectedRowIndexes.contains(outline.clickedRow) {
            outline.selectRowIndexes(IndexSet(integer: outline.clickedRow), byExtendingSelection: false)
        }
        guard !rois.isEmpty else { return }
        func add(_ title: String, _ action: Selector, tag: Int = 0, key: String = "") {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
            item.tag = tag
        }
        let hidden = rois.allSatisfy(\.hidden)
        add(hidden ? NSLocalizedString("Show", comment: "ROI Manager menu") : NSLocalizedString("Hide", comment: "ROI Manager menu"),
            #selector(setVisibleFromMenu(_:)), tag: hidden ? 1 : 0)
        let locked = rois.allSatisfy(\.locked)
        add(locked ? NSLocalizedString("Unlock", comment: "ROI Manager menu") : NSLocalizedString("Lock", comment: "ROI Manager menu"),
            #selector(setLockedFromMenu(_:)), tag: locked ? 0 : 1)
        add(NSLocalizedString("Group", comment: "ROI Manager menu"), #selector(setGroupedFromMenu(_:)), tag: 1)
        add(NSLocalizedString("Ungroup", comment: "ROI Manager menu"), #selector(setGroupedFromMenu(_:)), tag: 0)
        menu.addItem(.separator())
        add(NSLocalizedString("Go to Slice", comment: "ROI Manager menu"), #selector(goToSlice(_:)))
        add(NSLocalizedString("ROI Info…", comment: "ROI Manager menu"), #selector(showInfo(_:)), key: "i")
        menu.addItem(.separator())
        add(NSLocalizedString("Delete", comment: "ROI Manager menu"), #selector(deleteROI(_:)))
    }

    // MARK: - Delete

    /// Delete ROI
    @IBAction @objc(deleteROI:)
    public func deleteROI(_ sender: Any!) {
        let selectedROIs = self.selectedROIs()
        guard !selectedROIs.isEmpty, let viewer else { return }

        // Only the selected rows' ROIs: a removal by name also took every
        // other ROI of the series with that name, on every slice.
        let current = currentROIList()
        if selectedROIs.allSatisfy({ current?.indexOfObjectIdentical(to: $0) ?? NSNotFound != NSNotFound }) {
            viewer.imageView()?.deleteROIs(selectedROIs)
        } else {
            removeAcrossSlices(selectedROIs)
        }

        NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateView, object: nil, userInfo: nil)
    }

    /// The selected ROIs of other slices too, as -deleteROIs: removes those of
    /// the slice on screen: one undo step, locked ROIs kept.
    private func removeAcrossSlices(_ rois: [ROI]) {
        guard let viewer, let roiList = viewer.roiList() else { return }
        let wanted = Set(rois.filter { !$0.locked }.map(ObjectIdentifier.init))
        guard !wanted.isEmpty else { return }
        viewer.add(toUndoQueue: "roi")
        viewer.imageView()?.stopROIEditingForce(true)
        for index in 0..<roiList.count {
            guard let slice = roiList.object(at: index) as? NSMutableArray else { continue }
            for i in stride(from: slice.count - 1, through: 0, by: -1) {
                guard let roi = slice.object(at: i) as? ROI, wanted.contains(ObjectIdentifier(roi)) else { continue }
                NotificationCenter.default.post(name: NSNotification.Name.OsirixRemoveROI, object: roi, userInfo: nil)
                slice.removeObject(at: i)
            }
        }
        NotificationCenter.default.post(name: NSNotification.Name.OsirixROIRemovedFromArray, object: nil, userInfo: nil)
        if let view = viewer.imageView() { view.setIndex(view.curImage) }
    }

    // MARK: - CSV

    @objc func saveCSV(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = NSLocalizedString("ROIs", comment: "ROI Manager: the name of a CSV file") + ".csv"
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                do {
                    try self.writeCSV(to: url)
                } catch {
                    NSAlert(error: error).beginSheetModal(for: window)
                }
            }
        }
    }

    /// The listed ROIs, one per line, with their pixel statistics.
    @objc(writeCSVToURL:error:)
    func writeCSV(to url: URL) throws {
        var table = [ROIManagerModel.csvHeader]
        for row in ROIManagerModel.rows(of: items) {
            guard let roi = row.roi as? ROI else { continue }
            var s = ROIManagerStatistics()
            if let pix = viewer?.pixList()?.object(at: row.slice) as? DCMPix {
                pix.computeROI(roi, &s.mean, &s.total, &s.deviation, &s.minimum, &s.maximum)
            }
            table.append(ROIManagerModel.csvRecord(name: roi.name ?? "", slice: displayed(row.slice), areaCm2: area(of: roi), statistics: s,
                                                   hidden: roi.hidden, locked: roi.locked, comments: roi.comments ?? ""))
        }
        try StudyMetadataExport.data(forCSV: StudyMetadataExport.csv(fromRows: table)).write(to: url, options: .atomic)
    }

    // MARK: - Closing

    // delegate method setROIMode

    @objc(CloseViewerNotification:)
    func CloseViewerNotification(_ note: NSNotification!) {
        if (note.object as AnyObject?) === viewer {
            // A viewer that changes its data (a plane change, another
            // series) posts it too, and stays: the list follows its new ROIs.
            if viewer?.horos_windowWillClose == false {
                areas.removeAllObjects()
                scheduleRebuild()
                return
            }
            viewer = nil

            NSLog("ROIManager CloseViewerNotification")

            window?.close()
        }
    }

    @objc(windowWillClose:)
    public func windowWillClose(_ notification: NSNotification!) {
        closing = true
        window?.acceptsMouseMovedEvents = false

        NotificationCenter.default.removeObserver(self)

        NSLog("ROIManager windowWillClose")

        // [self autorelease]: the reference the code that made it kept.
        _ = Unmanaged.passUnretained(self).autorelease()
    }

    isolated deinit {
        NSLog("ROIManager dealloc")
        outline?.dataSource = nil
        outline?.delegate = nil
        viewer = nil

        NotificationCenter.default.removeObserver(self)
    }
}
