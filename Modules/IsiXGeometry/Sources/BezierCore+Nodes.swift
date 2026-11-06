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

public extension BezierCore {

    /// A smooth curve through the nodes: a cubic spline of each coordinate
    /// against the distance travelled, continuous to the second derivative,
    /// as curves of one segment per pair of nodes. Two nodes give a line.
    ///
    /// The ends get one more node outside the path: along the end segments
    /// (openEnds), or the node next to the other end (endsMeet). The
    /// tridiagonal system is solved as in Numerical Recipes in C; the three
    /// coordinates are solved together, a lane each.
    static func curve(through nodes: [Vector3], style: BezierNodeStyle) -> BezierCore {
        assert(nodes.count >= 2)
        let core = BezierCore()
        if nodes.count == 2 {
            core.add(.moveTo, endpoint: nodes[0])
            core.add(.lineTo, endpoint: nodes[1])
            return core
        }

        // Element 0 is not used, except h[0].
        let nb = nodes.count + 2
        var p = [Vector3](repeating: .zero, count: nb)
        for (i, node) in nodes.enumerated() {
            p[i + 1] = node
        }
        switch style {
        case .openEnds:
            p[0] = (-p[2]).addingProduct(2.0, p[1])
            p[nb - 1] = (-p[nb - 3]).addingProduct(2.0, p[nb - 2])
        case .endsMeet:
            p[0] = p[nb - 3]
            p[nb - 1] = p[2]
        }

        // h[i]: from point i to i + 1; d[i]: from the start to point i.
        var h = [Double](repeating: 0.0, count: nb)
        var d = [Double](repeating: 0.0, count: nb)
        for i in 0..<(nb - 1) {
            h[i] = (p[i + 1] - p[i]).length
            d[i + 1] = d[i] + h[i]
        }

        var a = [Double](repeating: 0.0, count: nb)
        var c = [Double](repeating: 0.0, count: nb)
        for i in 2..<(nb - 1) {
            a[i] = 2.0 * h[i - 1] / (h[i] + h[i - 1])
        }
        for i in 1..<(nb - 2) {
            c[i] = 2.0 * h[i] / (h[i] + h[i - 1])
        }

        // g[i] = 6 * the second divided difference around point i.
        var g = [Vector3](repeating: .zero, count: nb)
        for i in 1..<(nb - 1) {
            g[i] = 6.0 * (((p[i - 1] - p[i]) / (d[i - 1] - d[i])) - ((p[i] - p[i + 1]) / (d[i] - d[i + 1]))) / (d[i - 1] - d[i + 1])
        }

        // The second derivatives, from the tridiagonal system whose diagonal is 4.
        let b = 4.0
        var bet = 4.0
        var gam = [Double](repeating: 0.0, count: nb)
        var cv = [Vector3](repeating: .zero, count: nb)
        cv[1] = g[1] / b
        for j in 2..<(nb - 1) {
            gam[j] = c[j - 1] / bet
            bet = b.addingProduct(-a[j], gam[j])
            cv[j] = g[j].addingProduct(-a[j], cv[j - 1]) / bet
        }
        for j in stride(from: nb - 2, through: 1, by: -1) {
            cv[j] = cv[j].addingProduct(-gam[j + 1], cv[j + 1])
        }

        // On each interval S(t) = aa + bb t + cc t^2 + dd t^3, as a Bézier curve.
        var lastEndpoint = p[1]
        core.add(.moveTo, endpoint: lastEndpoint)
        for i in 1..<(nb - 2) {
            let hi = h[i]
            let cc = cv[i]
            let aa = p[i]
            let dd = (cv[i + 1] - cv[i]) / (3.0 * hi)
            let bb = ((p[i + 1] - p[i]) / hi).addingProduct(-(hi / 3.0), cv[i + 1].addingProduct(2.0, cv[i]))

            let endpoint = aa.addingProduct(bb, hi).addingProduct(cc * hi, hi).addingProduct(dd * hi * hi, hi)
            let control1 = lastEndpoint + (bb * hi) / 3.0
            let slope = bb.addingProduct(2.0 * cc, hi).addingProduct(3.0 * dd * hi, hi)
            let control2 = endpoint - (slope * hi) / 3.0

            core.add(.curveTo, control1: control1, control2: control2, endpoint: endpoint)
            lastEndpoint = endpoint
        }
        return core
    }
}
