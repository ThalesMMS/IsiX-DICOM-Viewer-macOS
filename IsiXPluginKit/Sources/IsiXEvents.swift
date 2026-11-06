//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

public enum IsiXROIChange: Hashable, Sendable {
    case added, modified, removed, selected
}

/// What one import added to the database. The application tells of an
/// import as it goes, one batch of images at a time, and once more when it
/// ends, with every image it added (`isComplete`).
public struct IsiXImagesAdded: Hashable, Sendable {
    public var images: [IsiXDatabaseImage]
    /// The SOP Instance UIDs of the images received from the network, by the
    /// AE title that sent them; empty for files imported from the disk.
    public var sopInstanceUIDsByCallingAETitle: [String: [String]]
    public var isComplete: Bool

    @_spi(IsiXHost)
    public init(images: [IsiXDatabaseImage], sopInstanceUIDsByCallingAETitle: [String: [String]], isComplete: Bool) {
        self.images = images
        self.sopInstanceUIDsByCallingAETitle = sopInstanceUIDsByCallingAETitle
        self.isComplete = isComplete
    }
}

/// Something that happened in the application, delivered on the main actor
/// to the observations of plugins that declared what it concerns: viewer
/// events need `viewer.read`, ROI events need `roi` too, and database events
/// need `database.read`.
public enum IsiXEvent: Hashable, Sendable {
    /// A viewer finished loading its series: when it opened, or when it
    /// replaced its series in the same window. Images read from it before a
    /// replacement are stale and cannot be committed.
    case viewerOpened(IsiXViewerID)
    /// The viewer's window is closing: its handles throw `viewerClosed` from now on.
    case viewerWillClose(IsiXViewerID)
    case sliceChanged(IsiXViewerID, IsiXSlicePosition)
    case roiChanged(IsiXViewerID, IsiXROIID, IsiXROIChange)
    /// Images entered the local database: imported, received from the
    /// network, retrieved or written by the application.
    case imagesAdded(IsiXImagesAdded)

    public var kind: IsiXEventKinds {
        switch self {
        case .viewerOpened: return .viewerOpened
        case .viewerWillClose: return .viewerWillClose
        case .sliceChanged: return .sliceChanged
        case .roiChanged: return .roiChanged
        case .imagesAdded: return .imagesAdded
        }
    }
}

public struct IsiXEventKinds: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let viewerOpened = IsiXEventKinds(rawValue: 1 << 0)
    public static let viewerWillClose = IsiXEventKinds(rawValue: 1 << 1)
    public static let sliceChanged = IsiXEventKinds(rawValue: 1 << 2)
    public static let roiChanged = IsiXEventKinds(rawValue: 1 << 3)
    public static let imagesAdded = IsiXEventKinds(rawValue: 1 << 4)
    public static let all: IsiXEventKinds = [.viewerOpened, .viewerWillClose, .sliceChanged, .roiChanged, .imagesAdded]
}

/// An observation registered with `IsiXPluginContext.observe(_:_:)`, an input
/// handler registered with `IsiXPluginContext.interceptInput(_:_:)` or an
/// overlay added with `IsiXViewer.addOverlay(_:)`. It delivers until
/// `invalidate()` is called, the token is released, or the plugin is
/// deactivated, whichever comes first; after that its handler is never called
/// again.
public final class IsiXObservation: Sendable {
    private let registry: ObservationRegistry
    private let key: Int

    init(registry: ObservationRegistry, key: Int) {
        self.registry = registry
        self.key = key
    }

    public var isActive: Bool { registry.contains(key) }

    public func invalidate() {
        registry.remove(key)
    }

    deinit {
        registry.remove(key)
    }
}

/// The handlers of one plugin: its event observations, input handlers and
/// overlays, under one sequence of keys. Delivery happens on the main actor;
/// removal may happen anywhere (a token released on another thread), hence
/// the lock.
final class ObservationRegistry: @unchecked Sendable {
    typealias Handler = @MainActor (IsiXEvent) -> Void
    typealias InputHandler = @MainActor (IsiXViewerInput) -> Bool
    typealias OverlayHandler = @MainActor (IsiXOverlayContext) -> Void

    private let lock = NSLock()
    private var nextKey = 0
    private var handlers: [Int: (IsiXEventKinds, Handler)] = [:]
    private var inputs: [Int: (IsiXInputKinds, InputHandler)] = [:]
    private var overlays: [Int: (IsiXViewerID, OverlayHandler)] = [:]
    private var closed = false

    private func nextFreeKey() -> Int? {
        guard !closed else { return nil }
        nextKey += 1
        return nextKey
    }

    func add(_ kinds: IsiXEventKinds, _ handler: @escaping Handler) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard let key = nextFreeKey() else { return nil }
        handlers[key] = (kinds, handler)
        return key
    }

    func addInput(_ kinds: IsiXInputKinds, _ handler: @escaping InputHandler) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard let key = nextFreeKey() else { return nil }
        inputs[key] = (kinds, handler)
        return key
    }

    func addOverlay(on viewer: IsiXViewerID, _ handler: @escaping OverlayHandler) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard let key = nextFreeKey() else { return nil }
        overlays[key] = (viewer, handler)
        return key
    }

    func contains(_ key: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return handlers[key] != nil || inputs[key] != nil || overlays[key] != nil
    }

    func remove(_ key: Int) {
        lock.lock(); defer { lock.unlock() }
        handlers[key] = nil
        inputs[key] = nil
        overlays[key] = nil
    }

    /// Removes every handler and refuses new ones.
    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        handlers.removeAll()
        inputs.removeAll()
        overlays.removeAll()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return handlers.count + inputs.count + overlays.count
    }

    /// The kinds of input some handler takes.
    var inputKinds: IsiXInputKinds {
        lock.lock(); defer { lock.unlock() }
        return inputs.values.reduce(into: IsiXInputKinds()) { $0.formUnion($1.0) }
    }

    func hasOverlays(on viewer: IsiXViewerID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return overlays.values.contains { $0.0 == viewer }
    }

    /// Asks every handler of the input's kind, in the order they were added;
    /// true when one of them took the input.
    @MainActor
    func deliver(_ input: IsiXViewerInput) -> Bool {
        lock.lock()
        let targets = inputs.sorted { $0.key < $1.key }.filter { $0.value.0.contains(input.kind.kinds) }.map(\.key)
        lock.unlock()
        var taken = false
        for key in targets {
            lock.lock()
            let handler = inputs[key]?.1
            lock.unlock()
            if handler?(input) == true { taken = true }
        }
        return taken
    }

    /// Calls the viewer's overlays, in the order they were added.
    @MainActor
    func draw(_ context: IsiXOverlayContext) {
        lock.lock()
        let targets = overlays.sorted { $0.key < $1.key }.filter { $0.value.0 == context.viewerID }.map(\.key)
        lock.unlock()
        for key in targets {
            lock.lock()
            let handler = overlays[key]?.1
            lock.unlock()
            guard let handler else { continue }
            // Each overlay starts from the image's coordinates, whatever the one before left.
            context.cgContext.saveGState()
            handler(context)
            context.cgContext.restoreGState()
        }
    }

    @MainActor
    func deliver(_ event: IsiXEvent) {
        lock.lock()
        let targets = handlers.sorted { $0.key < $1.key }.filter { $0.value.0.contains(event.kind) }.map(\.key)
        lock.unlock()
        for key in targets {
            // A handler may invalidate others while this runs: look each up again.
            lock.lock()
            let handler = handlers[key]?.1
            lock.unlock()
            handler?(event)
        }
    }
}
