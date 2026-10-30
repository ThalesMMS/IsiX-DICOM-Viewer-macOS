/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

// The registration of one 2D viewer's series onto another's: by orientation
// alone (series of the same study share their origin) or by named point ROIs
// placed on both. The arithmetic is the viewer's, operation for operation: the
// float and double products and sums are contracted as clang contracts them
// (a*b + c*d as fma(a, b, c*d)).

public enum PointRegistration {

    /// The rigid transform (12 numbers: a 3 x 3 rotation, then the translation,
    /// zero) that takes the moving series' orientation (`sensor`, 9 direction
    /// cosines) to the fixed one's (`model`): the first two rows are the
    /// normalized dot products, the third their cross product, normalized.
    public static func orientationTransform(sensor vs: [Float], model vm: [Float]) -> [Double] {
        var m = [Double](repeating: 0, count: 12)
        func dot(_ r: Int, _ c: Int) -> Double {
            Double((vs[3 * r + 1] * vm[3 * c + 1]).addingProduct(vs[3 * r], vm[3 * c]).addingProduct(vs[3 * r + 2], vm[3 * c + 2]))
        }
        func normalize(_ a: Int) {
            let length = ((m[a + 1] * m[a + 1]).addingProduct(m[a], m[a]).addingProduct(m[a + 2], m[a + 2])).squareRoot()
            m[a] = m[a] / length
            m[a + 1] = m[a + 1] / length
            m[a + 2] = m[a + 2] / length
        }
        m[0] = dot(0, 0); m[1] = dot(0, 1); m[2] = dot(0, 2)
        normalize(0)
        m[3] = dot(1, 0); m[4] = dot(1, 1); m[5] = dot(1, 2)
        normalize(3)
        m[6] = (-(m[2] * m[4])).addingProduct(m[1], m[5])
        m[7] = (-(m[0] * m[5])).addingProduct(m[2], m[3])
        m[8] = (-(m[1] * m[3])).addingProduct(m[0], m[4])
        normalize(6)
        return m
    }

    /// A point in patient coordinates, rotated into a series' orientation
    /// (`vectors`, 9 direction cosines), in float.
    public static func rotated(_ p: [Float], _ v: [Float]) -> [Float] {
        (0..<3).map { r in (p[1] * v[3 * r + 1]).addingProduct(p[0], v[3 * r]).addingProduct(p[2], v[3 * r + 2]) }
    }

    /// How the named points of the two series pair up.
    public struct Pairing: Sendable, Equatable {
        /// The same number of points on both.
        public var sameNumberOfPoints: Bool
        /// At least three.
        public var enoughPoints: Bool
        /// Each point found its twin of the same name.
        public var namesMatch: Bool
        /// A name came up more than twice.
        public var triplets: Bool
        /// The pairs (fixed index, moving index) handed to the registration, in order.
        public var pairs: [Pairing.Pair]

        public struct Pair: Sendable, Equatable {
            public var model: Int, sensor: Int
            public init(model: Int, sensor: Int) { self.model = model; self.sensor = sensor }
        }

        /// The registration can run.
        public var succeeds: Bool { sameNumberOfPoints && enoughPoints && namesMatch && !triplets }
    }

    /// Pairs the fixed series' points (`model`) with the moving one's
    /// (`sensor`) by name, both sorted, as the viewer did: each fixed point
    /// takes the first moving point of its name still free; it stops at the
    /// first point without a twin, or at a name already used.
    public static func pair(model: [String?], sensor: [String?]) -> Pairing {
        let same = { (a: String?, b: String?) -> Bool in
            guard let a, let b else { return false }
            return (a as NSString).isEqual(to: b)
        }
        var result = Pairing(sameNumberOfPoints: sensor.count == model.count, enoughPoints: model.count >= 3,
                             namesMatch: true, triplets: false, pairs: [])
        guard result.sameNumberOfPoints && result.enoughPoints else { return result }

        var free = Array(sensor.indices)
        var previousNames: [String?] = []
        var i = 0
        while i < model.count && result.namesMatch && !result.triplets {
            let modelName = model[i]
            var found = false
            var j = 0
            while j < free.count && !found {
                let sensorName = sensor[free[j]]
                for previous in previousNames {
                    result.triplets = result.triplets || same(modelName, previous) || same(sensorName, previous)
                }
                result.namesMatch = same(sensorName, modelName)
                if result.namesMatch {
                    found = true
                    let index = free.remove(at: j)
                    j -= 1
                    previousNames.append(sensorName)
                    if !result.triplets { result.pairs.append(Pairing.Pair(model: i, sensor: index)) }
                }
                j += 1
            }
            i += 1
        }
        return result
    }
}
