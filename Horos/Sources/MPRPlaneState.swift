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

/// Only plane geometry is remembered. Windowing, zoom and slab settings stay
/// under the control of the viewer and its existing preferences.
struct MPRPlaneState: Codable, Equatable {
    struct Pose: Codable, Equatable {
        /// Positions are divided by the volume's rendering factor before saving.
        var position: [Double]
        var focalPoint: [Double]
        var viewUp: [Double]
        var rollAngle: Double
        var angleMPR: Double

        var isValid: Bool {
            guard MPRPlaneState.validVector(position), MPRPlaneState.validVector(focalPoint),
                  MPRPlaneState.validVector(viewUp), rollAngle.isFinite, angleMPR.isFinite,
                  abs(rollAngle) < 1e8, abs(angleMPR) < 1e8 else { return false }
            let direction = zip(focalPoint, position).map(-)
            let cross = [direction[1] * viewUp[2] - direction[2] * viewUp[1],
                         direction[2] * viewUp[0] - direction[0] * viewUp[2],
                         direction[0] * viewUp[1] - direction[1] * viewUp[0]]
            return cross.reduce(0) { $0 + $1 * $1 } > 1e-12
        }
    }

    var poses: [Pose]
    var crossCenter: [Double]

    var isValid: Bool {
        poses.count == 3 && poses.allSatisfy(\.isValid) && Self.validVector(crossCenter)
    }

    private static func validVector(_ vector: [Double]) -> Bool {
        vector.count == 3 && vector.allSatisfy { $0.isFinite && abs($0) < 1e8 }
    }
}

/// One sidecar per study, in the database's existing 3D-state directory. Its
/// series dictionary keeps a second series from replacing the first one's pose.
enum MPRPlaneStateStore {
    private struct StudyState: Codable {
        var version = 1
        var studyUID: String
        var series: [String: MPRPlaneState] = [:]
    }

    static func fileURL(in directory: URL, studyUID: String) -> URL {
        let name = Data(studyUID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        return directory.appendingPathComponent("MPRPlanes-\(name).plist")
    }

    private static func read(in directory: URL, studyUID: String) -> StudyState? {
        guard !studyUID.isEmpty,
              let data = try? Data(contentsOf: fileURL(in: directory, studyUID: studyUID)),
              let state = try? PropertyListDecoder().decode(StudyState.self, from: data),
              state.version == 1, state.studyUID == studyUID else { return nil }
        return state
    }

    static func load(in directory: URL, studyUID: String, seriesUID: String) -> MPRPlaneState? {
        guard !seriesUID.isEmpty,
              let state = read(in: directory, studyUID: studyUID)?.series[seriesUID],
              state.isValid else { return nil }
        return state
    }

    static func save(_ state: MPRPlaneState, in directory: URL,
                     studyUID: String, seriesUID: String) throws {
        guard state.isValid, !studyUID.isEmpty, !seriesUID.isEmpty else {
            throw CocoaError(.propertyListWriteInvalid)
        }
        var study = read(in: directory, studyUID: studyUID) ?? StudyState(studyUID: studyUID)
        study.series[seriesUID] = state
        let data = try PropertyListEncoder().encode(study)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(in: directory, studyUID: studyUID), options: .atomic)
    }
}
