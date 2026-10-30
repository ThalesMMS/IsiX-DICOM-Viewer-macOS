/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

/// The point-set registration of two viewers: the similarity (rotation,
/// uniform scale and translation) that best carries the model points onto
/// the sensor points, by Horn's closed-form solution with unit quaternions
/// (B. K. P. Horn, "Closed-form solution of absolute orientation using unit
/// quaternions", J. Opt. Soc. Am. A 4:629-642, 1987).
///
/// The arithmetic is that of vtkLandmarkTransform in its similarity mode, as
/// the registration used it: the points are kept in single precision, as
/// vtkPoints kept them, the 4 × 4 matrix N is eigen-decomposed by Jacobi
/// rotations (vtkMath::JacobiN), and collinear points take the smallest
/// rotation that turns the first segment onto the other.
//
// The arithmetic is ported from VTK 9.7.1 (vtkLandmarkTransform.cxx and
// vtkMath.cxx: Copyright (c) Ken Martin, Will Schroeder, Bill Lorensen;
// Copyright 2011 Sandia Corporation; BSD-3-Clause), whose copyright and
// license accompany the app (NOTICE).
public enum PointSetRegistration {
    /// The registration of `model` onto `sensor`, sixteen doubles row by row:
    /// nil when the two sets have different numbers of points; the identity
    /// for none; a translation for one point, or when a set has all its
    /// points at its centroid.
    public static func similarity(model: [SIMD3<Double>], sensor: [SIMD3<Double>]) -> [Double]? {
        guard model.count == sensor.count else { return nil }
        let count = model.count
        var m = [[Double]](repeating: [1, 0, 0, 0], count: 4)
        for i in 0..<4 {
            m[i] = [0, 0, 0, 0]
            m[i][i] = 1
        }
        if count == 0 { return m.flatMap { $0 } }

        // vtkPoints of floats.
        let source = model.map { SIMD3<Double>(Double(Float($0.x)), Double(Float($0.y)), Double(Float($0.z))) }
        let target = sensor.map { SIMD3<Double>(Double(Float($0.x)), Double(Float($0.y)), Double(Float($0.z))) }

        var sc = [0.0, 0.0, 0.0], tc = [0.0, 0.0, 0.0]
        for i in 0..<count {
            sc[0] += source[i].x
            sc[1] += source[i].y
            sc[2] += source[i].z
            tc[0] += target[i].x
            tc[1] += target[i].y
            tc[2] += target[i].z
        }
        let n = Double(count)
        for k in 0..<3 {
            sc[k] /= n
            tc[k] /= n
        }

        func translationOnly() -> [Double] {
            m[0][3] = tc[0] - sc[0]
            m[1][3] = tc[1] - sc[1]
            m[2][3] = tc[2] - sc[2]
            return m.flatMap { $0 }
        }
        if count == 1 { return translationOnly() }

        // The 3 × 3 matrix M of the centred points' products.
        var M = [[Double]](repeating: [0, 0, 0], count: 3)
        var sa = 0.0, sb = 0.0
        for point in 0..<count {
            let a = [source[point].x - sc[0], source[point].y - sc[1], source[point].z - sc[2]]
            let b = [target[point].x - tc[0], target[point].y - tc[1], target[point].z - tc[2]]
            for i in 0..<3 {
                M[i][0] += a[i] * b[0]
                M[i][1] += a[i] * b[1]
                M[i][2] += a[i] * b[2]
            }
            sa += a[0] * a[0] + a[1] * a[1] + a[2] * a[2]
            sb += b[0] * b[0] + b[1] * b[1] + b[2] * b[2]
        }
        if sa == 0.0 || sb == 0.0 { return translationOnly() }

        let scale = (sb / sa).squareRoot()

        // The 4 × 4 symmetric matrix N.
        var N = [[Double]](repeating: [0, 0, 0, 0], count: 4)
        N[0][0] = M[0][0] + M[1][1] + M[2][2]
        N[1][1] = M[0][0] - M[1][1] - M[2][2]
        N[2][2] = -M[0][0] + M[1][1] - M[2][2]
        N[3][3] = -M[0][0] - M[1][1] + M[2][2]
        N[0][1] = M[1][2] - M[2][1]; N[1][0] = N[0][1]
        N[0][2] = M[2][0] - M[0][2]; N[2][0] = N[0][2]
        N[0][3] = M[0][1] - M[1][0]; N[3][0] = N[0][3]
        N[1][2] = M[0][1] + M[1][0]; N[2][1] = N[1][2]
        N[1][3] = M[2][0] + M[0][2]; N[3][1] = N[1][3]
        N[2][3] = M[1][2] + M[2][1]; N[3][2] = N[2][3]

        let (eigenvalues, eigenvectors) = jacobi(N)

        var w: Double, x: Double, y: Double, z: Double
        if eigenvalues[0] == eigenvalues[1] || count == 2 {
            // Collinear points: the quaternion of the smallest rotation.
            var ds = [source[1].x - source[0].x, source[1].y - source[0].y, source[1].z - source[0].z]
            var dt = [target[1].x - target[0].x, target[1].y - target[0].y, target[1].z - target[0].z]
            var rs = 0.0, rt = 0.0
            for i in 0..<3 {
                rs += ds[i] * ds[i]
                rt += dt[i] * dt[i]
            }
            rs = rs.squareRoot()
            ds = [ds[0] / rs, ds[1] / rs, ds[2] / rs]
            rt = rt.squareRoot()
            dt = [dt[0] / rt, dt[1] / rt, dt[2] / rt]

            w = ds[0] * dt[0] + ds[1] * dt[1] + ds[2] * dt[2]
            x = ds[1] * dt[2] - ds[2] * dt[1]
            y = ds[2] * dt[0] - ds[0] * dt[2]
            z = ds[0] * dt[1] - ds[1] * dt[0]

            var r = (x * x + y * y + z * z).squareRoot()
            let theta = atan2(r, w)
            w = cos(theta / 2)
            if r != 0 {
                r = sin(theta / 2) / r
                x = x * r
                y = y * r
                z = z * r
            } else {
                // A half turn: about a vector perpendicular to the segment.
                dt = perpendicular(ds)
                r = sin(theta / 2)
                x = dt[0] * r
                y = dt[1] * r
                z = dt[2] * r
            }
        } else {
            w = eigenvectors[0][0]
            x = eigenvectors[1][0]
            y = eigenvectors[2][0]
            z = eigenvectors[3][0]
        }

        // The quaternion as a rotation matrix, times the scale.
        let ww = w * w, wx = w * x, wy = w * y, wz = w * z
        let xx = x * x, yy = y * y, zz = z * z
        let xy = x * y, xz = x * z, yz = y * z
        m[0][0] = ww + xx - yy - zz
        m[1][0] = 2.0 * (wz + xy)
        m[2][0] = 2.0 * (-wy + xz)
        m[0][1] = 2.0 * (-wz + xy)
        m[1][1] = ww - xx + yy - zz
        m[2][1] = 2.0 * (wx + yz)
        m[0][2] = 2.0 * (wy + xz)
        m[1][2] = 2.0 * (-wx + yz)
        m[2][2] = ww - xx - yy + zz
        for i in 0..<3 {
            m[i][0] *= scale
            m[i][1] *= scale
            m[i][2] *= scale
        }

        // The translation: the target centroid less the transformed source centroid.
        let sx = m[0][0] * sc[0] + m[0][1] * sc[1] + m[0][2] * sc[2]
        let sy = m[1][0] * sc[0] + m[1][1] * sc[1] + m[1][2] * sc[2]
        let sz = m[2][0] * sc[0] + m[2][1] * sc[1] + m[2][2] * sc[2]
        m[0][3] = tc[0] - sx
        m[1][3] = tc[1] - sy
        m[2][3] = tc[2] - sz
        m[3] = [0, 0, 0, 1]
        return m.flatMap { $0 }
    }

    /// The rotation and translation of a registration matrix as the viewer
    /// applies it: the 3 × 3 block row by row, then the last column's first
    /// three entries.
    public static func rotationAndTranslation(_ matrix: [Double]) -> [Double] {
        [matrix[0], matrix[1], matrix[2], matrix[4], matrix[5], matrix[6], matrix[8], matrix[9], matrix[10],
         matrix[3], matrix[7], matrix[11]]
    }

    /// The eigenvalues of a symmetric matrix, in decreasing order, and its
    /// eigenvectors as columns, each with more positive entries than negative,
    /// by Jacobi rotations of its upper triangle (vtkMath::JacobiN).
    static func jacobi(_ matrix: [[Double]]) -> ([Double], [[Double]]) {
        var a = matrix
        let n = a.count
        var v = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for ip in 0..<n { v[ip][ip] = 1 }
        var w = (0..<n).map { a[$0][$0] }
        var b = w
        var z = [Double](repeating: 0, count: n)

        func rotate(_ m: inout [[Double]], _ i: Int, _ j: Int, _ k: Int, _ l: Int, _ s: Double, _ tau: Double) {
            let g = m[i][j], h = m[k][l]
            m[i][j] = g - s * (h + g * tau)
            m[k][l] = h + s * (g - h * tau)
        }

        for sweep in 0..<20 {
            var sm = 0.0
            for ip in 0..<(n - 1) {
                for iq in (ip + 1)..<n { sm += abs(a[ip][iq]) }
            }
            if sm == 0.0 { break }
            let tresh = sweep < 3 ? 0.2 * sm / Double(n * n) : 0.0

            for ip in 0..<(n - 1) {
                for iq in (ip + 1)..<n {
                    let g = 100.0 * abs(a[ip][iq])
                    if sweep > 3 && (abs(w[ip]) + g) == abs(w[ip]) && (abs(w[iq]) + g) == abs(w[iq]) {
                        a[ip][iq] = 0.0
                    } else if abs(a[ip][iq]) > tresh {
                        var h = w[iq] - w[ip]
                        var t: Double
                        if (abs(h) + g) == abs(h) {
                            t = a[ip][iq] / h
                        } else {
                            let theta = 0.5 * h / a[ip][iq]
                            t = 1.0 / (abs(theta) + (1.0 + theta * theta).squareRoot())
                            if theta < 0.0 { t = -t }
                        }
                        let c = 1.0 / (1 + t * t).squareRoot()
                        let s = t * c
                        let tau = s / (1.0 + c)
                        h = t * a[ip][iq]
                        z[ip] -= h
                        z[iq] += h
                        w[ip] -= h
                        w[iq] += h
                        a[ip][iq] = 0.0

                        var j = 0
                        while j <= ip - 1 { rotate(&a, j, ip, j, iq, s, tau); j += 1 }
                        j = ip + 1
                        while j <= iq - 1 { rotate(&a, ip, j, j, iq, s, tau); j += 1 }
                        j = iq + 1
                        while j < n { rotate(&a, ip, j, iq, j, s, tau); j += 1 }
                        for j in 0..<n { rotate(&v, j, ip, j, iq, s, tau) }
                    }
                }
            }
            for ip in 0..<n {
                b[ip] += z[ip]
                w[ip] = b[ip]
                z[ip] = 0.0
            }
        }

        // In decreasing order; of equal values, the last one first.
        for j in 0..<(n - 1) {
            var k = j
            var tmp = w[k]
            for i in (j + 1)..<n where w[i] >= tmp {
                k = i
                tmp = w[k]
            }
            if k != j {
                w[k] = w[j]
                w[j] = tmp
                for i in 0..<n {
                    let swap = v[i][j]
                    v[i][j] = v[i][k]
                    v[i][k] = swap
                }
            }
        }
        // Each vector with at least half its entries positive.
        let half = (n >> 1) + (n & 1)
        for j in 0..<n {
            var positive = 0
            for i in 0..<n where v[i][j] >= 0.0 { positive += 1 }
            if positive < half {
                for i in 0..<n { v[i][j] *= -1.0 }
            }
        }
        return (w, v)
    }

    /// A unit vector perpendicular to `v1` (vtkMath::Perpendiculars with no
    /// angle).
    static func perpendicular(_ v1: [Double]) -> [Double] {
        let v1sq = v1[0] * v1[0], v2sq = v1[1] * v1[1], v3sq = v1[2] * v1[2]
        let r = (v1sq + v2sq + v3sq).squareRoot()
        let (dv1, dv2, dv3): (Int, Int, Int)
        if v1sq > v2sq && v1sq > v3sq {
            (dv1, dv2, dv3) = (0, 1, 2)
        } else if v2sq > v3sq {
            (dv1, dv2, dv3) = (1, 2, 0)
        } else {
            (dv1, dv2, dv3) = (2, 0, 1)
        }
        let a = v1[dv1] / r, b = v1[dv2] / r, c = v1[dv3] / r
        let tmp = (a * a + c * c).squareRoot()
        _ = b
        var v2 = [0.0, 0.0, 0.0]
        v2[dv1] = c / tmp
        v2[dv2] = 0
        v2[dv3] = -a / tmp
        return v2
    }
}
