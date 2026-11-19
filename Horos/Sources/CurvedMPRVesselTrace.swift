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
import IsiXVolumeRendering
import Synchronization

/// The Curved MPR's path assistant as its window runs it: the vessel tracer
/// through the nodes of the path off the main thread, so that the window and
/// the app stay live; once it takes more than a moment, a sheet with its
/// progress and a Cancel button; the path back in patient space; and a notice
/// when the path needs checking or a segment found nothing. The assistant ran
/// on the main thread, which it held about 50 s a segment on a CT of 256 ×
/// 256 × 450.
@MainActor final class CurvedMPRVesselTrace {
    /// What a trace gives the window.
    struct Outcome {
        /// The nodes of each segment's curve in patient space, from its node
        /// to the next, nil for a segment without: what the path is assembled
        /// from (CurvedMPRPathAssistant.assembledPath).
        let segments: [[N3Vector]?]
        /// The nodes of the last segment that has any, in the volume's voxels.
        let lastSegment: [SIMD3<Float>]
        let assisted: VesselAssistedPath
    }

    /// How the window takes a trace's path. `isCurrent`: whether its path is
    /// still the one traced; a path edited meanwhile gives the trace up, with
    /// no notice, and `givenUp` runs. `isEditing`: whether a view has an edit
    /// of the path open, a node pressed, whose drag would go on with another
    /// node of the traced path: the path waits for the edit's end
    /// (`editEnded`).
    struct Delivery {
        var isCurrent: @MainActor () -> Bool = { true }
        var isEditing: @MainActor () -> Bool = { false }
        var givenUp: @MainActor () -> Void = {}
    }

    /// How long a trace runs before its sheet shows: a segment of a coronary
    /// takes a few hundredths of a second, a few tenths unoptimised.
    static let sheetDelay: Duration = .milliseconds(500)

    private var task: Task<Void, Never>?
    /// A cancelled trace still under way: a segment of the former assistant
    /// cannot stop half way, and the next trace waits for it, so that two of
    /// its distance maps are never kept at once.
    private var cancelledTask: Task<Void, Never>?
    /// Which trace `task` is: a cancelled trace that ends later leaves the next one alone.
    private var generation = 0
    private var sheet: CurvedMPRTraceSheet?
    /// The path of a trace that ended while an edit was open, given as it ends.
    private var held: (@MainActor () -> Void)?

    var isRunning: Bool { task != nil }

    /// Traces the path through `nodes`, in patient space, in `volume`, whose
    /// voxels `patientToVolume` maps them to; `completion` gets the outcome on
    /// the main actor as `delivery` says, and nothing after a cancel. A trace
    /// under way refuses another.
    func start(nodes: [N3Vector], in volume: VesselVolume, patientToVolume: N3AffineTransform, window: NSWindow?,
               delivery: Delivery = Delivery(), completion: @escaping @MainActor (Outcome) -> Void) {
        guard task == nil else { return NSSound.beep() }
        held = nil
        let voxels = nodes.map { node -> SIMD3<Float> in
            let p = N3VectorApplyTransform(node, patientToVolume)
            return SIMD3(Float(p.x), Float(p.y), Float(p.z))
        }
        let volumeToPatient = N3AffineTransformInvert(patientToVolume)
        let share = TraceShare()
        generation += 1
        let traceGeneration = generation
        let previous = cancelledTask
        task = Task { [weak self] in
            await previous?.value
            // Only a cancel ends it without a path: a segment's own refusal is in the path.
            let traced = try? await VesselPathAssistant.trace(through: voxels, in: volume) { share.report($0) }
            guard let self, self.generation == traceGeneration else { return }
            self.finish()
            guard let traced, !Task.isCancelled else { return }
            self.deliver(Self.outcome(of: traced, volumeToPatient: volumeToPatient), by: delivery, in: window, to: completion)
        }
        Task { [weak self] in
            try? await Task.sleep(for: Self.sheetDelay)
            // Not queued behind a sheet the window shows, past the trace's end.
            guard let self, self.generation == traceGeneration, self.task != nil, let window, window.attachedSheet == nil else { return }
            self.sheet = CurvedMPRTraceSheet(on: window, share: share) { [weak self] in self?.cancel() }
        }
    }

    /// After an edit of the window's path ends: the path held for it is given
    /// now, or given up if the edit changed the nodes. Whether one was held.
    func editEnded() -> Bool {
        guard let held else { return false }
        self.held = nil
        held()
        return true
    }

    /// Ends the trace under way, which then gives no path, and its sheet.
    func cancel() {
        if let task {
            task.cancel()
            cancelledTask = task
        }
        held = nil
        finish()
    }

    /// `outcome` to the window, and its notice, unless its path was edited meanwhile.
    private func deliver(_ outcome: Outcome, by delivery: Delivery, in window: NSWindow?, to completion: @escaping @MainActor (Outcome) -> Void) {
        guard delivery.isCurrent() else { return delivery.givenUp() }
        guard !delivery.isEditing() else {
            held = { [weak self] in self?.deliver(outcome, by: delivery, in: window, to: completion) }
            return
        }
        completion(outcome)
        Self.tell(outcome.assisted, in: window)
    }

    private func finish() {
        task = nil
        sheet?.close()
        sheet = nil
    }

    /// The segments of `traced` in patient space.
    static func outcome(of traced: VesselAssistedPath, volumeToPatient: N3AffineTransform) -> Outcome {
        let segments = traced.segmentNodes.map { nodes in
            nodes?.map { N3VectorApplyTransform(N3VectorMake(CGFloat($0.x), CGFloat($0.y), CGFloat($0.z)), volumeToPatient) }
        }
        let last = traced.segmentNodes.last { $0 != nil } ?? nil
        return Outcome(segments: segments, lastSegment: last ?? [], assisted: traced)
    }

    /// The title and text the user is told of `path`: a segment without a
    /// path, a stretch out of the lumen worth checking, a faint lumen; nil
    /// when there is nothing to tell. The length is written with the
    /// decimal separator of the user's region.
    static func notice(for path: VesselAssistedPath) -> (title: String, message: String)? {
        var lines: [String] = []
        let failures = path.failures
        if failures.contains(.outOfMemory) {
            lines.append(NSLocalizedString("Path Assistant cannot allocate enough memory. Close other studies or open a smaller series.", comment: ""))
        }
        if failures.contains(where: { $0 != .outOfMemory }) {
            lines.append(NSLocalizedString("Path Assistant can not find a path from A to B.", comment: ""))
        }
        if path.longestGap > VesselPathAssistant.noticeGapMillimetres {
            lines.append(String.localizedStringWithFormat(NSLocalizedString("The path runs %.1f mm outside the contrast-filled lumen: an occlusion, or points on two different vessels.",
                                                                            comment: "Curved MPR: the traced path crosses an occlusion, or joins two vessels"),
                                                          Double(path.longestGap)))
        }
        if path.isLumenFaint {
            lines.append(NSLocalizedString("The vessel hardly stands out from the tissue around it: the path may leave it.",
                                           comment: "Curved MPR: the traced vessel is too faint to tell from the myocardium"))
        }
        guard !lines.isEmpty else { return nil }
        let title = failures.isEmpty ? NSLocalizedString("Check the traced path", comment: "Curved MPR: title of the notice on a traced path")
            : failures.allSatisfy { $0 == .outOfMemory } ? NSLocalizedString("Not enough memory", comment: "")
            : NSLocalizedString("Can't find path", comment: "")
        return (title, lines.joined(separator: "\n\n"))
    }

    /// The notice of `path` as a sheet of `window`, which leaves the main
    /// thread free while it waits for its OK.
    private static func tell(_ path: VesselAssistedPath, in window: NSWindow?) {
        guard let window, let notice = notice(for: path) else { return }
        let alert = NSAlert()
        alert.messageText = notice.title
        alert.informativeText = notice.message
        alert.alertStyle = path.failures.isEmpty ? .informational : .warning
        alert.beginSheetModal(for: window)
    }

    /// The tracer's view of `data`, the floats `volumeData` reads, without a
    /// copy: the data object stays alive as long as a trace reads it. nil
    /// when it holds fewer floats than the volume has voxels.
    static func volume(of data: NSData, shapedAs volumeData: CPRVolumeData) -> VesselVolume? {
        let width = Int(volumeData.pixelsWide), height = Int(volumeData.pixelsHigh), depth = Int(volumeData.pixelsDeep)
        guard width > 0, height > 0, depth > 0, data.length >= width * height * depth * MemoryLayout<Float>.size else { return nil }
        let spacing = SIMD3(Float(volumeData.pixelSpacingX), Float(volumeData.pixelSpacingY), Float(volumeData.pixelSpacingZ))
        return VesselVolume(borrowing: data.bytes.assumingMemoryBound(to: Float.self), width: width, height: height, depth: depth,
                            spacing: spacing, keepingAlive: data)
    }
}

/// The share of a trace done, written on the tracer's thread and read by the sheet.
private final class TraceShare: Sendable {
    private let share = Mutex(0.0)

    func report(_ value: Double) { share.withLock { $0 = value } }

    var value: Double { share.withLock { $0 } }
}

/// The sheet of a trace that takes long: "Finding Path...", its progress, and
/// Cancel (Escape), sized from its translated texts.
@MainActor private final class CurvedMPRTraceSheet: NSObject {
    private let panel: NSPanel
    private let progress = NSProgressIndicator()
    private let onCancel: () -> Void
    private var updates: Task<Void, Never>?

    init(on window: NSWindow, share: TraceShare, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        super.init()

        let label = NSTextField(labelWithString: NSLocalizedString("Finding Path...", comment: ""))
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        let cancel = NSButton(title: NSLocalizedString("Cancel", comment: ""), target: self, action: #selector(cancelPressed(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), cancel])
        buttons.orientation = .horizontal
        let content = NSStackView(views: [label, progress, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for view in [progress, buttons] {
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20).isActive = true
        }
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        window.beginSheet(panel)

        updates = Task { [weak self] in
            while !Task.isCancelled, let self {
                self.progress.doubleValue = share.value
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    @objc private func cancelPressed(_ sender: Any?) {
        onCancel()
    }

    func close() {
        updates?.cancel()
        updates = nil
        if let parent = panel.sheetParent { parent.endSheet(panel) }
        panel.orderOut(nil)
    }
}
