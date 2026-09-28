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

/// The 3D view's frame, drawn by Metal and shown in the view's CAMetalLayer
/// (#731): what VTK's OpenGL render window drew. A frame is the background,
/// the surfaces - opaque ones writing depth, then the translucent ones - and
/// the volumes' ray-cast images over them, as VTK composed them. The frame
/// stays in a texture of its own, so that captures and VTK's pixel reads get
/// what was shown, and depth reads get the surfaces the rays stop at.
///
/// Depth follows OpenGL's window convention, 0 near and 1 far, as the camera's
/// matrices give it; pixel reads and writes are rows from the bottom, as VTK
/// keeps them. Main thread only.
@objc(HorosVRPresenter)
public final class VRPresenter: NSObject {

    /// The layout of a surface's uniforms, in floats, as the caller packs
    /// them: the clip matrix (VTK's world-to-clip times the actor's matrix)
    /// and the model-view matrix, column major; the normal matrix's three
    /// columns, each padded to four; ambient, diffuse and specular colours,
    /// already weighted, the specular power in the last float; then opacity,
    /// whether there are normals, a texture, a parallel camera; the light's
    /// direction in view coordinates; its colour.
    @objc public static let meshUniformFloats = 68
    /// A vertex: position, normal and texture coordinates, eight floats.
    @objc public static let vertexFloats = 8

    @objc public let layer: CAMetalLayer
    @objc public private(set) var failureReason: String?

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let opaqueMesh: MTLRenderPipelineState
    private let image: MTLRenderPipelineState
    private let accumulate: MTLRenderPipelineState
    private let composite: MTLRenderPipelineState
    private let always: MTLDepthStencilState
    private let writing: MTLDepthStencilState
    private let testing: MTLDepthStencilState
    private let linear: MTLSamplerState
    private let repeating: MTLSamplerState

    private var colour: MTLTexture?
    private var depth: MTLTexture?
    /// The translucent surfaces' sums, and whether this frame has any.
    private var accumulated: MTLTexture?
    private var coverage: MTLTexture?
    private var accumulating = false
    private var width = 0, height = 0
    private var background = MTLClearColorMake(0, 0, 0, 1)
    /// The frame's commands not yet sent, and the last ones sent.
    private var command: MTLCommandBuffer?
    private var submitted: MTLCommandBuffer?
    private var cleared = false
    /// Whether this frame has surfaces in its depth, and the depth once read.
    private var hasDepth = false
    private var depthValues: [Float]?
    private var imageTextures: [MTLTexture] = []
    private var imageCount = 0
    private var meshBuffers: [ObjectIdentifier: (data: NSData, buffer: MTLBuffer)] = [:]
    private var meshTextures: [ObjectIdentifier: (data: NSData, texture: MTLTexture)] = [:]
    private var usedThisFrame = Set<ObjectIdentifier>()

    private static let shader = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct MeshUniforms {
        float4x4 clip;
        float4x4 modelView;
        float4 normal0, normal1, normal2;
        float4 ambient, diffuse, specular;
        float4 flags;
        float4 light;
        float4 lightColour;
    };
    struct MeshOut {
        float4 position [[position]];
        float3 view;
        float3 normal;
        float2 uv;
    };
    vertex MeshOut vrMeshVertex(uint id [[vertex_id]], device const float *vertices [[buffer(0)]],
                                constant MeshUniforms &u [[buffer(1)]]) {
        device const float *v = vertices + id * 8;
        float4 world = float4(v[0], v[1], v[2], 1);
        MeshOut out;
        float4 clip = u.clip * world;
        // OpenGL's clip z runs from -w to w; Metal's from 0 to w.
        clip.z = (clip.z + clip.w) * 0.5;
        out.position = clip;
        out.view = (u.modelView * world).xyz;
        out.normal = float3x3(u.normal0.xyz, u.normal1.xyz, u.normal2.xyz) * float3(v[3], v[4], v[5]);
        out.uv = float2(v[6], v[7]);
        return out;
    }
    // VTK's polygon shading: the normal interpolated, or the face's when the
    // surface has none, turned to the viewer on back faces; ambient, then
    // diffuse and specular from the light, the texture over the lot.
    static float4 vrShade(MeshOut in, bool front, constant MeshUniforms &u, texture2d<float> picture, sampler s) {
        float3 n;
        if (u.flags.y > 0.5) {
            n = normalize(in.normal);
            if (!front) n = -n;
        } else {
            n = normalize(cross(dfdx(in.view), dfdy(in.view)));
            if (u.flags.w > 0.5) { if (n.z < 0.0) n = -n; }
            else if (dot(n, in.view) > 0.0) n = -n;
        }
        float3 l = normalize(u.light.xyz);
        float df = max(0.0, dot(n, l));
        float sf = df > 0.0 ? pow(max(0.0, dot(n, normalize(l + float3(0, 0, 1)))), u.specular.w) : 0.0;
        float4 colour = float4(u.ambient.rgb + df * u.diffuse.rgb * u.lightColour.rgb
                               + sf * u.specular.rgb * u.lightColour.rgb, u.flags.x);
        if (u.flags.z > 0.5) colour *= picture.sample(s, in.uv);
        return colour;
    }
    fragment float4 vrMeshFragment(MeshOut in [[stage_in]], bool front [[front_facing]],
                                   constant MeshUniforms &u [[buffer(1)]],
                                   texture2d<float> picture [[texture(0)]], sampler s [[sampler(0)]]) {
        return vrShade(in, front, u, picture, s);
    }
    // VTK 8.2's order independent translucency: each translucent fragment
    // adds its premultiplied colour and its opacity, and multiplies the
    // revealage (the alpha, cleared to 1) by its transparency.
    struct Accumulated {
        float4 colour [[color(0)]];
        float coverage [[color(1)]];
    };
    fragment Accumulated vrMeshAccumulate(MeshOut in [[stage_in]], bool front [[front_facing]],
                                          constant MeshUniforms &u [[buffer(1)]],
                                          texture2d<float> picture [[texture(0)]], sampler s [[sampler(0)]]) {
        float4 c = vrShade(in, front, u, picture, s);
        Accumulated out;
        out.colour = float4(c.rgb * c.a, c.a);
        out.coverage = c.a;
        return out;
    }
    struct CompositeOut { float4 position [[position]]; };
    vertex CompositeOut vrCompositeVertex(uint id [[vertex_id]]) {
        const float2 p[] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
        CompositeOut out;
        out.position = float4(p[id], 0, 1);
        return out;
    }
    // The average colour over the frame, weighed by the revealage.
    fragment float4 vrCompositeFragment(CompositeOut in [[stage_in]], texture2d<float> accumulated [[texture(0)]],
                                        texture2d<float> coverage [[texture(1)]]) {
        uint2 p = uint2(in.position.xy);
        float4 a = accumulated.read(p);
        return float4(a.rgb / max(coverage.read(p).r, 0.01), a.a);
    }

    struct ImageOut {
        float4 position [[position]];
        float2 uv;
    };
    // The ray-cast image's quad, as VTK's display helper draws it: corners in
    // normalised device coordinates at one depth, texture coordinates inset by
    // half a texel.
    vertex ImageOut vrImageVertex(uint id [[vertex_id]], constant float4 *corners [[buffer(0)]]) {
        ImageOut out;
        out.position = float4(corners[id].xy, corners[id].z, 1);
        out.uv = float2(corners[id].w, corners[id + 4].x);
        return out;
    }
    fragment float4 vrImageFragment(ImageOut in [[stage_in]], texture2d<float> picture [[texture(0)]],
                                    sampler s [[sampler(0)]], constant float &scale [[buffer(0)]]) {
        return picture.sample(s, in.uv) * scale;
    }
    """#

    @objc public init?(layer: CAMetalLayer) {
        guard let device = layer.device ?? PlanarHostRenderer.device, let queue = device.makeCommandQueue() else { return nil }
        self.layer = layer
        self.device = device
        self.queue = queue
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        // The frame is copied into the drawable.
        layer.framebufferOnly = false
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            func pipeline(_ vertex: String, _ fragment: String, source: MTLBlendFactor, depth: Bool) throws -> MTLRenderPipelineState {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: vertex)
                descriptor.fragmentFunction = library.makeFunction(name: fragment)
                descriptor.depthAttachmentPixelFormat = .depth32Float
                let attachment = descriptor.colorAttachments[0]!
                attachment.pixelFormat = .bgra8Unorm
                if depth { return try device.makeRenderPipelineState(descriptor: descriptor) }
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add; attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = source; attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one; attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try device.makeRenderPipelineState(descriptor: descriptor)
            }
            opaqueMesh = try pipeline("vrMeshVertex", "vrMeshFragment", source: .one, depth: true)
            // The ray-cast image is premultiplied.
            image = try pipeline("vrImageVertex", "vrImageFragment", source: .one, depth: false)
            let accumulating = MTLRenderPipelineDescriptor()
            accumulating.vertexFunction = library.makeFunction(name: "vrMeshVertex")
            accumulating.fragmentFunction = library.makeFunction(name: "vrMeshAccumulate")
            accumulating.depthAttachmentPixelFormat = .depth32Float
            let sum = accumulating.colorAttachments[0]!, count = accumulating.colorAttachments[1]!
            sum.pixelFormat = .rgba16Float; count.pixelFormat = .r16Float
            for attachment in [sum, count] {
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add; attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .one; attachment.destinationRGBBlendFactor = .one
            }
            sum.sourceAlphaBlendFactor = .zero; sum.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            count.sourceAlphaBlendFactor = .one; count.destinationAlphaBlendFactor = .one
            accumulate = try device.makeRenderPipelineState(descriptor: accumulating)
            let compositing = MTLRenderPipelineDescriptor()
            compositing.vertexFunction = library.makeFunction(name: "vrCompositeVertex")
            compositing.fragmentFunction = library.makeFunction(name: "vrCompositeFragment")
            compositing.depthAttachmentPixelFormat = .depth32Float
            let over = compositing.colorAttachments[0]!
            over.pixelFormat = .bgra8Unorm
            over.isBlendingEnabled = true
            over.rgbBlendOperation = .add; over.alphaBlendOperation = .add
            over.sourceRGBBlendFactor = .oneMinusSourceAlpha; over.destinationRGBBlendFactor = .sourceAlpha
            over.sourceAlphaBlendFactor = .oneMinusSourceAlpha; over.destinationAlphaBlendFactor = .sourceAlpha
            composite = try device.makeRenderPipelineState(descriptor: compositing)
        } catch {
            NSLog("Horos VR presenter: %@", error.localizedDescription)
            return nil
        }
        func depthState(write: Bool) -> MTLDepthStencilState? {
            let descriptor = MTLDepthStencilDescriptor()
            descriptor.depthCompareFunction = .lessEqual
            descriptor.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: descriptor)
        }
        func sampler(_ address: MTLSamplerAddressMode) -> MTLSamplerState? {
            let descriptor = MTLSamplerDescriptor()
            descriptor.minFilter = .linear; descriptor.magFilter = .linear
            descriptor.sAddressMode = address; descriptor.tAddressMode = address
            return device.makeSamplerState(descriptor: descriptor)
        }
        let alwaysDescriptor = MTLDepthStencilDescriptor()
        alwaysDescriptor.depthCompareFunction = .always
        alwaysDescriptor.isDepthWriteEnabled = false
        guard let writing = depthState(write: true), let testing = depthState(write: false),
              let always = device.makeDepthStencilState(descriptor: alwaysDescriptor),
              let linear = sampler(.clampToEdge), let repeating = sampler(.repeat) else { return nil }
        self.writing = writing; self.testing = testing; self.always = always
        self.linear = linear; self.repeating = repeating
        super.init()
    }

    // MARK: Frame

    /// Starts a frame `width` × `height` pixels on the background colour.
    @objc public func begin(width: Int, height: Int, red: Double, green: Double, blue: Double) -> Bool {
        failureReason = nil
        guard width > 0, height > 0, width <= 16384, height <= 16384 else {
            failureReason = "The 3D view has no size."
            return false
        }
        if width != self.width || height != self.height || colour == nil || depth == nil {
            let colourDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            colourDescriptor.usage = [.renderTarget, .shaderRead]
            colourDescriptor.storageMode = .private
            let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
            depthDescriptor.usage = [.renderTarget]
            depthDescriptor.storageMode = .private
            colour = device.makeTexture(descriptor: colourDescriptor)
            depth = device.makeTexture(descriptor: depthDescriptor)
            accumulated = nil
            coverage = nil
            guard colour != nil, depth != nil else {
                failureReason = "The 3D view's frame could not be allocated."
                self.width = 0; self.height = 0
                return false
            }
            self.width = width; self.height = height
        }
        // The last frame's textures are reused: let the GPU finish with them.
        submitted?.waitUntilCompleted()
        command = nil
        cleared = false
        accumulating = false
        hasDepth = false
        depthValues = nil
        imageCount = 0
        usedThisFrame.removeAll()
        background = MTLClearColorMake(red, green, blue, 1)
        return true
    }

    private func currentCommand() -> MTLCommandBuffer? {
        if let command { return command }
        command = queue.makeCommandBuffer()
        return command
    }

    private func submit() {
        guard let command else { return }
        command.commit()
        submitted = command
        self.command = nil
    }

    /// A render pass over the frame: the first one clears it.
    private func pass() -> MTLRenderCommandEncoder? {
        guard let colour, let depth, let command = currentCommand() else { return nil }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = colour
        descriptor.colorAttachments[0].loadAction = cleared ? .load : .clear
        descriptor.colorAttachments[0].clearColor = background
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.depthAttachment.texture = depth
        descriptor.depthAttachment.loadAction = cleared ? .load : .clear
        descriptor.depthAttachment.clearDepth = 1
        descriptor.depthAttachment.storeAction = .store
        cleared = true
        return command.makeRenderCommandEncoder(descriptor: descriptor)
    }

    /// A pass adding translucent fragments to the sums, tested against the
    /// frame's depth; the first one of a frame clears them.
    private func translucentPass() -> MTLRenderCommandEncoder? {
        clearIfNeeded()
        guard let depth, let command = currentCommand() else { return nil }
        if accumulated == nil || coverage == nil {
            func target(_ format: MTLPixelFormat) -> MTLTexture? {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
                descriptor.usage = [.renderTarget, .shaderRead]
                descriptor.storageMode = .private
                return device.makeTexture(descriptor: descriptor)
            }
            accumulated = target(.rgba16Float)
            coverage = target(.r16Float)
        }
        guard let accumulated, let coverage else { return nil }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = accumulated
        descriptor.colorAttachments[0].loadAction = accumulating ? .load : .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[1].texture = coverage
        descriptor.colorAttachments[1].loadAction = accumulating ? .load : .clear
        descriptor.colorAttachments[1].clearColor = MTLClearColorMake(0, 0, 0, 0)
        descriptor.colorAttachments[1].storeAction = .store
        descriptor.depthAttachment.texture = depth
        descriptor.depthAttachment.loadAction = .load
        descriptor.depthAttachment.storeAction = .store
        accumulating = true
        return command.makeRenderCommandEncoder(descriptor: descriptor)
    }

    /// Blends the translucent surfaces drawn since the last call over the
    /// frame, as VTK did before its volumes.
    @objc public func compositeTranslucent() {
        guard accumulating, let accumulated, let coverage, let encoder = pass() else { return }
        encoder.setRenderPipelineState(composite)
        encoder.setDepthStencilState(always)
        encoder.setFragmentTexture(accumulated, index: 0)
        encoder.setFragmentTexture(coverage, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        accumulating = false
    }

    /// Clears the frame if nothing has drawn on it yet.
    @objc public func clearIfNeeded() {
        if !cleared { pass()?.endEncoding() }
    }

    private func buffer(for data: NSData) -> MTLBuffer? {
        let key = ObjectIdentifier(data)
        usedThisFrame.insert(key)
        if let cached = meshBuffers[key], cached.data === data { return cached.buffer }
        guard data.length > 0, let made = device.makeBuffer(bytes: data.bytes, length: data.length, options: .storageModeShared) else { return nil }
        meshBuffers[key] = (data, made)
        return made
    }

    private func texture(for data: NSData, width: Int, height: Int) -> MTLTexture? {
        let key = ObjectIdentifier(data)
        usedThisFrame.insert(key)
        if let cached = meshTextures[key], cached.data === data { return cached.texture }
        guard width > 0, height > 0, data.length >= width * height * 4 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let made = device.makeTexture(descriptor: descriptor) else { return nil }
        made.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data.bytes, bytesPerRow: width * 4)
        meshTextures[key] = (data, made)
        return made
    }

    /// Draws a surface: `vertices` eight floats each, `indices` triangles of
    /// 32-bit indices, `uniforms` as `meshUniformFloats` describes. A texture,
    /// when given, is RGBA bytes, rows from the bottom, repeated. `cull` is 0
    /// for none, 1 for back faces, 2 for front faces. The caller keeps the
    /// same data objects while the surface does not change: the buffers are
    /// cached on them. `wireframe` draws the triangles' edges.
    @objc public func drawMesh(vertices: NSData, indices: NSData, uniforms: NSData, texture: NSData?,
                               textureWidth: Int, textureHeight: Int, translucent: Bool, cull: Int, wireframe: Bool) {
        guard uniforms.length == Self.meshUniformFloats * MemoryLayout<Float>.size, indices.length >= 12,
              let vertexBuffer = buffer(for: vertices), let indexBuffer = buffer(for: indices),
              let encoder = translucent ? translucentPass() : pass() else { return }
        encoder.setRenderPipelineState(translucent ? accumulate : opaqueMesh)
        encoder.setDepthStencilState(translucent ? testing : writing)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(cull == 1 ? .back : cull == 2 ? .front : .none)
        // A wireframe is the triangles' edges, culled as the faces are, as
        // OpenGL's polygon mode drew it.
        encoder.setTriangleFillMode(wireframe ? .lines : .fill)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(uniforms.bytes, length: uniforms.length, index: 1)
        encoder.setFragmentBytes(uniforms.bytes, length: uniforms.length, index: 1)
        let picture = texture.flatMap { self.texture(for: $0, width: textureWidth, height: textureHeight) }
        encoder.setFragmentTexture(picture ?? placeholder(), index: 0)
        encoder.setFragmentSamplerState(repeating, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: indices.length / 4, indexType: .uint32,
                                      indexBuffer: indexBuffer, indexBufferOffset: 0)
        encoder.endEncoding()
        if !translucent { hasDepth = true; depthValues = nil }
    }

    /// Draws line segments, `indices` pairs of 32-bit indices, with the
    /// surfaces' shading and uniforms, one pixel wide.
    @objc public func drawLines(vertices: NSData, indices: NSData, uniforms: NSData, translucent: Bool) {
        guard uniforms.length == Self.meshUniformFloats * MemoryLayout<Float>.size, indices.length >= 8,
              let vertexBuffer = buffer(for: vertices), let indexBuffer = buffer(for: indices),
              let encoder = translucent ? translucentPass() : pass() else { return }
        encoder.setRenderPipelineState(translucent ? accumulate : opaqueMesh)
        encoder.setDepthStencilState(translucent ? testing : writing)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(uniforms.bytes, length: uniforms.length, index: 1)
        encoder.setFragmentBytes(uniforms.bytes, length: uniforms.length, index: 1)
        encoder.setFragmentTexture(placeholder(), index: 0)
        encoder.setFragmentSamplerState(repeating, index: 0)
        encoder.drawIndexedPrimitives(type: .line, indexCount: indices.length / 4, indexType: .uint32,
                                      indexBuffer: indexBuffer, indexBufferOffset: 0)
        encoder.endEncoding()
        if !translucent { hasDepth = true; depthValues = nil }
    }

    private var blank: MTLTexture?
    private func placeholder() -> MTLTexture? {
        if let blank { return blank }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        blank = device.makeTexture(descriptor: descriptor)
        var white: UInt32 = 0xFFFF_FFFF
        blank?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 4)
        return blank
    }

    /// Whether any opaque surface has drawn into this frame's depth.
    @objc public var hasGeometryDepth: Bool { hasDepth }

    /// Draws a ray-cast image over the frame as VTK's display helper did:
    /// `pixels` is RGBA in 16-bit words, premultiplied, rows from the bottom,
    /// `memoryWidth` words × 4 a row, of which `usedWidth` × `usedHeight`
    /// are in use. The quad covers the in-use rectangle at `originX`,
    /// `originY` of a `viewportWidth` × `viewportHeight` grid spanning the
    /// frame, at `depth` (OpenGL window convention), tested against the
    /// surfaces. The words are multiplied by `scale`.
    @objc public func drawImage(pixels: UnsafeRawPointer, memoryWidth: Int, memoryHeight: Int, usedWidth: Int, usedHeight: Int,
                                originX: Int, originY: Int, viewportWidth: Int, viewportHeight: Int,
                                depth: Double, scale: Double) {
        guard memoryWidth > 0, memoryHeight > 0, usedWidth > 0, usedHeight > 0, usedWidth <= memoryWidth, usedHeight <= memoryHeight,
              viewportWidth > 0, viewportHeight > 0 else { return }
        let slot = imageCount
        imageCount += 1
        var texture = slot < imageTextures.count ? imageTextures[slot] : nil
        if texture == nil || texture!.width != memoryWidth || texture!.height != memoryHeight {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Unorm, width: memoryWidth, height: memoryHeight, mipmapped: false)
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            texture = device.makeTexture(descriptor: descriptor)
            guard let texture else { return }
            if slot < imageTextures.count { imageTextures[slot] = texture } else { imageTextures.append(texture) }
        }
        guard let texture else { return }
        texture.replace(region: MTLRegionMake2D(0, 0, usedWidth, usedHeight), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: memoryWidth * 8)
        guard let encoder = pass() else { return }
        let offsetX = 0.5 / Float(memoryWidth), offsetY = 0.5 / Float(memoryHeight)
        let u0 = offsetX, u1 = Float(usedWidth) / Float(memoryWidth) - offsetX
        let v0 = offsetY, v1 = Float(usedHeight) / Float(memoryHeight) - offsetY
        let x0 = 2 * Float(originX) / Float(viewportWidth) - 1, x1 = 2 * Float(originX + usedWidth) / Float(viewportWidth) - 1
        let y0 = 2 * Float(originY) / Float(viewportHeight) - 1, y1 = 2 * Float(originY + usedHeight) / Float(viewportHeight) - 1
        let z = Float(min(1, max(0, depth)))
        // A strip: bottom left, bottom right, top left, top right; each
        // corner's v in the next four.
        var corners: [SIMD4<Float>] = [
            SIMD4(x0, y0, z, u0), SIMD4(x1, y0, z, u1), SIMD4(x0, y1, z, u0), SIMD4(x1, y1, z, u1),
            SIMD4(v0, 0, 0, 0), SIMD4(v0, 0, 0, 0), SIMD4(v1, 0, 0, 0), SIMD4(v1, 0, 0, 0),
        ]
        var factor = Float(scale)
        encoder.setRenderPipelineState(image)
        encoder.setDepthStencilState(testing)
        encoder.setVertexBytes(&corners, length: MemoryLayout<SIMD4<Float>>.stride * corners.count, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(linear, index: 0)
        encoder.setFragmentBytes(&factor, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    /// Sends the frame drawn so far to the GPU and forgets the surfaces'
    /// buffers no frame uses any more.
    @objc public func finish() {
        clearIfNeeded()
        compositeTranslucent()
        submit()
        for key in meshBuffers.keys where !usedThisFrame.contains(key) { meshBuffers[key] = nil }
        for key in meshTextures.keys where !usedThisFrame.contains(key) { meshTextures[key] = nil }
    }

    /// Shows the frame in the layer, with the current Core Animation
    /// transaction, so that the overlay above shows the same frame.
    @objc public func present() {
        guard let colour else { return }
        if command != nil { finish() }
        let size = layer.drawableSize
        guard Int(size.width) == width, Int(size.height) == height,
              let drawable = layer.nextDrawable(), let next = queue.makeCommandBuffer(),
              let blit = next.makeBlitCommandEncoder() else { return }
        blit.copy(from: colour, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOriginMake(0, 0, 0),
                  sourceSize: MTLSizeMake(width, height, 1), to: drawable.texture, destinationSlice: 0,
                  destinationLevel: 0, destinationOrigin: MTLOriginMake(0, 0, 0))
        blit.endEncoding()
        if layer.presentsWithTransaction {
            next.commit()
            next.waitUntilScheduled()
            drawable.present()
        } else {
            next.present(drawable)
            next.commit()
        }
        submitted = next
    }

    // MARK: Two-buffer stereo (#734)

    /// Copies the frame drawn so far into `other`'s, which it makes the same
    /// size; NO when there is no frame.
    @objc(copyFrameInto:) public func copyFrame(into other: VRPresenter) -> Bool {
        guard let colour, other !== self,
              other.begin(width: width, height: height, red: background.red, green: background.green, blue: background.blue),
              let target = other.colour else { return false }
        if command != nil { finish() }
        guard let copy = queue.makeCommandBuffer(), let blit = copy.makeBlitCommandEncoder() else { return false }
        blit.copy(from: colour, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOriginMake(0, 0, 0),
                  sourceSize: MTLSizeMake(width, height, 1), to: target, destinationSlice: 0,
                  destinationLevel: 0, destinationOrigin: MTLOriginMake(0, 0, 0))
        blit.endEncoding()
        copy.commit()
        // The other presenter shows it from its own queue.
        copy.waitUntilCompleted()
        submitted = copy
        other.cleared = true
        return true
    }

    /// Exchanges this frame's colour with `other`'s, of the same size.
    @objc(exchangeFrameWith:) public func exchangeFrame(with other: VRPresenter) {
        guard other !== self, other.width == width, other.height == height, colour != nil, other.colour != nil else { return }
        if command != nil { finish() }
        submitted?.waitUntilCompleted()
        other.submitted?.waitUntilCompleted()
        swap(&colour, &other.colour)
    }

    // MARK: Reads and writes, rows from the bottom

    private func clamp(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> MTLRegion? {
        guard w > 0, h > 0, x >= 0, y >= 0, x + w <= width, y + h <= height else { return nil }
        // Metal's rows run from the top.
        return MTLRegionMake2D(x, height - y - h, w, h)
    }

    /// The frame's depth at `x`, `y`, `w` × `h`, rows from the bottom; 1
    /// where no surface drew. Returns NO outside the frame.
    @objc public func readDepth(x: Int, y: Int, width w: Int, height h: Int, into values: UnsafeMutablePointer<Float>) -> Bool {
        guard clamp(x, y, w, h) != nil else { return false }
        if !hasDepth {
            values.update(repeating: 1, count: w * h)
            return true
        }
        if depthValues == nil {
            guard let depth, let command = currentCommand(),
                  let staging = device.makeBuffer(length: width * height * 4, options: .storageModeShared),
                  let blit = command.makeBlitCommandEncoder() else { return false }
            blit.copy(from: depth, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOriginMake(0, 0, 0),
                      sourceSize: MTLSizeMake(width, height, 1), to: staging, destinationOffset: 0,
                      destinationBytesPerRow: width * 4, destinationBytesPerImage: width * height * 4)
            blit.endEncoding()
            submit()
            command.waitUntilCompleted()
            depthValues = Array(UnsafeBufferPointer(start: staging.contents().assumingMemoryBound(to: Float.self), count: width * height))
        }
        guard let depthValues else { return false }
        for row in 0..<h {
            let source = (height - 1 - (y + row)) * width + x
            depthValues.withUnsafeBufferPointer { all in
                (values + row * w).update(from: all.baseAddress! + source, count: w)
            }
        }
        return true
    }

    /// The frame's colour at `x`, `y`, `w` × `h`, rows from the bottom, RGB
    /// or RGBA bytes; nil outside the frame or before any frame.
    @objc public func readPixels(x: Int, y: Int, width w: Int, height h: Int, alpha: Bool) -> NSData? {
        guard let colour, let region = clamp(x, y, w, h) else { return nil }
        submit()
        submitted?.waitUntilCompleted()
        guard let staging = device.makeBuffer(length: w * h * 4, options: .storageModeShared),
              let read = queue.makeCommandBuffer(), let blit = read.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: colour, sourceSlice: 0, sourceLevel: 0, sourceOrigin: region.origin, sourceSize: region.size,
                  to: staging, destinationOffset: 0, destinationBytesPerRow: w * 4, destinationBytesPerImage: w * h * 4)
        blit.endEncoding()
        read.commit()
        read.waitUntilCompleted()
        let channels = alpha ? 4 : 3
        let out = NSMutableData(length: w * h * channels)!
        let bgra = staging.contents().assumingMemoryBound(to: UInt8.self)
        let bytes = out.mutableBytes.assumingMemoryBound(to: UInt8.self)
        for row in 0..<h {
            let from = bgra + (h - 1 - row) * w * 4, to = bytes + row * w * channels
            for column in 0..<w {
                to[column * channels] = from[column * 4 + 2]
                to[column * channels + 1] = from[column * 4 + 1]
                to[column * channels + 2] = from[column * 4]
                if alpha { to[column * channels + 3] = from[column * 4 + 3] }
            }
        }
        return out
    }

    /// Replaces the frame's colour at `x`, `y`, `w` × `h` with RGB or RGBA
    /// bytes, rows from the bottom, as VTK's pixel writes do.
    @objc public func writePixels(_ data: NSData, x: Int, y: Int, width w: Int, height h: Int, alpha: Bool) -> Bool {
        let channels = alpha ? 4 : 3
        guard let colour, let region = clamp(x, y, w, h), data.length >= w * h * channels,
              let staging = device.makeBuffer(length: w * h * 4, options: .storageModeShared) else { return false }
        let from = data.bytes.assumingMemoryBound(to: UInt8.self)
        let bgra = staging.contents().assumingMemoryBound(to: UInt8.self)
        for row in 0..<h {
            let source = from + (h - 1 - row) * w * channels, target = bgra + row * w * 4
            for column in 0..<w {
                target[column * 4] = source[column * channels + 2]
                target[column * 4 + 1] = source[column * channels + 1]
                target[column * 4 + 2] = source[column * channels]
                target[column * 4 + 3] = alpha ? source[column * channels + 3] : 255
            }
        }
        guard let command = currentCommand(), let blit = command.makeBlitCommandEncoder() else { return false }
        if !cleared { cleared = true }
        blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: w * 4, sourceBytesPerImage: w * h * 4,
                  sourceSize: region.size, to: colour, destinationSlice: 0, destinationLevel: 0, destinationOrigin: region.origin)
        blit.endEncoding()
        return true
    }
}
