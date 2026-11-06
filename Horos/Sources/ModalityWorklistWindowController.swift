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
import IsiXDICOMNetwork
import IsiXPreferences

/// Network > Modality Worklist…: the scheduled procedure steps of the nodes
/// Settings > Locations marks with Worklist, with a mark on each step that has
/// arrived in the local database.
///
/// The window asks its nodes when it opens, when Refresh is clicked, when the
/// days asked for change, and every few minutes as Settings > Locations sets
/// it (ModalityWorklistRefresh). The marks are worked out again when studies
/// are added to the database. Made in code: one window for the process,
/// kept after it is closed so that it opens again as it was.
@MainActor
final class ModalityWorklistWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {

    private static var shared: ModalityWorklistWindowController?

    /// Shows the window, made the first time, and asks its nodes.
    static func show() {
        let controller = shared ?? ModalityWorklistWindowController()
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.startObserving()
        controller.refresh(nil)
    }

    private enum Column: String, CaseIterable {
        case received, scheduled, patientName, patientID, accessionNumber, modality, procedure, station, node

        var title: String {
            switch self {
            case .received: return NSLocalizedString("Received", comment: "Modality Worklist window, column of the mark of a step whose study has arrived")
            case .scheduled: return NSLocalizedString("Scheduled", comment: "Modality Worklist window, column of the date and time of a scheduled step")
            case .patientName: return NSLocalizedString("Patient Name", comment: "")
            case .patientID: return NSLocalizedString("Patient ID", comment: "")
            case .accessionNumber: return NSLocalizedString("Accession Number", comment: "")
            case .modality: return NSLocalizedString("Modality", comment: "")
            case .procedure: return NSLocalizedString("Procedure", comment: "Modality Worklist window, column of the description of a scheduled step")
            case .station: return NSLocalizedString("Station", comment: "Modality Worklist window, column of the AE title of the scheduled station")
            case .node: return NSLocalizedString("Node", comment: "Modality Worklist window, column of the DICOM node that answered a step")
            }
        }

        var width: CGFloat {
            switch self {
            case .received: return 60
            case .scheduled: return 120
            case .patientName: return 160
            case .patientID, .accessionNumber: return 100
            case .modality: return 60
            case .procedure: return 180
            case .station, .node: return 90
            }
        }
    }

    private let table = NSTableView()
    private let dateWindow = NSPopUpButton(frame: .zero, pullsDown: false)
    private let refreshButton = NSButton(title: NSLocalizedString("Refresh", comment: ""), target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "")

    private var procedures: [ScheduledProcedure] = []
    private var matches: [String: WorklistStudyMatch] = [:]
    private var lastAnswer: ModalityWorklistAnswer?
    private var lastUpdate: Date?
    private var refreshing = false
    /// A refresh asked for while one runs: it runs when that one ends.
    private var refreshAgain = false
    private var timer: Timer?
    private var timerInterval: TimeInterval?
    private var observers: [any NSObjectProtocol] = []

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 460),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = NSLocalizedString("Modality Worklist", comment: "Title of the Modality Worklist window")
        window.minSize = NSSize(width: 560, height: 240)
        window.isReleasedWhenClosed = false
        _ = window.setFrameAutosaveName("IsiXModalityWorklistWindow")
        super.init(window: window)
        window.delegate = self
        layOut(in: window.contentView ?? NSView())
        if window.frame.origin == .zero { window.center() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("made in code")
    }

    // MARK: Layout

    private func layOut(in content: NSView) {
        let bounds = content.bounds
        let label = NSTextField(labelWithString: NSLocalizedString("Scheduled for:", comment: "Modality Worklist window, before the popup of the days asked for"))
        label.sizeToFit()
        label.frame.origin = NSPoint(x: 14, y: bounds.maxY - 34 + (22 - label.frame.height) / 2)
        label.autoresizingMask = [.maxXMargin, .minYMargin]

        dateWindow.addItems(withTitles: [NSLocalizedString("Today", comment: ""),
                                         NSLocalizedString("Next 7 days", comment: "Modality Worklist window, the steps of today and the six days after"),
                                         NSLocalizedString("Any date", comment: "")])
        for (index, item) in dateWindow.itemArray.enumerated() { item.tag = ModalityWorklistQuery.DateWindow.allCases[index].rawValue }
        dateWindow.sizeToFit()
        dateWindow.frame = NSRect(x: label.frame.maxX + 6, y: bounds.maxY - 36, width: max(dateWindow.frame.width, 150), height: 26)
        dateWindow.autoresizingMask = [.maxXMargin, .minYMargin]
        dateWindow.target = self
        dateWindow.action = #selector(dateWindowChanged(_:))

        refreshButton.bezelStyle = .rounded
        refreshButton.sizeToFit()
        refreshButton.frame = NSRect(x: bounds.maxX - 14 - max(refreshButton.frame.width, 90), y: bounds.maxY - 38,
                                     width: max(refreshButton.frame.width, 90), height: 30)
        refreshButton.autoresizingMask = [.minXMargin, .minYMargin]
        refreshButton.target = self
        refreshButton.action = #selector(refresh(_:))

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.frame = NSRect(x: refreshButton.frame.minX - 24, y: bounds.maxY - 31, width: 16, height: 16)
        spinner.autoresizingMask = [.minXMargin, .minYMargin]

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 40
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            if column == .received { tableColumn.headerCell.alignment = .center }
            table.addTableColumn(tableColumn)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.autosaveName = "IsiXModalityWorklistTable"
        table.autosaveTableColumns = true

        let scroll = NSScrollView(frame: NSRect(x: 14, y: 36, width: bounds.width - 28, height: bounds.height - 36 - 46))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autoresizingMask = [.width, .height]

        status.frame = NSRect(x: 14, y: 10, width: bounds.width - 28, height: 18)
        status.lineBreakMode = .byTruncatingTail
        status.textColor = .secondaryLabelColor
        status.autoresizingMask = [.width, .maxYMargin]

        for view in [label, dateWindow, spinner, refreshButton, scroll, status] as [NSView] { content.addSubview(view) }
    }

    // MARK: Refresh

    /// The steps of the worklist nodes, asked again.
    @objc func refresh(_ sender: Any?) {
        guard !refreshing else {
            refreshAgain = true
            return
        }
        refreshing = true
        spinner.startAnimation(nil)
        showStatus(NSLocalizedString("Asking for the worklist…", comment: "Modality Worklist window, while the nodes are asked"))
        let days = ModalityWorklistQuery.DateWindow(rawValue: dateWindow.selectedTag()) ?? .today
        Task { [weak self] in
            let answer = await ModalityWorklistService.refresh(filter: .init(dateWindow: days))
            self?.finishRefresh(answer)
        }
    }

    private func finishRefresh(_ answer: ModalityWorklistAnswer) {
        refreshing = false
        spinner.stopAnimation(nil)
        lastAnswer = answer
        lastUpdate = Date()
        procedures = answer.procedures
        sortProcedures()
        updateMatches()
        scheduleTimer()
        if refreshAgain {
            refreshAgain = false
            refresh(nil)
        }
    }

    @objc private func dateWindowChanged(_ sender: Any?) {
        refresh(sender)
    }

    /// The marks of the steps, read again from the database.
    private func updateMatches() {
        matches = ModalityWorklistService.matches(for: procedures)
        table.reloadData()
        showSummary()
    }

    private func showSummary() {
        guard let answer = lastAnswer else { return }
        guard answer.askedNodes > 0 else {
            showStatus(NSLocalizedString("No DICOM node provides the worklist: check Worklist beside a node in Settings > Locations.",
                                         comment: "Modality Worklist window, no node is marked for the worklist"))
            return
        }
        var parts = [String(format: NSLocalizedString("Scheduled steps: %ld", comment: "Modality Worklist window, number of steps listed"),
                            procedures.count),
                     String(format: NSLocalizedString("Received: %ld", comment: "Modality Worklist window, number of steps whose study has arrived"),
                            matches.count)]
        if let lastUpdate {
            parts.append(String(format: NSLocalizedString("Updated at %@", comment: "Modality Worklist window, time of the last answer"),
                                DateFormatter.localizedString(from: lastUpdate, dateStyle: .none, timeStyle: .medium)))
        }
        for failure in answer.failures {
            parts.append(String(format: NSLocalizedString("%1$@ did not answer: %2$@", comment: "Modality Worklist window, a node that failed, and why"),
                                failure.node, failure.reason))
        }
        showStatus(parts.joined(separator: "   "))
    }

    private func showStatus(_ text: String) {
        status.stringValue = text
        status.toolTip = text
    }

    /// The timer of the automatic refresh, as Settings > Locations sets it;
    /// none while the window is closed.
    private func scheduleTimer() {
        let stored = PreferencesSource.process.preferences[NetworkPreferences.modalityWorklistRefreshMinutes]
        let interval = (window?.isVisible ?? false) ? ModalityWorklistRefresh.interval(fromStored: stored) : nil
        guard interval != timerInterval || (interval != nil && timer == nil) else { return }
        timer?.invalidate()
        timer = nil
        timerInterval = interval
        guard let interval else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(nil) }
        }
    }

    private func startObserving() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // A change of Settings > Locations' interval takes effect at once.
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleTimer() }
        })
        // Studies added to the database may be steps of the worklist.
        observers.append(center.addObserver(forName: .OsirixAddToDBComplete, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMatches() }
        })
    }

    private func stopObserving() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        timer?.invalidate()
        timer = nil
        timerInterval = nil
    }

    func windowWillClose(_ notification: Notification) {
        stopObserving()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        procedures.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue), procedures.indices.contains(row) else {
            return nil
        }
        let identifier = NSUserInterfaceItemIdentifier("IsiXModalityWorklistCell")
        let field = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.lineBreakMode = .byTruncatingTail
            return field
        }()
        let procedure = procedures[row]
        field.stringValue = text(of: procedure, in: column)
        field.alignment = column == .received ? .center : .natural
        field.textColor = column == .received ? .systemGreen : .labelColor
        field.toolTip = column == .received ? matches[procedure.id].map(Self.explanation) : nil
        return field
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        sortProcedures()
        tableView.reloadData()
    }

    private func text(of procedure: ScheduledProcedure, in column: Column) -> String {
        switch column {
        case .received: return matches[procedure.id] == nil ? "" : "\u{2713}"
        case .scheduled:
            guard let start = procedure.scheduledStart() else { return procedure.startDate }
            return procedure.startTime.isEmpty ? dayFormatter.string(from: start) : dateFormatter.string(from: start)
        case .patientName: return procedure.displayPatientName
        case .patientID: return procedure.patientID
        case .accessionNumber: return procedure.accessionNumber
        case .modality: return procedure.modality
        case .procedure: return procedure.procedureDescription
        case .station: return procedure.stationAETitle.isEmpty ? procedure.stationName : procedure.stationAETitle
        case .node: return procedure.node
        }
    }

    /// Sorted by the table's first sort column; in start order without one.
    private func sortProcedures() {
        guard let descriptor = table.sortDescriptors.first, let key = descriptor.key, let column = Column(rawValue: key) else { return }
        let ascending = descriptor.ascending
        let keyed = procedures.enumerated().map { (offset: $0.offset, procedure: $0.element, key: sortKey(of: $0.element, in: column)) }
        procedures = keyed.sorted { left, right in
            let order = left.key.localizedStandardCompare(right.key)
            if order == .orderedSame { return left.offset < right.offset }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }.map(\.procedure)
    }

    private func sortKey(of procedure: ScheduledProcedure, in column: Column) -> String {
        switch column {
        case .scheduled: return procedure.startDate + procedure.startTime
        case .received: return matches[procedure.id].map { String($0.rawValue) } ?? ""
        default: return text(of: procedure, in: column)
        }
    }

    private static func explanation(_ match: WorklistStudyMatch) -> String {
        switch match {
        case .studyInstanceUID:
            return NSLocalizedString("Received: same Study Instance UID", comment: "Modality Worklist window, why a step is marked as arrived")
        case .accessionNumber:
            return NSLocalizedString("Received: same Accession Number", comment: "Modality Worklist window, why a step is marked as arrived")
        case .patientIDOnScheduledDay:
            return NSLocalizedString("Received: a study of this Patient ID on the scheduled day",
                                     comment: "Modality Worklist window, why a step is marked as arrived")
        }
    }
}
