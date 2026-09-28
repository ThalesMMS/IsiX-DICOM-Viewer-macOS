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
import simd
import Accelerate

/// Reslice and projections for #374, on the volume the host already decoded.
///
/// The volume is a regular voxel grid with one affine to the world (patient
/// or the host's local frame; the engine does not care which, only that the
/// plane is expressed in the same frame). A plane is sampled at pixel centres,
/// a slab is a fixed number of samples along the plane normal, centred on the
/// plane, reduced by maximum, minimum or mean. Nothing here reads DICOM,
/// Core Data or the host's views; the host hands in bytes and geometry.
///
/// Conventions, each fixed by `tests/test-mpr-metal-reslicer.py`:
/// - voxel `(i, j, k)` has its centre at index coordinates `(i, j, k)`, so a
///   plane through voxel centres reproduces the stored values exactly;
/// - a sample is inside the volume when every index coordinate lies within
///   `[-0.5, dimension - 0.5]`; neighbours are clamped to the edge (the
///   sampler's clamp-to-edge), so the half-voxel rim repeats the edge value;
/// - a pixel whose samples all fall outside receives `background`; a mean
///   divides by the samples that were inside, as the CPU slab does.
public struct ResliceVolume {
    public let width: Int, height: Int, depth: Int
    public let voxels: Data
    /// Column-major: `voxelToWorld * (i, j, k, 1)` is the centre of voxel (i, j, k).
    public let voxelToWorld: simd_float4x4

    public init(width: Int, height: Int, depth: Int, voxels: Data, voxelToWorld: simd_float4x4) throws {
        guard width > 0, height > 0, depth > 0 else { throw ResliceFailure.geometry("The volume has no extent.") }
        let count = VolumeAllocation.byteCount(width: width, height: height, slices: depth, bytesPerVoxel: 4)
        guard count == voxels.count else {
            throw ResliceFailure.geometry("The volume bytes do not match \(VolumeAllocation.describeMatrix(width: width, height: height, slices: depth)).")
        }
        let m = voxelToWorld
        let entries = [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
        guard entries.allSatisfy({ $0.isFinite }) else { throw ResliceFailure.geometry("The volume geometry is not finite.") }
        let linear = simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                   SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                   SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        guard abs(linear.determinant) > 1e-12 else { throw ResliceFailure.geometry("The volume geometry is degenerate; no plane can be resliced from it.") }
        self.width = width; self.height = height; self.depth = depth
        self.voxels = voxels; self.voxelToWorld = voxelToWorld
    }

    /// Builds the affine the way DICOM describes a stack: the first slice's
    /// position, its row and column cosines scaled by the pixel spacing, and
    /// the step between slice positions. The step is measured, not assumed:
    /// slices must be equally spaced along the plane normal, and a series
    /// acquired in decreasing position keeps its negative step instead of
    /// being silently reordered. A gap, a non-parallel slice or a step that
    /// is not constant is refused with a reason, never regularised.
    public static func stackTransform(positions: [SIMD3<Double>], rowCosines: SIMD3<Double>,
                                      columnCosines: SIMD3<Double>, pixelSpacing: SIMD2<Double>,
                                      tolerance: Double = 1e-3) throws -> simd_float4x4 {
        guard let first = positions.first else { throw ResliceFailure.geometry("The stack has no slices.") }
        guard pixelSpacing.x > 0, pixelSpacing.y > 0, pixelSpacing.x.isFinite, pixelSpacing.y.isFinite
        else { throw ResliceFailure.geometry("The pixel spacing is not a positive finite length.") }
        let row = simd_normalize(rowCosines), column = simd_normalize(columnCosines)
        guard row.x.isFinite, column.x.isFinite, abs(simd_dot(row, column)) < 1e-4
        else { throw ResliceFailure.geometry("The row and column cosines are not orthogonal unit vectors.") }
        let normal = simd_cross(row, column)
        var step = SIMD3<Double>(0, 0, 0)
        if positions.count == 1 {
            step = normal
        } else {
            let offsets = positions.map { $0 - first }
            let along = offsets.map { simd_dot($0, normal) }
            for (index, offset) in offsets.enumerated() {
                let inPlane = offset - along[index] * normal
                guard simd_length(inPlane) <= tolerance else {
                    throw ResliceFailure.geometry("Slice \(index) is displaced \(String(format: "%.3f", simd_length(inPlane))) mm within its own plane; the stack is not a regular grid.")
                }
            }
            let first = along[1]
            guard abs(first) > tolerance else { throw ResliceFailure.geometry("Slices 0 and 1 share a position; the stack has no interval.") }
            for index in 1..<along.count {
                let interval = along[index] - along[index - 1]
                guard abs(interval - first) <= tolerance else {
                    throw ResliceFailure.geometry("The interval between slices \(index - 1) and \(index) is \(String(format: "%.3f", interval)) mm, not \(String(format: "%.3f", first)) mm; gaps or irregular spacing are not resampled silently.")
                }
            }
            step = normal * first
        }
        return simd_float4x4(columns: (
            SIMD4<Float>(Float(row.x * pixelSpacing.x), Float(row.y * pixelSpacing.x), Float(row.z * pixelSpacing.x), 0),
            SIMD4<Float>(Float(column.x * pixelSpacing.y), Float(column.y * pixelSpacing.y), Float(column.z * pixelSpacing.y), 0),
            SIMD4<Float>(Float(step.x), Float(step.y), Float(step.z), 0),
            SIMD4<Float>(Float(first.x), Float(first.y), Float(first.z), 1)))
    }
}

public enum ResliceProjection: Int {
    case maximum = 1, minimum = 2, mean = 3
}

/// How a sample between voxel centres is computed (#702). `linear` is the
/// reference: measurement, projections and the comparison with VTK use it.
/// `cubic` is Catmull-Rom over the 4×4×4 neighbourhood, for display only: it
/// reproduces voxel centres and linear ramps exactly, and its result is kept
/// within the eight voxels around the sample, so a sharp edge gains no halo.
public enum ResliceInterpolation: Int {
    case linear = 0, cubic = 1
}

/// One plane to produce: `origin` is the centre of pixel (0, 0); pixel (x, y)
/// has its centre at `origin + x * rowStep + y * columnStep`. The slab spans
/// `thickness` along `rowStep × columnStep`, centred on the plane, sampled
/// `sampleCount` times; a thickness of zero (or one sample) is a single plane.
public struct ReslicePlane {
    public let origin: SIMD3<Float>, rowStep: SIMD3<Float>, columnStep: SIMD3<Float>
    public let width: Int, height: Int
    public let thickness: Float, sampleCount: Int
    public let projection: ResliceProjection
    public let background: Float
    public let interpolation: ResliceInterpolation

    public init(origin: SIMD3<Float>, rowStep: SIMD3<Float>, columnStep: SIMD3<Float>, width: Int, height: Int,
                thickness: Float, sampleStep: Float, projection: ResliceProjection, background: Float,
                interpolation: ResliceInterpolation = .linear) throws {
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { throw ResliceFailure.geometry("The plane has no extent.") }
        let numbers = [origin, rowStep, columnStep].flatMap { [$0.x, $0.y, $0.z] } + [thickness, sampleStep, background]
        guard numbers.allSatisfy({ $0.isFinite }), thickness >= 0, sampleStep > 0 else { throw ResliceFailure.geometry("The plane geometry is not finite.") }
        guard simd_length(rowStep) > 0, simd_length(columnStep) > 0,
              simd_length(simd_cross(rowStep, columnStep)) > 1e-9 * simd_length(rowStep) * simd_length(columnStep)
        else { throw ResliceFailure.geometry("The plane axes are collinear.") }
        self.origin = origin; self.rowStep = rowStep; self.columnStep = columnStep
        self.width = width; self.height = height; self.thickness = thickness
        // Samples are placed every `sampleStep`, both ends of the slab included.
        sampleCount = thickness > 0 ? max(2, Int((thickness / sampleStep).rounded(.up)) + 1) : 1
        guard sampleCount <= 4096 else { throw ResliceFailure.geometry("The slab asks for \(sampleCount) samples per pixel; reduce the thickness or coarsen the step.") }
        self.projection = projection; self.background = background; self.interpolation = interpolation
    }

    var normal: SIMD3<Float> { simd_normalize(simd_cross(rowStep, columnStep)) }
}

public enum ResliceFailure: Error, CustomStringConvertible {
    case geometry(String), device(String), memory(String), cancelled

    public var description: String {
        switch self {
        case .geometry(let s), .device(let s), .memory(let s): return s
        case .cancelled: return "The reslice was cancelled."
        }
    }
    var nsError: NSError {
        let code: Int
        switch self { case .geometry: code = 1; case .device: code = 2; case .memory: code = 3; case .cancelled: code = 4 }
        return NSError(domain: "HorosMPRReslice", code: code, userInfo: [NSLocalizedDescriptionKey: description])
    }
}

/// The GPU side. One instance owns one uploaded volume; a second upload
/// replaces the first and any token still outstanding on it is cancelled.
///
/// The output plane (#620): one shared buffer is kept between reconstructions,
/// sized for the largest plane asked for since the last `release()`, rounded up
/// to a whole MiB. A reconstruction has it to itself from encoding to the copy
/// out; one that runs meanwhile, on another thread, makes a buffer of its own,
/// and the larger of the two is kept. `release()` drops it. The kernel writes
/// every pixel of the plane, so nothing of an earlier frame survives in one,
/// and the pixels are always copied out: what a caller holds never changes
/// when the next reconstruction reuses the buffer.
public final class MPRMetalReslicer {
    static let shader = #"""
    #include <metal_stdlib>
    using namespace metal;
    struct Params {
        float4x4 worldToVoxel;
        float4 origin;      // xyz: centre of pixel (0,0)
        float4 rowStep;     // xyz
        float4 columnStep;  // xyz
        float4 slabStep;    // xyz: displacement between consecutive samples; w: first sample offset factor
        uint4 size;         // width, height, sampleCount, projection
        float4 extent;      // volume dims (x, y, z), background
        uint4 options;      // x: interpolation, 0 linear, 1 cubic
    };
    static float sampleVolume(texture3d<float, access::read> volume, float3 v, thread bool &inside) {
        float3 dims = float3(volume.get_width(), volume.get_height(), volume.get_depth());
        inside = all(v >= -0.5) && all(v <= dims - 0.5);
        if (!inside) return 0.0;
        // Weights in float from the exact index coordinates: the hardware
        // sampler quantises them, and a slab of near-equal samples must not
        // pick its maximum by sampler precision.
        float3 base = floor(v);
        float3 w = v - base;
        int3 i0 = clamp(int3(base), int3(0), int3(dims) - 1);
        int3 i1 = clamp(int3(base) + 1, int3(0), int3(dims) - 1);
        float c000 = volume.read(uint3(i0.x, i0.y, i0.z)).r, c100 = volume.read(uint3(i1.x, i0.y, i0.z)).r;
        float c010 = volume.read(uint3(i0.x, i1.y, i0.z)).r, c110 = volume.read(uint3(i1.x, i1.y, i0.z)).r;
        float c001 = volume.read(uint3(i0.x, i0.y, i1.z)).r, c101 = volume.read(uint3(i1.x, i0.y, i1.z)).r;
        float c011 = volume.read(uint3(i0.x, i1.y, i1.z)).r, c111 = volume.read(uint3(i1.x, i1.y, i1.z)).r;
        float x00 = mix(c000, c100, w.x), x10 = mix(c010, c110, w.x);
        float x01 = mix(c001, c101, w.x), x11 = mix(c011, c111, w.x);
        return mix(mix(x00, x10, w.y), mix(x01, x11, w.y), w.z);
    }
    // Catmull-Rom weights of the four neighbours at offsets -1, 0, 1, 2 for a
    // fraction t: (0, 1, 0, 0) at t = 0, so voxel centres come back exactly.
    static float4 catmullRom(float t) {
        float t2 = t * t, t3 = t2 * t;
        return float4(-0.5f * t3 + t2 - 0.5f * t,
                      1.5f * t3 - 2.5f * t2 + 1.0f,
                      -1.5f * t3 + 2.0f * t2 + 0.5f * t,
                      0.5f * t3 - 0.5f * t2);
    }
    static float sampleVolumeCubic(texture3d<float, access::read> volume, float3 v, thread bool &inside) {
        float3 dims = float3(volume.get_width(), volume.get_height(), volume.get_depth());
        inside = all(v >= -0.5) && all(v <= dims - 0.5);
        if (!inside) return 0.0;
        float3 base = floor(v);
        float3 t = v - base;
        int3 b = int3(base), last = int3(dims) - 1;
        float4 wx = catmullRom(t.x), wy = catmullRom(t.y), wz = catmullRom(t.z);
        // Seeded from the voxel at the base: fast math assumes no infinities.
        float low = volume.read(uint3(clamp(b, int3(0), last))).r, high = low, sum = 0.0;
        for (int dz = 0; dz < 4; ++dz) {
            int z = clamp(b.z - 1 + dz, 0, last.z);
            float plane = 0.0;
            for (int dy = 0; dy < 4; ++dy) {
                int y = clamp(b.y - 1 + dy, 0, last.y);
                float row = 0.0;
                for (int dx = 0; dx < 4; ++dx) {
                    float c = volume.read(uint3(clamp(b.x - 1 + dx, 0, last.x), y, z)).r;
                    row += wx[dx] * c;
                    // The eight voxels a linear sample would use bound the result.
                    if (dx == 1 || dx == 2) if (dy == 1 || dy == 2) if (dz == 1 || dz == 2) { low = min(low, c); high = max(high, c); }
                }
                plane += wy[dy] * row;
            }
            sum += wz[dz] * plane;
        }
        return clamp(sum, low, high);
    }
    // One pixel of the plane: its slab through `volume`, reduced.
    static float reslicePixel(texture3d<float, access::read> volume, constant Params &p, uint2 gid) {
        float3 centre = p.origin.xyz + float(gid.x) * p.rowStep.xyz + float(gid.y) * p.columnStep.xyz;
        float3 start = centre - p.slabStep.xyz * p.slabStep.w;
        uint n = p.size.z, projection = p.size.w;
        float accumulated = 0.0; uint counted = 0;
        for (uint s = 0; s < n; ++s) {
            float3 world = start + p.slabStep.xyz * float(s);
            float4 voxel = p.worldToVoxel * float4(world, 1.0);
            bool inside;
            float value = p.options.x == 1 ? sampleVolumeCubic(volume, voxel.xyz, inside) : sampleVolume(volume, voxel.xyz, inside);
            if (!inside) continue;
            if (counted == 0) accumulated = value;
            else if (projection == 1) accumulated = max(accumulated, value);
            else if (projection == 2) accumulated = min(accumulated, value);
            else accumulated += value;
            counted += 1;
        }
        float result = p.extent.w;
        // A mean multiplies by the reciprocal, as the host's slab does
        // (vDSP_vsmul by 1.0f / count). Under fast math this compiles as the
        // division did; under safe math it is the host's arithmetic exactly.
        if (counted > 0) result = (projection == 3) ? accumulated * (1.0f / float(counted)) : accumulated;
        return result;
    }
    kernel void reslice(texture3d<float, access::read> volume [[texture(0)]],
                        device float *output [[buffer(0)]],
                        constant Params &p [[buffer(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.size.x || gid.y >= p.size.y) return;
        output[gid.y * p.size.x + gid.x] = reslicePixel(volume, p, gid);
    }
    // An RGB volume's three channels, one scalar volume each, in one dispatch
    // (#787): grid depth 3, one channel per thread, the same pixel function as
    // `reslice`; the planes follow one another in `output`.
    kernel void resliceChannels(texture3d<float, access::read> red [[texture(0)]],
                                texture3d<float, access::read> green [[texture(1)]],
                                texture3d<float, access::read> blue [[texture(2)]],
                                device float *output [[buffer(0)]],
                                constant Params &p [[buffer(1)]],
                                uint3 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.size.x || gid.y >= p.size.y || gid.z > 2) return;
        float value = gid.z == 0 ? reslicePixel(red, p, gid.xy)
                    : gid.z == 1 ? reslicePixel(green, p, gid.xy) : reslicePixel(blue, p, gid.xy);
        output[(gid.z * p.size.y + gid.y) * p.size.x + gid.x] = value;
    }
    """#

    public let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLComputePipelineState
    private let safeMath: Bool
    private let channelsLock = NSLock()
    // Under channelsLock: made by the first RGB plane, so a scalar engine compiles nothing more (#787).
    private var channelsPipelineMade: MTLComputePipelineState?
    /// How reconstructions reach the GPU (#623); the kernel and its result are the same on either.
    public let backend: MetalComputeBackend
    private let submitter: Metal4ComputeSubmitter?
    /// The Metal 4 submission slots: made, in flight and idle; nil on Metal 3.
    var submissionSlots: (made: Int, inFlight: Int, idle: Int)? { submitter?.slots }
    /// Which Metal 4 submitter this engine uses; the same for every engine on a device.
    var submitterIdentity: ObjectIdentifier? { submitter.map { ObjectIdentifier($0) } }
    private let uploads = DispatchQueue(label: "org.horosproject.mpr.reslice.upload")
    private var texture: MTLTexture? {
        didSet {
            volumeResidency = submitter == nil ? nil : Self.residency(device: device, keeping: texture)
            volumeResidentResources = volumeResidency == nil ? [] : Set(texture.map { [ObjectIdentifier($0)] } ?? [])
        }
    }
    /// On Metal 4, a residency set holding the installed volume, used by every reconstruction on it instead of
    /// adding the volume to each job's set again (#623).
    private var volumeResidency: MTLResidencySet?
    private var volumeResidentResources: Set<ObjectIdentifier> = []
    private var uploaded: ResliceVolume?
    private var uploadGeneration = 0
    public private(set) var volumeBytes = 0
    private static let outputRounding = 1 << 20
    private let outputLock = NSLock()
    // Under outputLock.
    private var keptOutput: MTLBuffer?
    private var outputGeneration = 0
    private var outputAllocationCount = 0

    /// `safeMath` compiles the kernel with IEEE arithmetic, for a caller that
    /// must equal a CPU reduction bit for bit (the planar thick slab, #659);
    /// the MPR keeps fast math.
    public init(device: MTLDevice, backend: MetalComputeBackend = .metal3, safeMath: Bool = false) throws {
        let traceStart = MetalPerformanceTrace.now()
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw ResliceFailure.device("Metal cannot create a command queue.") }
        self.queue = queue
        self.backend = backend
        self.safeMath = safeMath
        submitter = backend == .metal4
            ? try Metal4ComputeSubmitter.shared(for: device)
            : nil
        // Compiled once per device and shared with every other MPR engine (#622).
        let (pipelines, compiled) = try MetalComputePipelineCache.pipelines(
            device: device, configuration: MetalComputePipelineCache.Configuration(
                source: Self.shader, functions: ["reslice"], safeMath: safeMath))
        pipeline = pipelines["reslice"]!
        MetalPerformanceTrace.record("mpr.pipeline", startedAt: traceStart, extra: ["cold": compiled])
    }

    /// A committed residency set holding `resource`; nil for nil. Residency is not requested here: asking for it
    /// at once made opening a window slower than on Metal 3, and the command buffers that use the set make its
    /// allocations resident when they are committed.
    static func residency(device: MTLDevice, keeping resource: MTLAllocation?) -> MTLResidencySet? {
        guard let resource, let set = try? device.makeResidencySet(descriptor: MTLResidencySetDescriptor()) else { return nil }
        set.addAllocation(resource)
        set.commit()
        return set
    }

    /// True once a volume is on the GPU and no later upload has replaced it.
    public var isReady: Bool { texture != nil }

    /// Refuses before allocating anything: the texture would be this many
    /// bytes, and a request the device cannot hold is named, not clamped.
    public func memoryRequirement(width: Int, height: Int, depth: Int) throws -> Int {
        try Self.memoryRequirement(device: device, width: width, height: height, depth: depth)
    }

    /// Shared with the volume renderer: one rule for what fits on the GPU.
    public static func memoryRequirement(device: MTLDevice, width: Int, height: Int, depth: Int) throws -> Int {
        let bytes = VolumeAllocation.byteCount(width: width, height: height, slices: depth, bytesPerVoxel: 4)
        guard bytes > 0, bytes != Int.max, width <= 2048, height <= 2048, depth <= 2048 else {
            throw ResliceFailure.memory("Cannot reslice a \(VolumeAllocation.describeMatrix(width: width, height: height, slices: depth)) volume: it needs \(VolumeAllocation.describe(byteCount: bytes)) of GPU memory. Nothing was reduced silently.")
        }
        let budget = Int(device.recommendedMaxWorkingSetSize)
        guard budget == 0 || bytes <= budget / 2 else {
            throw ResliceFailure.memory("Cannot reslice a \(VolumeAllocation.describeMatrix(width: width, height: height, slices: depth)) volume: it needs \(VolumeAllocation.describe(byteCount: bytes)) and this GPU offers \(VolumeAllocation.describe(byteCount: budget)). Nothing was reduced silently.")
        }
        return bytes
    }

    /// Shared with the volume renderer: the r32Float 3D texture of a volume,
    /// refused with a reason before allocation when it cannot fit.
    public static func makeTexture(device: MTLDevice, volume: ResliceVolume,
                                   pixelFormat: MTLPixelFormat = .r32Float) throws -> (MTLTexture, Int) {
        let bytes = try memoryRequirement(device: device, width: volume.width, height: volume.height, depth: volume.depth)
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D; descriptor.pixelFormat = pixelFormat
        descriptor.width = volume.width; descriptor.height = volume.height; descriptor.depth = volume.depth
        descriptor.storageMode = .shared; descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw ResliceFailure.memory("Metal refused a \(VolumeAllocation.describeMatrix(width: volume.width, height: volume.height, slices: volume.depth)) texture of \(VolumeAllocation.describe(byteCount: bytes)). Nothing was reduced silently.")
        }
        volume.voxels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake3D(0, 0, 0, volume.width, volume.height, volume.depth), mipmapLevel: 0, slice: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: volume.width * 4, bytesPerImage: volume.width * volume.height * 4)
        }
        return (texture, bytes)
    }

    /// Uploads synchronously. The host's reconstruction loop is synchronous
    /// too, so this is what it calls once per volume generation.
    public func upload(_ volume: ResliceVolume) throws {
        let traceStart = MetalPerformanceTrace.now()
        let bytes = try memoryRequirement(width: volume.width, height: volume.height, depth: volume.depth)
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D; descriptor.pixelFormat = .r32Float
        descriptor.width = volume.width; descriptor.height = volume.height; descriptor.depth = volume.depth
        descriptor.storageMode = .shared; descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw ResliceFailure.memory("Metal refused a \(VolumeAllocation.describeMatrix(width: volume.width, height: volume.height, slices: volume.depth)) texture of \(VolumeAllocation.describe(byteCount: bytes)). Nothing was reduced silently.")
        }
        let rowBytes = volume.width * 4, sliceBytes = rowBytes * volume.height
        volume.voxels.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake3D(0, 0, 0, volume.width, volume.height, volume.depth), mipmapLevel: 0, slice: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: rowBytes, bytesPerImage: sliceBytes)
        }
        self.texture = texture; uploaded = volume; volumeBytes = bytes; uploadGeneration += 1
        MetalPerformanceTrace.record("mpr.upload", startedAt: traceStart, extra: ["bytes": bytes])
    }

    /// Uploads off the calling thread. A token cancelled before delivery
    /// never installs its texture, a later upload supersedes an earlier one,
    /// and the completion reports which of the three happened.
    @discardableResult
    public func upload(_ volume: ResliceVolume, token: VolumeLoadToken,
                       completion: @escaping (Result<Void, Error>) -> Void) -> VolumeLoadToken {
        uploadGeneration += 1
        let generation = uploadGeneration
        uploads.async { [weak self] in
            guard let self else { return }
            if token.isCancelled { completion(.failure(ResliceFailure.cancelled)); return }
            do {
                _ = try self.memoryRequirement(width: volume.width, height: volume.height, depth: volume.depth)
            } catch { completion(.failure(error)); return }
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = .type3D; descriptor.pixelFormat = .r32Float
            descriptor.width = volume.width; descriptor.height = volume.height; descriptor.depth = volume.depth
            descriptor.storageMode = .shared; descriptor.usage = .shaderRead
            guard let texture = self.device.makeTexture(descriptor: descriptor) else {
                completion(.failure(ResliceFailure.memory("Metal refused the volume texture."))); return
            }
            volume.voxels.withUnsafeBytes { raw in
                texture.replace(region: MTLRegionMake3D(0, 0, 0, volume.width, volume.height, volume.depth), mipmapLevel: 0, slice: 0,
                                withBytes: raw.baseAddress!, bytesPerRow: volume.width * 4, bytesPerImage: volume.width * volume.height * 4)
            }
            DispatchQueue.main.async {
                // Cancelled after the work but before delivery: the texture is
                // dropped here and the caller is told; nothing was installed.
                guard !token.isCancelled, token.deliver() else { completion(.failure(ResliceFailure.cancelled)); return }
                guard generation == self.uploadGeneration else { completion(.failure(ResliceFailure.cancelled)); return }
                self.texture = texture; self.uploaded = volume
                self.volumeBytes = volume.voxels.count
                completion(.success(()))
            }
        }
        return token
    }

    /// Drops the GPU volume and the kept output plane. Command buffers in flight
    /// keep their own references, so this is safe during a render.
    public func release() {
        texture = nil; uploaded = nil; volumeBytes = 0; uploadGeneration += 1
        outputLock.withLock { keptOutput = nil; outputGeneration += 1 }
    }

    /// Output buffers made so far; a repeated reconstruction of planes that fit adds none.
    public var outputAllocations: Int { outputLock.withLock { outputAllocationCount } }

    /// Bytes of the output buffer kept for the next reconstruction; 0 after `release()`.
    public var outputCapacity: Int { outputLock.withLock { keptOutput?.length ?? 0 } }

    /// A buffer of at least `bytes` for one reconstruction, its own until `checkIn`.
    private func checkOutOutput(bytes: Int) throws -> (buffer: MTLBuffer, generation: Int) {
        let (kept, generation): (MTLBuffer?, Int) = outputLock.withLock {
            if let buffer = keptOutput, buffer.length >= bytes {
                keptOutput = nil
                return (buffer, outputGeneration)
            }
            outputAllocationCount += 1
            return (nil, outputGeneration)
        }
        if let kept { return (kept, generation) }
        // A window that grows a row at a time needs a new buffer only once per MiB.
        let length = (bytes + Self.outputRounding - 1) / Self.outputRounding * Self.outputRounding
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
            throw ResliceFailure.memory("Metal refused a \(VolumeAllocation.describe(byteCount: length)) output plane.")
        }
        return (buffer, generation)
    }

    /// Keeps the larger of the returned buffer and the one kept, unless `release()` came in between.
    private func checkIn(_ buffer: MTLBuffer, generation: Int) {
        outputLock.withLock {
            guard generation == outputGeneration else { return }
            if keptOutput.map({ buffer.length > $0.length }) ?? true { keptOutput = buffer }
        }
    }

    struct Params {
        var worldToVoxel: simd_float4x4
        var origin: SIMD4<Float>, rowStep: SIMD4<Float>, columnStep: SIMD4<Float>, slabStep: SIMD4<Float>
        var size: SIMD4<UInt32>
        var extent: SIMD4<Float>
        var options: SIMD4<UInt32>
    }

    /// The kernel's arguments for `plane` through `volume`.
    private static func params(_ plane: ReslicePlane, volume uploaded: ResliceVolume) -> Params {
        let slabDirection = plane.sampleCount > 1 ? plane.normal * (plane.thickness / Float(plane.sampleCount - 1)) : SIMD3<Float>(0, 0, 0)
        return Params(
            worldToVoxel: uploaded.voxelToWorld.inverse,
            origin: SIMD4(plane.origin, 0), rowStep: SIMD4(plane.rowStep, 0), columnStep: SIMD4(plane.columnStep, 0),
            slabStep: SIMD4(slabDirection, Float(plane.sampleCount - 1) * 0.5),
            size: SIMD4(UInt32(plane.width), UInt32(plane.height), UInt32(plane.sampleCount), UInt32(plane.projection.rawValue)),
            extent: SIMD4(Float(uploaded.width), Float(uploaded.height), Float(uploaded.depth), plane.background),
            options: SIMD4(UInt32(plane.interpolation.rawValue), 0, 0, 0))
    }

    /// Produces `plane.width * plane.height` floats, row-major, top row first.
    /// Runs the kernel and waits: the host consumes the pixels immediately.
    public func reslice(_ plane: ReslicePlane) throws -> Data {
        var pixels = Data(count: plane.width * plane.height * MemoryLayout<Float>.stride)
        try pixels.withUnsafeMutableBytes { try reslice(plane, into: $0) }
        return pixels
    }

    /// Writes the plane into `destination`, which the caller owns and which holds at
    /// least `plane.width * plane.height` floats: the one copy of the pixels.
    public func reslice(_ plane: ReslicePlane, into destination: UnsafeMutableRawBufferPointer) throws {
        let traceStart = MetalPerformanceTrace.now()
        guard let texture, let uploaded else { throw ResliceFailure.device("No volume is uploaded.") }
        let bytes = plane.width * plane.height * MemoryLayout<Float>.stride
        guard let destinationBytes = destination.baseAddress, destination.count >= bytes else {
            throw ResliceFailure.memory("The plane needs \(VolumeAllocation.describe(byteCount: bytes)); its destination holds \(VolumeAllocation.describe(byteCount: destination.count)).")
        }
        let (output, outputGeneration) = try checkOutOutput(bytes: bytes)
        defer { checkIn(output, generation: outputGeneration) }
        var params = Self.params(plane, volume: uploaded)
        let w = pipeline.threadExecutionWidth, h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        let grid = MTLSize(width: plane.width, height: plane.height, depth: 1), group = MTLSize(width: w, height: h, depth: 1)
        if let submitter {
            // Metal 4 (#623): the slot's uniforms carry the parameters, and the output is copied after the feedback.
            let times: Metal4ComputeSubmitter.Times
            do {
                times = try withUnsafeBytes(of: &params) { parameters in
                    try submitter.dispatch(pipeline: pipeline, textures: [texture], buffers: [output, nil], uniformsIndex: 1,
                                           parameters: parameters, size: grid, threadsPerThreadgroup: group,
                                           resident: volumeResidency, residentResources: volumeResidentResources)
                }
            } catch {
                MetalPerformanceTrace.record("mpr.reslice.metal4", startedAt: traceStart, committedAt: nil, completedAt: nil,
                                             gpuStartTime: 0, gpuEndTime: 0, failed: true, finishedAt: nil)
                throw error
            }
            destinationBytes.copyMemory(from: output.contents(), byteCount: bytes)
            MetalPerformanceTrace.record("mpr.reslice.metal4", startedAt: traceStart, committedAt: times.committedAt,
                                         completedAt: times.observedAt, gpuStartTime: times.gpuStartTime,
                                         gpuEndTime: times.gpuEndTime, failed: false, finishedAt: MetalPerformanceTrace.now(),
                                         extra: ["width": plane.width, "height": plane.height, "samples": plane.sampleCount])
            return
        }
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw ResliceFailure.device("Metal cannot encode the reslice.")
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(output, offset: 0, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 1)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: group)
        encoder.endEncoding()
        let committedAt = MetalPerformanceTrace.now()
        command.commit(); command.waitUntilCompleted()
        let completedAt = MetalPerformanceTrace.now()
        guard command.status == .completed else {
            MetalPerformanceTrace.record("mpr.reslice", startedAt: traceStart, committedAt: committedAt,
                                         completedAt: completedAt, command: command)
            throw command.error ?? ResliceFailure.device("The reslice command failed.")
        }
        destinationBytes.copyMemory(from: output.contents(), byteCount: bytes)
        MetalPerformanceTrace.record("mpr.reslice", startedAt: traceStart, committedAt: committedAt, completedAt: completedAt,
                                     command: command, finishedAt: MetalPerformanceTrace.now(),
                                     extra: ["width": plane.width, "height": plane.height, "samples": plane.sampleCount])
    }

    private func channelsPipeline() throws -> MTLComputePipelineState {
        try channelsLock.withLock {
            if let made = channelsPipelineMade { return made }
            let (pipelines, _) = try MetalComputePipelineCache.pipelines(
                device: device, configuration: MetalComputePipelineCache.Configuration(
                    source: Self.shader, functions: ["resliceChannels"], safeMath: safeMath))
            let made = pipelines["resliceChannels"]!
            channelsPipelineMade = made
            return made
        }
    }

    /// The same plane through the volumes of three engines - an RGB volume's red, green and blue, one scalar
    /// volume each - in one submission and one wait (#787): one dispatch whose grid holds the three channels,
    /// on this engine's queue or Metal 4 submitter. Each channel's pixels are what `reslice(_:)` gives on its
    /// own engine: the kernel runs the same pixel function. The three volumes must share one geometry.
    public func resliceChannels(_ channels: [MPRMetalReslicer], plane: ReslicePlane) throws -> [Data] {
        let traceStart = MetalPerformanceTrace.now()
        guard channels.count == 3 else { throw ResliceFailure.geometry("A colour plane needs three channels.") }
        var textures = [MTLTexture]()
        var volumes = [ResliceVolume]()
        for channel in channels {
            guard let texture = channel.texture, let volume = channel.uploaded else { throw ResliceFailure.device("No volume is uploaded.") }
            textures.append(texture); volumes.append(volume)
        }
        let uploaded = volumes[0]
        guard volumes.allSatisfy({ $0.width == uploaded.width && $0.height == uploaded.height && $0.depth == uploaded.depth
                                   && $0.voxelToWorld == uploaded.voxelToWorld }) else {
            throw ResliceFailure.geometry("The colour channels do not share one volume geometry.")
        }
        guard channels.allSatisfy({ $0.device === device && $0.backend == backend }) else {
            throw ResliceFailure.device("The colour channels are not on one device and backend.")
        }
        let pipeline = try channelsPipeline()
        let planeBytes = plane.width * plane.height * MemoryLayout<Float>.stride
        let (output, outputGeneration) = try checkOutOutput(bytes: 3 * planeBytes)
        defer { checkIn(output, generation: outputGeneration) }
        var params = Self.params(plane, volume: uploaded)
        let w = pipeline.threadExecutionWidth, h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        let grid = MTLSize(width: plane.width, height: plane.height, depth: 3), group = MTLSize(width: w, height: h, depth: 1)
        func planes() -> [Data] { (0..<3).map { Data(bytes: output.contents() + $0 * planeBytes, count: planeBytes) } }
        let extra: [String: Any] = ["width": plane.width, "height": plane.height, "samples": plane.sampleCount, "channels": 3]
        if let submitter {
            // Each channel's volume stays in its engine's residency set; none is added to the job's own set again.
            let times: Metal4ComputeSubmitter.Times
            do {
                times = try withUnsafeBytes(of: &params) { parameters in
                    try submitter.dispatch(pipeline: pipeline, textures: textures, buffers: [output, nil], uniformsIndex: 1,
                                           parameters: parameters, size: grid, threadsPerThreadgroup: group,
                                           residentSets: channels.compactMap { $0.volumeResidency },
                                           residentResources: channels.reduce(into: Set()) { $0.formUnion($1.volumeResidentResources) })
                }
            } catch {
                MetalPerformanceTrace.record("mpr.reslice.metal4", startedAt: traceStart, committedAt: nil, completedAt: nil,
                                             gpuStartTime: 0, gpuEndTime: 0, failed: true, finishedAt: nil)
                throw error
            }
            let result = planes()
            MetalPerformanceTrace.record("mpr.reslice.metal4", startedAt: traceStart, committedAt: times.committedAt,
                                         completedAt: times.observedAt, gpuStartTime: times.gpuStartTime,
                                         gpuEndTime: times.gpuEndTime, failed: false, finishedAt: MetalPerformanceTrace.now(),
                                         extra: extra)
            return result
        }
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw ResliceFailure.device("Metal cannot encode the reslice.")
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTextures(textures, range: 0..<3)
        encoder.setBuffer(output, offset: 0, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 1)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: group)
        encoder.endEncoding()
        let committedAt = MetalPerformanceTrace.now()
        command.commit(); command.waitUntilCompleted()
        let completedAt = MetalPerformanceTrace.now()
        guard command.status == .completed else {
            MetalPerformanceTrace.record("mpr.reslice", startedAt: traceStart, committedAt: committedAt,
                                         completedAt: completedAt, command: command)
            throw command.error ?? ResliceFailure.device("The reslice command failed.")
        }
        let result = planes()
        MetalPerformanceTrace.record("mpr.reslice", startedAt: traceStart, committedAt: committedAt, completedAt: completedAt,
                                     command: command, finishedAt: MetalPerformanceTrace.now(), extra: extra)
        return result
    }
}

/// Objective-C face for `MPRHostBridge.m`. Vectors travel as number arrays
/// because the host speaks `float[9]` orientations and `float[3]` origins.
@objc(HorosMPRReslicer)
public final class MPRReslicerBridge: NSObject {
    private let engine: MPRMetalReslicer
    @objc public private(set) var lastMilliseconds: Double = 0

    private init(engine: MPRMetalReslicer) { self.engine = engine; super.init() }

    /// `[HorosMPRReslicer makeAndReturnError:]` from Objective-C, on the backend the host asks for (#623).
    @objc public static func make() throws -> MPRReslicerBridge {
        guard let device = MTLCreateSystemDefaultDevice() else { throw ResliceFailure.device("No Metal device is available.").nsError }
        return try make(device: device, backend: MetalComputeBackend.host(device: device).backend)
    }

    public static func make(device: MTLDevice, backend: MetalComputeBackend) throws -> MPRReslicerBridge {
        do { return MPRReslicerBridge(engine: try MPRMetalReslicer(device: device, backend: backend)) }
        catch let failure as ResliceFailure { throw failure.nsError }
    }

    /// "Metal 3" or "Metal 4".
    @objc public var backendName: String { engine.backend.name }

    @objc public var isReady: Bool { engine.isReady }
    @objc public var volumeBytes: Int { engine.volumeBytes }
    @objc public var outputAllocations: Int { engine.outputAllocations }
    @objc public var outputCapacity: Int { engine.outputCapacity }
    @objc public func releaseVolume() { engine.release() }

    /// Column-major voxel-to-world matrix in millimetres, including the host's
    /// volume translation and orientation, in the same frame as its camera.
    @objc public func uploadVolume(_ voxels: NSData, width: Int, height: Int, depth: Int,
                                   voxelToWorld: [NSNumber]) throws {
        guard voxelToWorld.count == 16 else {
            throw ResliceFailure.geometry("The volume transform is incomplete.").nsError
        }
        let m = voxelToWorld.map { $0.floatValue }
        let transform = simd_float4x4(columns: (SIMD4(m[0], m[1], m[2], m[3]),
            SIMD4(m[4], m[5], m[6], m[7]), SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])))
        do {
            let volume = try ResliceVolume(width: width, height: height, depth: depth, voxels: voxels as Data, voxelToWorld: transform)
            try engine.upload(volume)
        } catch let failure as ResliceFailure { throw failure.nsError }
    }

    @objc public func memoryRequirementForWidth(_ width: Int, height: Int, depth: Int) throws -> NSNumber {
        do { return NSNumber(value: try engine.memoryRequirement(width: width, height: height, depth: depth)) }
        catch let failure as ResliceFailure { throw failure.nsError }
    }

    /// `orientation` holds the DCMPix nine cosines (row, column, normal) and
    /// `origin` the centre of pixel (0, 0), both in the uploaded frame.
    @objc public func reslice(origin: [NSNumber], orientation: [NSNumber], spacing: Double, width: Int, height: Int,
                              thickness: Double, sampleStep: Double, projection: Int, background: Double) throws -> NSData {
        do {
            let plane = try Self.plane(origin: origin, orientation: orientation, spacing: spacing, width: width, height: height,
                                       thickness: thickness, sampleStep: sampleStep, projection: projection, background: background)
            let started = DispatchTime.now().uptimeNanoseconds
            let data = try engine.reslice(plane)
            lastMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
            return data as NSData
        } catch let failure as ResliceFailure { throw failure.nsError }
    }

    /// The same plane into the host's own `float[width * height]`, which it then owns (#620).
    @objc public func reslice(origin: [NSNumber], orientation: [NSNumber], spacing: Double, width: Int, height: Int,
                              thickness: Double, sampleStep: Double, projection: Int, background: Double,
                              into destination: UnsafeMutablePointer<Float>) throws {
        try reslice(origin: origin, orientation: orientation, spacing: spacing, width: width, height: height,
                    thickness: thickness, sampleStep: sampleStep, projection: projection, background: background,
                    interpolation: ResliceInterpolation.linear.rawValue, into: destination)
    }

    /// The same, with `interpolation` 0 (linear) or 1 (cubic, for display only; #702).
    @objc public func reslice(origin: [NSNumber], orientation: [NSNumber], spacing: Double, width: Int, height: Int,
                              thickness: Double, sampleStep: Double, projection: Int, background: Double,
                              interpolation: Int, into destination: UnsafeMutablePointer<Float>) throws {
        do {
            let plane = try Self.plane(origin: origin, orientation: orientation, spacing: spacing, width: width, height: height,
                                       thickness: thickness, sampleStep: sampleStep, projection: projection, background: background,
                                       interpolation: interpolation)
            let started = DispatchTime.now().uptimeNanoseconds
            try engine.reslice(plane, into: UnsafeMutableRawBufferPointer(start: destination,
                                                                          count: plane.width * plane.height * MemoryLayout<Float>.stride))
            lastMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        } catch let failure as ResliceFailure { throw failure.nsError }
    }

    /// An RGB volume's plane (#787): `reslicers` hold its red, green and blue channels, uploaded with one geometry,
    /// and the same plane is resliced through the three in one GPU submission. The first reslicer's
    /// `lastMilliseconds` holds the time of the three.
    @objc public static func resliceChannels(_ reslicers: [MPRReslicerBridge], origin: [NSNumber], orientation: [NSNumber],
                                             spacing: Double, width: Int, height: Int, thickness: Double, sampleStep: Double,
                                             projection: Int, background: Double) throws -> [NSData] {
        do {
            guard let first = reslicers.first else { throw ResliceFailure.geometry("A colour plane needs three channels.") }
            let plane = try Self.plane(origin: origin, orientation: orientation, spacing: spacing, width: width, height: height,
                                       thickness: thickness, sampleStep: sampleStep, projection: projection, background: background)
            let started = DispatchTime.now().uptimeNanoseconds
            let planes = try first.engine.resliceChannels(reslicers.map { $0.engine }, plane: plane)
            first.lastMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
            return planes.map { $0 as NSData }
        } catch let failure as ResliceFailure { throw failure.nsError }
    }

    private static func plane(origin: [NSNumber], orientation: [NSNumber], spacing: Double, width: Int, height: Int,
                              thickness: Double, sampleStep: Double, projection: Int, background: Double,
                              interpolation: Int = 0) throws -> ReslicePlane {
        guard origin.count == 3, orientation.count == 9, let mode = ResliceProjection(rawValue: projection),
              let sampling = ResliceInterpolation(rawValue: interpolation) else {
            throw ResliceFailure.geometry("The plane description is incomplete.")
        }
        let o = origin.map { $0.floatValue }, c = orientation.map { $0.floatValue }
        return try ReslicePlane(origin: SIMD3(o[0], o[1], o[2]),
                                rowStep: SIMD3(c[0], c[1], c[2]) * Float(spacing),
                                columnStep: SIMD3(c[3], c[4], c[5]) * Float(spacing),
                                width: width, height: height, thickness: Float(thickness), sampleStep: Float(sampleStep),
                                projection: mode, background: Float(background), interpolation: sampling)
    }
}

/// An RGB volume's MPR plane, reslice by channel (#724). VTK's ray caster holds
/// the viewer's ARGB bytes as four independent components - alpha, weighted 0,
/// and red, green and blue, each with its colour function and the view's
/// opacity function. Each channel is resliced as a scalar volume - its
/// maximum, minimum or mean along the slab - and the three are looked up and
/// combined as
/// `VTKKWRCHelper_LookupAndCombineIndependentColorsMax` combines them, in 15
/// bits, from the mapper's own tables; the MPR reads the result as bytes, the
/// top 8 of those 15 bits.
@objc(HorosMPRColourPlane)
public final class MPRColourPlane: NSObject {
    /// The red, green and blue channels of ARGB voxels, `width` a row and
    /// `rows` rows (every slice's rows one after the other), as floats 0-255.
    @objc public static func channels(fromARGB volume: NSData, width: Int, rows: Int) -> [NSData]? {
        let count = width * rows
        guard width > 0, rows > 0, volume.length >= count * 4 else { return nil }
        var alphaBytes = Data(count: count), redBytes = Data(count: count)
        var greenBytes = Data(count: count), blueBytes = Data(count: count)
        func buffer(_ pointer: UnsafeMutableRawPointer, _ bytes: Int) -> vImage_Buffer {
            vImage_Buffer(data: pointer, height: vImagePixelCount(rows), width: vImagePixelCount(width), rowBytes: width * bytes)
        }
        let status: vImage_Error = alphaBytes.withUnsafeMutableBytes { a in redBytes.withUnsafeMutableBytes { r in
            greenBytes.withUnsafeMutableBytes { g in blueBytes.withUnsafeMutableBytes { b in
                var source = buffer(UnsafeMutableRawPointer(mutating: volume.bytes), 4)
                var alpha = buffer(a.baseAddress!, 1), red = buffer(r.baseAddress!, 1)
                var green = buffer(g.baseAddress!, 1), blue = buffer(b.baseAddress!, 1)
                return vImageConvert_ARGB8888toPlanar8(&source, &alpha, &red, &green, &blue, vImage_Flags(kvImageNoFlags))
            } } } }
        guard status == kvImageNoError else { return nil }
        let planes = [redBytes, greenBytes, blueBytes]
        var floats = [NSData]()
        for var plane in planes {
            var values = Data(count: count * MemoryLayout<Float>.size)
            let converted: vImage_Error = values.withUnsafeMutableBytes { destination in
                plane.withUnsafeMutableBytes { bytes in
                    var from = buffer(bytes.baseAddress!, 1), to = buffer(destination.baseAddress!, 4)
                    return vImageConvert_Planar8toPlanarF(&from, &to, 255, 0, vImage_Flags(kvImageNoFlags))
                }
            }
            guard converted == kvImageNoError else { return nil }
            floats.append(values as NSData)
        }
        return floats
    }

    /// The ARGB bytes of a plane from its three channel projections. `tables` holds,
    /// for each component VTK weighs, its `component` (1 red, 2 green, 3 blue),
    /// `weight`, `shift`, `scale`, table `size`, `opacity` (size shorts) and
    /// `colour` (3 x size shorts). A pixel below 0 in the channels had no sample
    /// inside the volume, which VTK leaves black.
    @objc public static func combine(red: NSData, green: NSData, blue: NSData, count: Int, tables: [NSDictionary]) -> NSData? {
        combine(red: red, green: green, blue: blue, count: count, tables: tables, fifteenBits: false)
    }

    static func combine(red: NSData, green: NSData, blue: NSData, count: Int, tables: [NSDictionary], fifteenBits: Bool) -> NSData? {
        let size = count * MemoryLayout<Float>.size
        guard count > 0, red.length >= size, green.length >= size, blue.length >= size else { return nil }
        struct Component { let channel: Int; let weight: Float; let shift: Float; let scale: Float; let size: Int
                           let opacity: [UInt16]; let colour: [UInt16] }
        var components = [Component]()
        for table in tables {
            guard let c = (table["component"] as? NSNumber)?.intValue, (1...3).contains(c),
                  let weight = (table["weight"] as? NSNumber)?.floatValue, let shift = (table["shift"] as? NSNumber)?.floatValue,
                  let scale = (table["scale"] as? NSNumber)?.floatValue, let n = (table["size"] as? NSNumber)?.intValue, n > 0,
                  let opacity = table["opacity"] as? Data, opacity.count == n * 2,
                  let colour = table["colour"] as? Data, colour.count == n * 6 else { return nil }
            components.append(Component(channel: c - 1, weight: weight, shift: shift, scale: scale, size: n,
                                        opacity: opacity.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) },
                                        colour: colour.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }))
        }
        let out = NSMutableData(length: count * 4 * (fifteenBits ? 2 : 1))!
        let pixels = out.mutableBytes.assumingMemoryBound(to: UInt8.self)
        let wide = out.mutableBytes.assumingMemoryBound(to: UInt16.self)
        let channels = [red.bytes.assumingMemoryBound(to: Float.self), green.bytes.assumingMemoryBound(to: Float.self),
                        blue.bytes.assumingMemoryBound(to: Float.self)]
        for i in 0..<count {
            if !fifteenBits { pixels[4 * i] = 255 }
            if channels[0][i] < 0 { continue }
            var sum: (UInt32, UInt32, UInt32) = (0, 0, 0)
            var opacity: UInt32 = 0
            for component in components {
                let value = component.scale * (channels[component.channel][i] + component.shift)
                let index = min(component.size - 1, max(0, Int(value.isFinite ? value : 0)))
                let alpha = UInt32(UInt16(Float(component.opacity[index]) * component.weight))
                opacity += alpha
                sum.0 += UInt32(UInt16((UInt32(component.colour[3 * index]) * alpha + 0x7fff) >> 15))
                sum.1 += UInt32(UInt16((UInt32(component.colour[3 * index + 1]) * alpha + 0x7fff) >> 15))
                sum.2 += UInt32(UInt16((UInt32(component.colour[3 * index + 2]) * alpha + 0x7fff) >> 15))
            }
            if fifteenBits {
                wide[4 * i] = UInt16(min(32767, sum.0)); wide[4 * i + 1] = UInt16(min(32767, sum.1))
                wide[4 * i + 2] = UInt16(min(32767, sum.2)); wide[4 * i + 3] = UInt16(min(32767, opacity))
                continue
            }
            pixels[4 * i + 1] = UInt8(min(32767, sum.0) >> 7)
            pixels[4 * i + 2] = UInt8(min(32767, sum.1) >> 7)
            pixels[4 * i + 3] = UInt8(min(32767, sum.2) >> 7)
        }
        return out
    }

    /// The ray-cast picture of an RGB volume's projection in the 3D view
    /// (#725): three values a pixel, red, green and blue, one after the other,
    /// combined through the mapper's tables as VTK combines them, kept in its
    /// 15 bits: premultiplied red, green and blue, and the sum of the
    /// opacities. A pixel below 0 had no sample and stays at zero.
    @objc public static func picture(components values: NSData, count: Int, tables: [NSDictionary]) -> NSData? {
        guard count > 0, values.length >= 3 * count * MemoryLayout<Float>.size else { return nil }
        let planes = (0..<3).map { channel -> NSData in
            let source = values.bytes.assumingMemoryBound(to: Float.self)
            var plane = [Float](repeating: 0, count: count)
            for i in 0..<count { plane[i] = source[3 * i + channel] }
            return plane.withUnsafeBufferPointer { NSData(bytes: $0.baseAddress!, length: count * 4) }
        }
        return combine(red: planes[0], green: planes[1], blue: planes[2], count: count, tables: tables, fifteenBits: true)
    }
}
