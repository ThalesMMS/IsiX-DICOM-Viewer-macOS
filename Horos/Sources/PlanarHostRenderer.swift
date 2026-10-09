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

import AppKit
import Metal
import QuartzCore

/// Which submission path presents the planar pixels.
///
/// The pilot is chosen explicitly, never by availability alone, and a system or
/// device without Metal 4 falls back to the backend in use with a reason the
/// host can show. Nothing about the image, the geometry or the overlays differs
/// between the two: they share the shader, the textures and `PlanarFrame`.
enum PlanarBackend {
    case metal3(PlanarMetalRenderer)
    case metal4(PlanarMetal4Renderer)

    /// The user default that asks for the pilot. Absent means the backend in use.
    static let pilotDefaultsKey = "HorosPlanarMetal4Pilot"

    static func make(device: MTLDevice, wantsPilot: Bool) throws -> (PlanarBackend, String?) {
        guard wantsPilot else { return (.metal3(try PlanarMetalRenderer(device: device)), nil) }
        guard PlanarMetal4Renderer.isSupported(device) else {
            return (.metal3(try PlanarMetalRenderer(device: device)),
                    NSLocalizedString("This graphics device has no Metal 4; the viewer is using the existing renderer.",
                                      comment: ""))
        }
        do {
            return (.metal4(try PlanarMetal4Renderer(device: device)), nil)
        } catch {
            return (.metal3(try PlanarMetalRenderer(device: device)), error.localizedDescription)
        }
    }

    var device: MTLDevice {
        switch self {
        case .metal3(let renderer): return renderer.device
        case .metal4(let renderer): return renderer.device
        }
    }

    var name: String {
        switch self {
        case .metal3: return "Metal 3"
        case .metal4: return "Metal 4 pilot"
        }
    }

    func update(_ frame: PlanarFrame) throws {
        switch self {
        case .metal3(let renderer): try renderer.update(frame)
        case .metal4(let renderer): try renderer.update(frame)
        }
    }

    func uploadedTexture(layer: Int) -> MTLTexture? {
        switch self {
        case .metal3(let renderer): return renderer.uploadedTexture(layer: layer)
        case .metal4(let renderer): return renderer.uploadedTexture(layer: layer)
        }
    }

    func clear() {
        switch self {
        case .metal3(let renderer): renderer.clear()
        case .metal4(let renderer): renderer.clear()
        }
    }

    /// Draw and wait: the drawable is presented with the Core Animation
    /// transaction that shows the view's graphics and text, and a capture reads
    /// the target back, so neither may be handed over while the GPU writes it.
    func render(into target: MTLTexture) throws -> Double {
        switch self {
        case .metal3(let renderer):
            let traceStart = MetalPerformanceTrace.now()
            guard let command = renderer.queue.makeCommandBuffer() else { throw PlanarMetalRenderer.failure() }
            try renderer.encode(into: target, command: command)
            let committedAt = MetalPerformanceTrace.now()
            command.commit()
            command.waitUntilCompleted()
            let completedAt = MetalPerformanceTrace.now()
            MetalPerformanceTrace.record("planar.metal3.render", startedAt: traceStart, committedAt: committedAt,
                                         completedAt: completedAt, command: command, finishedAt: completedAt,
                                         extra: ["width": target.width, "height": target.height])
            guard command.status == .completed else { throw command.error ?? PlanarMetalRenderer.failure() }
            // A command buffer without timestamps is not a zero-millisecond draw:
            // -1 is what the host already reads as "not measured".
            let gpu = command.gpuEndTime - command.gpuStartTime
            return command.gpuStartTime > 0 && gpu >= 0 ? gpu * 1000 : -1
        case .metal4(let renderer):
            try renderer.render(into: target)
            return renderer.lastGPUMilliseconds
        }
    }
}

/// The DCMView's picture, drawn by Metal into the view's CAMetalLayer.
/// The host still owns input, geometry, graphics, ROIs and plugin
/// notifications. No viewer or database is retained here, and only immutable
/// decoded snapshots reach Metal.
@MainActor @objc(HorosPlanarHostRenderer)
public final class PlanarHostRenderer: NSObject {
    private var renderer: PlanarBackend?
    private var frame: PlanarFrame?
    private var identity: VolumeIdentity?
    private var sessionID: Int?
    private var passes: PlanarFinishingPasses?
    private weak var presentedLayer: CAMetalLayer?
    private var presentation: (frame: PlanarFrame, size: CGSize, inverted: Bool)?
    @objc public private(set) var failureReason: String?

    /// For integration probes: the GPU time of the last frame's command.
    @objc public private(set) var gpuMilliseconds: Double = 0
    @objc public private(set) var renderedFrameCount: Int = 0
    @objc public private(set) var encodedGPUCommand = false

    /// Which submission path drew the last frame, for the record and the trace.
    @objc public var backendName: String { renderer?.name ?? "" }

    /// The device the view's layer presents with.
    @objc public static let device: MTLDevice? = MTLCreateSystemDefaultDevice()

    /// Validation reads the immutable upload already used by the last frame.
    /// Main-actor callers retain this shared texture until readback completes.
    /// No upload, render, queue wait or drawable is created by this accessor.
    @objc(uploadedTextureForLayer:)
    func uploadedTexture(layer: Int) -> MTLTexture? {
        precondition(Thread.isMainThread)
        guard let texture = renderer?.uploadedTexture(layer: layer),
              texture.storageMode == .shared,
              texture.pixelFormat == .r32Float || texture.pixelFormat == .r8Unorm else { return nil }
        return texture
    }

    @objc public func invalidate() {
        renderer?.clear(); frame = nil; identity = nil; sessionID = nil
        presentedLayer = nil; presentation = nil
    }

    private func backend() throws -> PlanarBackend {
        if let renderer { return renderer }
        guard let device = Self.device else { throw PlanarMetalRenderer.failure() }
        let wantsPilot = UserDefaults.standard.bool(forKey: PlanarBackend.pilotDefaultsKey)
        let (backend, reason) = try PlanarBackend.make(device: device, wantsPilot: wantsPilot)
        renderer = backend
        // A fallback says so; it is never silent.
        if let reason { NSLog("Horos planar: %@", reason) }
        return backend
    }

    private func finishing(_ device: MTLDevice) throws -> PlanarFinishingPasses {
        if let passes { return passes }
        let made = try PlanarFinishingPasses(device: device)
        passes = made
        return made
    }

    /// Makes `snapshot` the frame the backend draws. A session, when the view
    /// has one, guards the upload against a volume closed or replaced meanwhile.
    private func prepare(_ snapshot: NSDictionary, session: VolumeSession?) throws -> PlanarBackend {
        let renderer = try backend()
        let next = try PlanarFrame(snapshot)
        if let session {
            guard session.isOpen, !session.isStale else { throw PlanarMetalRenderer.failure() }
            if identity?.isEqual(session.identity) != true || sessionID != session.sessionID { invalidate() }
        } else if identity != nil {
            invalidate()
        }
        if frame != next {
            if let session {
                guard let token = VolumeSessionRegistry.shared.makeLoadToken(for: session) else {
                    throw PlanarMetalRenderer.failure()
                }
                defer { token.cancel() }
                try renderer.update(next)
                guard session.isOpen, !session.isStale, session.identity.isEqual(token.identity), token.deliver() else {
                    throw PlanarMetalRenderer.failure()
                }
                identity = token.identity; sessionID = session.sessionID
            } else {
                try renderer.update(next)
            }
            frame = next
        }
        return renderer
    }

    /// Draws `snapshot` into the layer's next drawable and presents it with the
    /// current transaction. `inverted` inverts the picture, as the host's
    /// (ONE_MINUS_DST_COLOR, ZERO) quad over the frame did.
    @objc(drawSnapshot:session:layer:inverted:)
    public func draw(snapshot: NSDictionary, session: VolumeSession?, layer: CAMetalLayer, inverted: Bool) -> Bool {
        precondition(Thread.isMainThread)
        encodedGPUCommand = false
        failureReason = nil
        let size = layer.drawableSize
        guard size.width >= 1, size.height >= 1, size.width <= 16384, size.height <= 16384 else { return false }
        do {
            let renderer = try prepare(snapshot, session: session)
            guard let frame else { throw PlanarMetalRenderer.failure() }
            // An overlay redraw keeps the picture already presented. Captures
            // can prepare another frame without changing what this layer shows.
            if presentedLayer === layer, let presentation,
               presentation.frame == frame, presentation.size == size, presentation.inverted == inverted {
                return true
            }
            guard let drawable = layer.nextDrawable() else { throw PlanarMetalRenderer.failure() }
            let gpu = try renderer.render(into: drawable.texture)
            if inverted { try finishing(renderer.device).invert(drawable.texture) }
            drawable.present()
            gpuMilliseconds = gpu
            encodedGPUCommand = true
            renderedFrameCount += 1
            presentedLayer = layer
            presentation = (frame, size, inverted)
            return true
        } catch {
            failureReason = error.localizedDescription
            invalidate()
            return false
        }
    }

    /// A frame with no image: the clear colour, inverted as the host inverted it.
    @objc(clearLayer:white:inverted:)
    public func clear(layer: CAMetalLayer, white: Bool, inverted: Bool) {
        precondition(Thread.isMainThread)
        presentedLayer = nil; presentation = nil
        let size = layer.drawableSize
        guard size.width >= 1, size.height >= 1, let device = Self.device,
              let passes = try? finishing(device), let drawable = layer.nextDrawable() else { return }
        let value: Double = white != inverted ? 1 : 0
        try? passes.clear(drawable.texture, to: MTLClearColorMake(value, value, value, 1))
        drawable.present()
    }

    /// The pixels `snapshot` draws into a `width` x `height` target, BGRA, rows
    /// from the top: what the view shows, for a capture or the magnifying lens.
    @objc(renderSnapshot:session:width:height:inverted:)
    public func render(snapshot: NSDictionary, session: VolumeSession?, width: Int, height: Int, inverted: Bool) -> Data? {
        precondition(Thread.isMainThread)
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { return nil }
        do {
            let renderer = try prepare(snapshot, session: session)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: width, height: height, mipmapped: false)
            descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
            guard let target = renderer.device.makeTexture(descriptor: descriptor) else { throw PlanarMetalRenderer.failure() }
            _ = try renderer.render(into: target)
            if inverted { try finishing(renderer.device).invert(target) }
            var bytes = Data(count: width * height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                target.getBytes(buffer.baseAddress!, bytesPerRow: width * 4,
                                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            return bytes
        } catch {
            failureReason = error.localizedDescription
            invalidate()
            return nil
        }
    }
}

/// The two passes a frame may need after the image: a clear when there is no
/// image, and the inversion the host drew as a white quad blended with
/// (ONE_MINUS_DST_COLOR, ZERO) over everything.
final class PlanarFinishingPasses {
    private static let shader = #"""
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 position [[position]]; };
    vertex Vertex planarFinishVertex(uint id [[vertex_id]]) {
        const float2 p[] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
        Vertex v; v.position=float4(p[id],0,1); return v;
    }
    fragment float4 planarWhite() { return float4(1); }
    """#
    private let queue: MTLCommandQueue
    private let invertPipeline: MTLRenderPipelineState

    init(device: MTLDevice) throws {
        guard let queue = device.makeCommandQueue() else { throw PlanarMetalRenderer.failure() }
        self.queue = queue
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "planarFinishVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "planarWhite")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add; attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .oneMinusDestinationColor; attachment.destinationRGBBlendFactor = .zero
        attachment.sourceAlphaBlendFactor = .zero; attachment.destinationAlphaBlendFactor = .one
        invertPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func run(_ target: MTLTexture, load: MTLLoadAction, clear: MTLClearColor, draw: Bool) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = load; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clear
        guard let command = queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw PlanarMetalRenderer.failure() }
        if draw {
            encoder.setRenderPipelineState(invertPipeline)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw command.error ?? PlanarMetalRenderer.failure() }
    }

    func invert(_ target: MTLTexture) throws {
        try run(target, load: .load, clear: MTLClearColorMake(0, 0, 0, 1), draw: true)
    }

    func clear(_ target: MTLTexture, to colour: MTLClearColor) throws {
        try run(target, load: .clear, clear: colour, draw: false)
    }
}
