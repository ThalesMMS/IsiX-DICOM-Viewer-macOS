//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation
import Metal

/// The submission the MPR and VR compute engines use.
public enum MetalComputeBackend: Int, Sendable {
    /// `MTLCommandQueue` command buffers, waited for with `waitUntilCompleted`.
    case metal3 = 3
    /// `MTL4CommandQueue` with reused command buffers, allocators and argument tables, explicit residency and
    /// commit feedback.
    case metal4 = 4

    /// The backend the host's MPR and VR bridges use unless `HorosMetal4Compute` says otherwise: Metal 4 since
    /// its campaign found nothing slower than Metal 3. Metal 3 stays selectable with
    /// `HorosMetal4Compute NO` for rollback. An engine made directly still takes the backend it is given.
    public static let standard: MetalComputeBackend = .metal4

    /// What the host asks for on `device`: `HorosMetal4Compute` YES or NO when set, else `standard`; Metal 4 only
    /// where the device supports it, with the reason when it does not.
    public static func host(device: MTLDevice, defaults: UserDefaults = .standard) -> (backend: MetalComputeBackend, reason: String?) {
        let wanted: MetalComputeBackend = defaults.object(forKey: "HorosMetal4Compute") == nil
            ? standard : (defaults.bool(forKey: "HorosMetal4Compute") ? .metal4 : .metal3)
        guard wanted == .metal4 else { return (.metal3, nil) }
        return Metal4ComputeSubmitter.isSupported(device) ? (.metal4, nil) : (.metal3, "This device has no Metal 4 submission.")
    }

    public var name: String { self == .metal4 ? "Metal 4" : "Metal 3" }
}

/// Runs one compute dispatch at a time per slot on Metal 4 and waits for its commit feedback.
///
/// The engines' kernels, pipelines and results do not change; only the submission does. The model is the one
/// the planar Metal 4 renderer uses, which follows the reference's ROI and surface passes (bd47b643):
/// - A slot is one job's mutable state: a command allocator, a command buffer, an argument table, a residency
///   set and the uniforms buffer. A job has its slot to itself from encoding until its feedback arrives, and
///   only the feedback handler gives it back, once, whatever the outcome. The allocator is reset when the slot
///   is taken again, never while the GPU may still use what it allocated.
/// - The uniforms are copied into the slot's own buffer, so no dispatch reads parameters another one wrote.
/// - Everything a job binds is made residency-set allocations for that job, and retained by the slot until the
///   feedback, since Metal 4 retains nothing for the command buffer.
/// - Every commit gets new commit options and its own feedback handler.
/// - One dispatch per command buffer, so no pass consumes what another in the same buffer produces and no
///   barrier is needed. A caller that copies results out does so after the feedback.
/// - The caller waits for the feedback: the engines' contract stays synchronous, and nothing here is presented
///   as an asynchronous gain.
/// One submitter per device, shared by every MPR and VR engine on it: the queue and the idle slots are not an
/// engine's to own, and making them for every engine made opening a window slower than on Metal 3. Slots are
/// made when every existing one is busy and kept for reuse, at most `keptSlots` of them, each able to bind what
/// either engine binds.
///
/// @unchecked Sendable: one submitter serves every engine of a device, from their threads and from Metal's
/// feedback thread. `idle`, `slotCount` and `inFlightCount` are read and written only under `lock`; the
/// device and the queue are constant.
final class Metal4ComputeSubmitter: @unchecked Sendable {
    struct Times {
        let committedAt: CFTimeInterval?, observedAt: CFTimeInterval?
        let gpuStartTime: CFTimeInterval, gpuEndTime: CFTimeInterval
    }

    static let keptSlots = 8
    /// What a slot binds: enough for the VR render (six buffers, two textures, its 320-byte parameters).
    static let bufferCapacity = 8, textureCapacity = 4, uniformCapacity = 1024
    /// Longer than any frame or upload of these engines; a job not done by then is reported as failed, and its
    /// slot comes back only with its feedback.
    static let timeout: TimeInterval = 30

    private static let registryLock = NSLock()
    // nonisolated(unsafe): read and written only inside `registryLock.withLock`, as every
    // use below shows. Remove when the lock becomes a Mutex that holds it.
    nonisolated(unsafe) private static var submitters: [UInt64: Metal4ComputeSubmitter] = [:]
    nonisolated(unsafe) private static var support: [UInt64: Bool] = [:]

    /// Whether this device can run Metal 4 submission at all; asked once per device.
    static func isSupported(_ device: MTLDevice) -> Bool {
        if let known = registryLock.withLock({ support[device.registryID] }) { return known }
        let supported = device.makeMTL4CommandQueue() != nil && device.makeCommandAllocator() != nil
            && (try? device.makeResidencySet(descriptor: MTLResidencySetDescriptor())) != nil
        registryLock.withLock { support[device.registryID] = supported }
        return supported
    }

    /// The device's submitter, made by the first engine that asks.
    static func shared(for device: MTLDevice) throws -> Metal4ComputeSubmitter {
        try registryLock.withLock {
            if let existing = submitters[device.registryID] { return existing }
            let made = try Metal4ComputeSubmitter(device: device)
            submitters[device.registryID] = made
            return made
        }
    }

    /// @unchecked Sendable: a slot has one owner at a time - the job from `takeSlot` to its commit, then that
    /// job's feedback handler, which gives it back - and an idle slot is reached only under the submitter's
    /// `lock`. `retained` changes only in the owner; the Metal objects are constant.
    private final class Slot: @unchecked Sendable {
        let allocator: MTL4CommandAllocator
        let commandBuffer: MTL4CommandBuffer
        let arguments: MTL4ArgumentTable
        let residency: MTLResidencySet
        let uniforms: MTLBuffer
        var retained: [MTLResource] = []

        init(device: MTLDevice, buffers: Int, textures: Int, uniformLength: Int) throws {
            guard let allocator = device.makeCommandAllocator(), let commandBuffer = device.makeCommandBuffer(),
                  let uniforms = device.makeBuffer(length: uniformLength, options: .storageModeShared) else {
                throw ResliceFailure.device("Metal 4 could not make a command allocator, a command buffer or a uniforms buffer.")
            }
            let table = MTL4ArgumentTableDescriptor()
            table.maxBufferBindCount = buffers
            table.maxTextureBindCount = textures
            table.initializeBindings = true
            let descriptor = MTLResidencySetDescriptor()
            descriptor.initialCapacity = buffers + textures
            self.allocator = allocator
            self.commandBuffer = commandBuffer
            self.uniforms = uniforms
            arguments = try device.makeArgumentTable(descriptor: table)
            residency = try device.makeResidencySet(descriptor: descriptor)
        }
    }

    /// One completion per job, however the driver delivers feedback.
    /// @unchecked Sendable: `claimed` only under `lock`, kept as it is on this per-job path.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool { lock.withLock { if claimed { return false }; claimed = true; return true } }
    }

    /// @unchecked Sendable: `stored` only under `lock`, set by the feedback handler before `done` is signalled.
    private final class Outcome: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var stored: (error: Error?, gpuStart: CFTimeInterval, gpuEnd: CFTimeInterval, observedAt: CFTimeInterval?)?
        func set(_ value: (error: Error?, gpuStart: CFTimeInterval, gpuEnd: CFTimeInterval, observedAt: CFTimeInterval?)) {
            lock.withLock { stored = value }
        }
        var value: (error: Error?, gpuStart: CFTimeInterval, gpuEnd: CFTimeInterval, observedAt: CFTimeInterval?)? {
            lock.withLock { stored }
        }
    }

    let device: MTLDevice
    private let queue: MTL4CommandQueue
    private let lock = NSLock()
    // Under lock.
    private var idle: [Slot] = []
    private var slotCount = 0, inFlightCount = 0

    private init(device: MTLDevice) throws {
        guard let queue = device.makeMTL4CommandQueue() else {
            throw ResliceFailure.device("Metal 4 is not available on this device.")
        }
        self.device = device
        self.queue = queue
    }

    /// Slots made so far, and how many jobs hold one now.
    var slots: (made: Int, inFlight: Int, idle: Int) { lock.withLock { (slotCount, inFlightCount, idle.count) } }

    /// Encodes one dispatch of `pipeline`, commits it and waits for its feedback.
    ///
    /// `textures[i]` and `buffers[i]` are bound at index `i`. With a `uniformsIndex`, `parameters` are copied into
    /// the slot's uniforms buffer, which is bound at that index in place of the entry of `buffers`. `groups`
    /// dispatches `size` threadgroups instead of `size` threads. `resident` is a set the caller keeps with some of
    /// these resources (a volume, from its upload), and `residentResources` names what it holds: those are not
    /// added to the job's own set again; `residentSets` are more such sets (an RGB plane's three channel volumes).
    /// Nothing here allocates per job beyond what Metal does.
    func dispatch(pipeline: MTLComputePipelineState, textures: [MTLTexture], buffers: [MTLBuffer?],
                  uniformsIndex: Int?, parameters: UnsafeRawBufferPointer,
                  size: MTLSize, threadsPerThreadgroup: MTLSize, groups: Bool = false,
                  resident: MTLResidencySet? = nil, residentSets: [MTLResidencySet] = [],
                  residentResources: Set<ObjectIdentifier> = []) throws -> Times {
        precondition(textures.count <= Self.textureCapacity && buffers.count <= Self.bufferCapacity
                     && parameters.count <= Self.uniformCapacity && (uniformsIndex.map { $0 < Self.bufferCapacity } ?? true))
        let slot = try takeSlot()
        slot.allocator.reset()
        slot.commandBuffer.beginCommandBuffer(allocator: slot.allocator)
        parameters.baseAddress.map { slot.uniforms.contents().copyMemory(from: $0, byteCount: parameters.count) }
        slot.retained.append(slot.uniforms)
        slot.residency.addAllocation(slot.uniforms)
        for (index, texture) in textures.enumerated() {
            slot.arguments.setTexture(texture.gpuResourceID, index: index)
            slot.retained.append(texture)
            if !residentResources.contains(ObjectIdentifier(texture)) { slot.residency.addAllocation(texture) }
        }
        for (index, buffer) in buffers.enumerated() {
            if index == uniformsIndex {
                slot.arguments.setAddress(slot.uniforms.gpuAddress, index: index)
            } else if let buffer {
                slot.arguments.setAddress(buffer.gpuAddress, index: index)
                slot.retained.append(buffer)
                if !residentResources.contains(ObjectIdentifier(buffer)) { slot.residency.addAllocation(buffer) }
            }
        }
        if let uniformsIndex, uniformsIndex >= buffers.count { slot.arguments.setAddress(slot.uniforms.gpuAddress, index: uniformsIndex) }
        slot.residency.commit()
        slot.commandBuffer.useResidencySet(slot.residency)
        if let resident { slot.commandBuffer.useResidencySet(resident) }
        if !residentSets.isEmpty { slot.commandBuffer.useResidencySets(residentSets) }
        guard let encoder = slot.commandBuffer.makeComputeCommandEncoder() else {
            slot.commandBuffer.endCommandBuffer()
            giveBack(slot)
            throw ResliceFailure.device("Metal 4 cannot encode the compute pass.")
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setArgumentTable(slot.arguments)
        if groups {
            encoder.dispatchThreadgroups(threadgroupsPerGrid: size, threadsPerThreadgroup: threadsPerThreadgroup)
        } else {
            encoder.dispatchThreads(threadsPerGrid: size, threadsPerThreadgroup: threadsPerThreadgroup)
        }
        encoder.endEncoding()
        slot.commandBuffer.endCommandBuffer()

        let outcome = Outcome()
        let once = Once()
        let options = MTL4CommitOptions()
        options.addFeedbackHandler { [weak self] feedback in
            guard once.claim() else { return }
            outcome.set((feedback.error, feedback.gpuStartTime, feedback.gpuEndTime, MetalPerformanceTrace.now()))
            // The only place that gives the slot back.
            if let self { self.giveBack(slot) }
            outcome.done.signal()
        }
        let committedAt = MetalPerformanceTrace.now()
        queue.commit([slot.commandBuffer], options: options)
        guard outcome.done.wait(timeout: .now() + Self.timeout) == .success, let result = outcome.value else {
            throw ResliceFailure.device("The GPU did not finish the compute pass in \(Int(Self.timeout)) s.")
        }
        if let error = result.error { throw error }
        return Times(committedAt: committedAt, observedAt: result.observedAt,
                     gpuStartTime: result.gpuStart, gpuEndTime: result.gpuEnd)
    }

    private func takeSlot() throws -> Slot {
        let reused: Slot? = lock.withLock {
            if let slot = idle.popLast() {
                inFlightCount += 1
                return slot
            }
            return nil
        }
        if let reused { return reused }
        let made = try Slot(device: device, buffers: Self.bufferCapacity, textures: Self.textureCapacity,
                            uniformLength: Self.uniformCapacity)
        lock.withLock { slotCount += 1; inFlightCount += 1 }
        return made
    }

    private func giveBack(_ slot: Slot) {
        slot.residency.removeAllAllocations()
        slot.residency.commit()
        slot.retained.removeAll(keepingCapacity: true)
        lock.withLock {
            inFlightCount -= 1
            if idle.count < Self.keptSlots { idle.append(slot) } else { slotCount -= 1 }
        }
    }
}
