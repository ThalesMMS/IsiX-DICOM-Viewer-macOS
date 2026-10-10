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

/// The planar pilot on Metal 4.
///
/// Same shader source, same textures, same window/CLUT arithmetic and the same
/// `PlanarFrame` as `PlanarMetalRenderer`: this is a submission experiment, not
/// a second renderer. What changes is how work reaches the GPU — a reusable
/// command buffer with per-frame allocators, an argument table instead of
/// per-encoder bindings, explicit residency, and commit feedback instead of a
/// blocking wait.
///
/// It is selected explicitly and never silently: the host asks for it, and a
/// device or a system without Metal 4 gets the existing backend with a reason.
///
/// @unchecked Sendable: the commit feedback handler holds the renderer weakly
/// on Metal's own thread. What it touches - the counters, `coalesced` and the
/// slots' `inFlight` and `retained` - is read and written only under `lock`
/// (`submit` holds it from encode to commit). `textures` belongs to the host
/// thread that calls `update`, `clear` and `submit`; the rest is constant.
@objc(HorosPlanarMetal4Renderer)
final class PlanarMetal4Renderer: NSObject, @unchecked Sendable {
    /// Immutable per-device library and pipelines. Only compiled artefacts are
    /// shared; nothing a viewer or a job can mutate lives here, and a failed
    /// compilation is never stored as a success.
    final class PipelineCache {
        struct Key: Hashable {
            let vertexFunction: String
            let fragmentFunction: String
            let colorFormat: UInt
            let sampleCount: Int
            let blending: Bool
        }

        private static let lock = NSLock()
        // nonisolated(unsafe): read and written only between `lock.lock()` and
        // `lock.unlock()`, as every use below shows. Remove when the lock
        // becomes a Mutex that holds it.
        nonisolated(unsafe) private static var caches: [ObjectIdentifier: PipelineCache] = [:]

        static func shared(for device: MTLDevice) throws -> PipelineCache {
            lock.lock()
            defer { lock.unlock() }
            let identifier = ObjectIdentifier(device)
            if let existing = caches[identifier] { return existing }
            // A library that does not compile throws here, and nothing is
            // registered: the next attempt compiles again rather than being
            // served a failure.
            let cache = try PipelineCache(device: device, source: PlanarMetalRenderer.shader)
            caches[identifier] = cache
            return cache
        }

        /// Build a cache without registering it for the device. Metal 4 reports
        /// a shader problem when the library is built, not when a pipeline is
        /// made from it, so this is where a compilation failure can be observed.
        static func make(device: MTLDevice, source: String) throws -> PipelineCache {
            try PipelineCache(device: device, source: source)
        }

        /// Forget the caches; a test needs a cold compile to measure one.
        static func removeAll() {
            lock.lock()
            defer { lock.unlock() }
            caches.removeAll()
        }

        let device: MTLDevice
        let compiler: MTL4Compiler
        private let library: MTLLibrary
        private let cacheLock = NSLock()
        private var pipelines: [Key: MTLRenderPipelineState] = [:]
        private(set) var compileCount = 0
        private(set) var hitCount = 0

        private init(device: MTLDevice, source: String) throws {
            self.device = device
            compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
            let descriptor = MTL4LibraryDescriptor()
            descriptor.source = source
            library = try compiler.makeLibrary(descriptor: descriptor)
        }

        func pipeline(for key: Key) throws -> MTLRenderPipelineState {
            cacheLock.lock()
            if let existing = pipelines[key] {
                hitCount += 1
                cacheLock.unlock()
                return existing
            }
            cacheLock.unlock()

            let vertex = MTL4LibraryFunctionDescriptor()
            vertex.name = key.vertexFunction
            vertex.library = library
            let fragment = MTL4LibraryFunctionDescriptor()
            fragment.name = key.fragmentFunction
            fragment.library = library
            let descriptor = MTL4RenderPipelineDescriptor()
            descriptor.vertexFunctionDescriptor = vertex
            descriptor.fragmentFunctionDescriptor = fragment
            descriptor.rasterSampleCount = key.sampleCount
            descriptor.colorAttachments[0].pixelFormat = MTLPixelFormat(rawValue: key.colorFormat) ?? .bgra8Unorm
            descriptor.colorAttachments[0].blendingState = key.blending ? .enabled : .disabled
            if key.blending {
                // The host's fusion blend: GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA
                // on every channel, alpha included.
                let attachment = descriptor.colorAttachments[0]!
                attachment.rgbBlendOperation = .add; attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .sourceAlpha; attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .sourceAlpha; attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            // A compilation that throws leaves the cache as it was.
            let state = try compiler.makeRenderPipelineState(descriptor: descriptor)
            cacheLock.lock()
            pipelines[key] = state
            compileCount += 1
            cacheLock.unlock()
            return state
        }
    }

    /// One in-flight submission's own resources. Nothing here is touched again
    /// until its commit feedback says the GPU is done with it.
    ///
    /// @unchecked Sendable: the feedback handler releases the slot on Metal's
    /// thread. `inFlight` and `retained` change only under the renderer's
    /// `lock`; the Metal objects are constant.
    private final class Slot: @unchecked Sendable {
        /// One layer's four parameter vectors.
        static let layerBytes = 4 * MemoryLayout<SIMD4<Float>>.stride
        /// A buffer layer's size and format, after both layers' parameters.
        static let sourceBytes = MemoryLayout<SIMD4<UInt32>>.stride

        let allocator: MTL4CommandAllocator
        /// The image's parameters, then the fused series'.
        let uniforms: MTLBuffer
        let argumentTable: MTL4ArgumentTable
        /// The fused series' bindings, a table of their own so the
        /// image's draw keeps what it was encoded with.
        let fusionTable: MTL4ArgumentTable
        let residency: MTLResidencySet
        var inFlight = false
        var retained: [MTLResource] = []

        init(device: MTLDevice) throws {
            guard let allocator = device.makeCommandAllocator(),
                  let uniforms = device.makeBuffer(length: 2 * Self.layerBytes + 2 * Self.sourceBytes, options: .storageModeShared) else {
                throw PlanarMetalRenderer.failure()
            }
            self.allocator = allocator
            self.uniforms = uniforms
            let table = MTL4ArgumentTableDescriptor()
            // Parameters, and for a layer read from a buffer its pixels
            // and their size and format.
            table.maxBufferBindCount = 3
            table.maxTextureBindCount = 2
            table.initializeBindings = true
            argumentTable = try device.makeArgumentTable(descriptor: table)
            fusionTable = try device.makeArgumentTable(descriptor: table)
            let descriptor = MTLResidencySetDescriptor()
            descriptor.initialCapacity = 4
            residency = try device.makeResidencySet(descriptor: descriptor)
            residency.addAllocation(uniforms)
            residency.commit()
        }

        /// Give back everything this submission owned. Called only after the
        /// GPU has reported completion, or after an encode that never started.
        func release() {
            for resource in retained { residency.removeAllocation(resource) }
            residency.commit()
            retained.removeAll(keepingCapacity: true)
            inFlight = false
        }
    }

    static let slotCount = 3

    let device: MTLDevice
    private let queue: MTL4CommandQueue
    private let commandBuffer: MTL4CommandBuffer
    private let cache: PipelineCache
    private let pipeline: MTLRenderPipelineState
    private let fusionPipeline: MTLRenderPipelineState
    /// The same two draws for a layer read from a buffer.
    private let bufferPipeline: MTLRenderPipelineState
    private let bufferFusionPipeline: MTLRenderPipelineState
    private var slots: [Slot]
    private var textures: PlanarTextures?
    var image: MTLTexture? { textures?.image }
    /// Read-only validation access to an uploaded layer; never a large-image placeholder.
    func uploadedTexture(layer: Int) -> MTLTexture? {
        guard let textures else { return nil }
        switch layer {
        case 0: return textures.buffer == nil ? textures.image : nil
        case 1: return textures.fused?.buffer == nil ? textures.fused?.image : nil
        default: return nil
        }
    }


    /// A request that arrived while every slot was busy, kept as the newest one
    /// only. The queue never grows, so the UI is never asked to wait for it.
    private var coalesced: (@Sendable () -> Void)?
    /// Commit feedback arrives on Metal's own thread while the host encodes on
    /// the main one. Recursive, so a feedback handler delivered inline during a
    /// commit cannot deadlock against the encode holding it.
    private let lock = NSRecursiveLock()
    private var _coalescedCount = 0
    private var _submittedCount = 0
    private var _completedCount = 0
    private var _failedCount = 0
    private var _lastGPUMilliseconds: Double = 0
    private var _lastEncodeMilliseconds: Double = 0

    var coalescedCount: Int { lock.withLock { _coalescedCount } }
    var submittedCount: Int { lock.withLock { _submittedCount } }
    var completedCount: Int { lock.withLock { _completedCount } }
    var failedCount: Int { lock.withLock { _failedCount } }
    /// The GPU's own start/end difference for the last completed submission.
    /// A submission whose timestamps are missing leaves this unchanged rather
    /// than reporting zero.
    @objc var lastGPUMilliseconds: Double { lock.withLock { _lastGPUMilliseconds } }
    /// Entry to the point the commit call returned, on the calling thread.
    @objc var lastEncodeMilliseconds: Double { lock.withLock { _lastEncodeMilliseconds } }

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeMTL4CommandQueue(),
              let commandBuffer = device.makeCommandBuffer() else { throw PlanarMetalRenderer.failure() }
        self.queue = queue
        self.commandBuffer = commandBuffer
        cache = try PipelineCache.shared(for: device)
        pipeline = try cache.pipeline(for: PipelineCache.Key(
            vertexFunction: "planarVertex", fragmentFunction: "planarFragment",
            colorFormat: MTLPixelFormat.bgra8Unorm.rawValue, sampleCount: 1, blending: false))
        fusionPipeline = try cache.pipeline(for: PipelineCache.Key(
            vertexFunction: "planarVertex", fragmentFunction: "planarFusionFragment",
            colorFormat: MTLPixelFormat.bgra8Unorm.rawValue, sampleCount: 1, blending: true))
        bufferPipeline = try cache.pipeline(for: PipelineCache.Key(
            vertexFunction: "planarVertex", fragmentFunction: "planarBufferFragment",
            colorFormat: MTLPixelFormat.bgra8Unorm.rawValue, sampleCount: 1, blending: false))
        bufferFusionPipeline = try cache.pipeline(for: PipelineCache.Key(
            vertexFunction: "planarVertex", fragmentFunction: "planarBufferFusionFragment",
            colorFormat: MTLPixelFormat.bgra8Unorm.rawValue, sampleCount: 1, blending: true))
        slots = try (0..<Self.slotCount).map { _ in try Slot(device: device) }
        super.init()
    }

    /// Whether this system and device can run the pilot at all.
    @objc static func isSupported(_ device: MTLDevice) -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        guard device.makeMTL4CommandQueue() != nil, device.makeCommandAllocator() != nil else { return false }
        return (try? device.makeCompiler(descriptor: MTL4CompilerDescriptor())) != nil
    }

    func update(_ next: PlanarFrame) throws {
        // The same upload as the backend in use, opacity-table pass and fused
        // series included: the pilot changes how a frame is submitted, not
        // what it samples. A texture an in-flight submission is sampling is
        // never overwritten: a changed layer gets new ones, and the old ones
        // stay alive in the slot that retains them until the GPU reports
        // completion.
        textures = try PlanarTextures(next, reusing: textures, device: device)
    }

    func clear() {
        // The feedback handler takes `coalesced` under the lock on Metal's
        // thread; clearing it without the lock raced with that.
        lock.withLock {
            textures = nil
            coalesced = nil
        }
    }

    /// Encode and commit one frame. Returns false when every slot is busy.
    ///
    /// With `coalescing` the work is then kept as the newest pending request
    /// and run when a slot frees, which is what a redraw wants: the latest
    /// state, never a queue that grows behind the UI. A caller that paces
    /// itself asks for no coalescing and submits again when it chooses.
    ///
    /// `completion` runs on Metal's own feedback queue, not on the main
    /// thread, so that a caller waiting for one frame is not forced to drain a
    /// run loop while AppKit is half way through a draw. A completion that
    /// touches the UI has to hop to the main queue itself.
    @discardableResult
    func submit(into target: MTLTexture, coalescing: Bool = true,
                completion: @escaping @Sendable (Error?) -> Void) throws -> Bool {
        let encodeStartedAt = ProcessInfo.processInfo.systemUptime
        let traceStart = MetalPerformanceTrace.now()
        lock.lock()
        defer { lock.unlock() }
        guard let textures else { throw PlanarMetalRenderer.failure() }
        guard let slot = slots.first(where: { !$0.inFlight }) else {
            guard coalescing else { return false }
            _coalescedCount += 1
            // nonisolated(unsafe): the target is only encoded into again by the
            // coalesced redraw, on the main queue, after this submission has
            // handed it over; nothing else writes it meanwhile.
            nonisolated(unsafe) let target = target
            coalesced = { [weak self] in
                guard let self else { return }
                _ = try? self.submit(into: target, coalescing: true, completion: completion)
            }
            return false
        }

        slot.inFlight = true
        slot.allocator.reset()
        commandBuffer.beginCommandBuffer(allocator: slot.allocator)

        let pass = MTL4RenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        // Residency and retention for exactly what this submission reads and
        // writes; released only by its own feedback handler.
        slot.retained = textures.resources + [target]
        for resource in slot.retained { slot.residency.addAllocation(resource) }
        slot.residency.commit()
        commandBuffer.useResidencySet(slot.residency)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            commandBuffer.endCommandBuffer()
            slot.release()
            throw PlanarMetalRenderer.failure()
        }

        let parameters = PlanarMetalRenderer.parameters(for: textures.frame, width: target.width, height: target.height)
        parameters.withUnsafeBytes { bytes in
            slot.uniforms.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        slot.argumentTable.setAddress(slot.uniforms.gpuAddress, index: 0)
        // Both texture slots are set on every draw, so a monochrome frame can
        // never sample what a colour frame left behind, or the other way round.
        slot.argumentTable.setTexture(textures.image.gpuResourceID, index: 0)
        slot.argumentTable.setTexture(textures.clut.gpuResourceID, index: 1)
        let sourceOffset = 2 * Slot.layerBytes
        if let buffer = textures.buffer {
            (slot.uniforms.contents() + sourceOffset).storeBytes(of: buffer.info, as: SIMD4<UInt32>.self)
            slot.argumentTable.setAddress(buffer.pixels.gpuAddress, index: 1)
            slot.argumentTable.setAddress(slot.uniforms.gpuAddress + UInt64(sourceOffset), index: 2)
        }

        encoder.setRenderPipelineState(textures.buffer == nil ? pipeline : bufferPipeline)
        encoder.setArgumentTable(slot.argumentTable, stages: .fragment)
        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
        // The fused series over the image, in the host's order.
        if let fused = textures.fused, let layer = textures.frame.fusion.first {
            let fusedParameters = PlanarMetalRenderer.parameters(for: layer, width: target.width, height: target.height)
            fusedParameters.withUnsafeBytes { bytes in
                (slot.uniforms.contents() + Slot.layerBytes).copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            }
            slot.fusionTable.setAddress(slot.uniforms.gpuAddress + UInt64(Slot.layerBytes), index: 0)
            slot.fusionTable.setTexture(fused.image.gpuResourceID, index: 0)
            slot.fusionTable.setTexture(fused.clut.gpuResourceID, index: 1)
            if let buffer = fused.buffer {
                let offset = sourceOffset + Slot.sourceBytes
                (slot.uniforms.contents() + offset).storeBytes(of: buffer.info, as: SIMD4<UInt32>.self)
                slot.fusionTable.setAddress(buffer.pixels.gpuAddress, index: 1)
                slot.fusionTable.setAddress(slot.uniforms.gpuAddress + UInt64(offset), index: 2)
            }
            encoder.setRenderPipelineState(fused.buffer == nil ? fusionPipeline : bufferFusionPipeline)
            encoder.setArgumentTable(slot.fusionTable, stages: .fragment)
            encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        commandBuffer.endCommandBuffer()

        // A fresh options object per submission. The origin recorded a hang
        // from reusing one across commits; the header says the class is not
        // thread-safe and the handler is retained by the options themselves.
        let options = MTL4CommitOptions()
        let once = OnceFlag()
        let committedAt = MetalPerformanceTrace.now()
        let targetWidth = target.width, targetHeight = target.height
        options.addFeedbackHandler { [weak self] feedback in
            // Exactly once, whatever the driver does with a reused handler.
            guard once.claim() else { return }
            MetalPerformanceTrace.record("planar.metal4.render", startedAt: traceStart, committedAt: committedAt,
                                         observedAt: MetalPerformanceTrace.now(), gpuStartTime: feedback.gpuStartTime,
                                         gpuEndTime: feedback.gpuEndTime, failed: feedback.error != nil,
                                         extra: ["width": targetWidth, "height": targetHeight])
            var pending: (@Sendable () -> Void)?
            if let self {
                // Metal 4 does not retain what a submission used; this handler
                // is the only place that may give the slot back.
                self.lock.lock()
                if feedback.error != nil { self._failedCount += 1 } else { self._completedCount += 1 }
                let gpu = feedback.gpuEndTime - feedback.gpuStartTime
                // A missing timestamp is not a measurement of zero, and not the
                // previous submission's either: -1, which the host reads as
                // "not measured".
                if feedback.gpuEndTime > 0, feedback.gpuStartTime > 0, gpu >= 0 {
                    self._lastGPUMilliseconds = gpu * 1000
                } else {
                    self._lastGPUMilliseconds = -1
                }
                slot.release()
                pending = self.coalesced
                self.coalesced = nil
                self.lock.unlock()
            }
            completion(feedback.error)
            // A coalesced redraw belongs to the host's thread, not to Metal's.
            if let pending { DispatchQueue.main.async(execute: pending) }
        }
        queue.commit([commandBuffer], options: options)
        _lastEncodeMilliseconds = (ProcessInfo.processInfo.systemUptime - encodeStartedAt) * 1000
        _submittedCount += 1
        return true
    }

    /// One completion per submission, however the driver delivers feedback.
    ///
    /// @unchecked Sendable: `claimed` is read and written only under `lock`,
    /// the lock it always had on this per-frame path.
    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }

    /// Render one frame and wait for it, the way the OpenGL host composition
    /// requires. Kept separate from `submit` so the asynchronous path is not
    /// forced to grow a wait.
    func renderTexture(width: Int, height: Int) throws -> MTLTexture {
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { throw PlanarMetalRenderer.failure() }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = PlanarMetalRenderer.readbackStorageMode
        descriptor.usage = .renderTarget
        guard let target = device.makeTexture(descriptor: descriptor) else { throw PlanarMetalRenderer.failure() }
        try render(into: target)
        try PlanarMetalRenderer.bringToCPU(target, queue: nil)
        return target
    }

    /// Submit into an existing target and wait for the GPU to finish with it.
    ///
    /// The feedback handler runs on Metal's thread and signals directly, so a
    /// caller on the main thread waits without draining its run loop - drawing
    /// must not re-enter AppKit while a frame is half composed.
    func render(into target: MTLTexture) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ErrorBox()
        let submitted = try submit(into: target, coalescing: false) { error in
            box.value = error
            semaphore.signal()
        }
        guard submitted else { throw PlanarMetalRenderer.failure() }
        guard semaphore.wait(timeout: .now() + 5) == .success else { throw PlanarMetalRenderer.failure() }
        if let error = box.value { throw error }
    }

    /// @unchecked Sendable: written by the feedback handler on Metal's thread,
    /// read by the waiting caller; `stored` only under `lock`.
    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Error?
        var value: Error? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    func renderBGRA(width: Int, height: Int) throws -> Data {
        let target = try renderTexture(width: width, height: height)
        var result = Data(count: width * height * 4)
        result.withUnsafeMutableBytes { bytes in
            target.getBytes(bytes.baseAddress!, bytesPerRow: width * 4,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return result
    }

    var pipelineCompileCount: Int { cache.compileCount }
    var pipelineHitCount: Int { cache.hitCount }
}
