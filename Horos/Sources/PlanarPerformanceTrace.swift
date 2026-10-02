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
import OSLog
import Darwin

/// Opt-in Instruments spans for the retained viewer.
/// No names, paths, DICOM identifiers or pixels enter the trace. The endpoint
/// is the overlay committed at the end of drawRect:, not a claim of compositor display.
@MainActor @objc(HorosPlanarPerformanceTrace)
public final class PlanarPerformanceTrace: NSObject {
    @objc public static let enabled = UserDefaults.standard.bool(forKey: "HorosPlanarPerformanceTrace")
    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "thalesmms.isis.workstation",
                                   category: "PlanarPerformance")
    private static var nextView: UInt64 = 0
    private let view: UInt64
    private var lastScroll: UInt64 = 0

    public override init() {
        Self.nextView &+= 1
        view = Self.nextView
        super.init()
    }

    @objc(beginScroll:fromIndex:)
    public func beginScroll(_ event: NSEvent, fromIndex index: Int) -> UInt64 {
        let id = OSSignpostID(log: Self.log)
        lastScroll = id.rawValue
        let age = ProcessInfo.processInfo.systemUptime - event.timestamp
        os_signpost(.begin, log: Self.log, name: "PlanarScroll", signpostID: id,
            "view=%{public}llu from=%{public}ld precise=%{public}d inverted=%{public}d dx=%{public}.3f dy=%{public}.3f age_ms=%{public}.3f",
            view, index, event.hasPreciseScrollingDeltas ? 1 : 0, event.isDirectionInvertedFromDevice ? 1 : 0,
            event.scrollingDeltaX, event.scrollingDeltaY, event.timestamp > 0 && age >= 0 ? age*1000 : -1)
        return id.rawValue
    }

    @objc(endScroll:index:)
    public func endScroll(_ value: UInt64, index: Int) {
        os_signpost(.end, log: Self.log, name: "PlanarScroll", signpostID: OSSignpostID(value),
                    "view=%{public}llu to=%{public}ld", view, index)
    }

    @objc(beginDrawForIndex:)
    public func beginDraw(index: Int) -> UInt64 {
        let id = OSSignpostID(log: Self.log)
        os_signpost(.begin, log: Self.log, name: "PlanarDraw", signpostID: id,
                    "view=%{public}llu index=%{public}ld input=%{public}llu", view, index, lastScroll)
        return id.rawValue
    }

    @objc(prepared:metal:loadedLegacyTexture:gpuMilliseconds:)
    public func prepared(_ value: UInt64, metal: Bool, loadedLegacyTexture: Bool, gpuMilliseconds: Double) {
        os_signpost(.event, log: Self.log, name: "PlanarPrepared", signpostID: OSSignpostID(value),
                    "view=%{public}llu metal=%{public}d legacy_upload=%{public}d gpu_ms=%{public}.6f",
                    view, metal ? 1 : 0, loadedLegacyTexture ? 1 : 0, gpuMilliseconds)
    }

    @objc(imageDrawn:)
    public func imageDrawn(_ value: UInt64) {
        os_signpost(.event, log: Self.log, name: "PlanarImageDrawn", signpostID: OSSignpostID(value),
                    "view=%{public}llu", view)
    }

    @objc(endDraw:index:)
    public func endDraw(_ value: UInt64, index: Int) {
        guard value != 0 else { return }
        // Process-wide CPU and physical footprint, sampled only while this
        // development trace is enabled. They include other Horos threads.
        var usage = rusage()
        let status = getrusage(RUSAGE_SELF, &usage)
        let cpu = status == 0 ? Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec)/1_000_000 : -1
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info)/MemoryLayout<integer_t>.size)
        let size = Int(count)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: size) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let footprint: UInt64 = result == KERN_SUCCESS ? info.phys_footprint : 0
        os_signpost(.end, log: Self.log, name: "PlanarDraw", signpostID: OSSignpostID(value),
                    "view=%{public}llu index=%{public}ld cpu_s=%{public}.6f footprint_bytes=%{public}llu",
                    view, index, cpu, footprint)
    }
}
