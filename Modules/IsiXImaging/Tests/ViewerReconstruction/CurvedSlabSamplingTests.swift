//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Testing
@testable import IsiXImaging

struct CurvedSlabSamplingTests {
    @Test func thePlanesCoverTheWholeWidth() {
        // Planes 0.7 mm apart covered 2.8 mm of a slab of 3 mm.
        for (width, spacing) in [(3.0, 0.7), (1.0, 0.7), (2.0, 0.625), (0.4, 0.7), (10.0, 0.33), (1.25, 1.25), (50.0, 0.5)] {
            let planes = CurvedSlabSampling.planes(width: width, spacing: spacing, fixedDistance: 0)
            #expect(abs(Double(planes.count - 1) * planes.distance - width) < 1e-9, "\(width) mm at \(spacing) mm")
            #expect(planes.distance <= spacing + 1e-9, "\(width) mm at \(spacing) mm is sampled coarser than the volume")
            #expect(planes.count >= 2)
            // No finer than it takes: one plane fewer would be coarser than the volume.
            #expect(planes.count == 2 || width / Double(planes.count - 2) > spacing - 1e-9, "\(width) mm at \(spacing) mm")
        }
        let whole = CurvedSlabSampling.planes(width: 2.8, spacing: 0.7, fixedDistance: 0)
        #expect(whole.count == 5)
        #expect(abs(whole.distance - 0.7) < 1e-9)
        let thin = CurvedSlabSampling.planes(width: 1, spacing: 0.7, fixedDistance: 0)
        #expect(thin.count == 3)
        #expect(abs(thin.distance - 0.5) < 1e-12)
    }

    @Test func noSlabIsThePlaneOfTheCurve() {
        #expect(CurvedSlabSampling.planes(width: 0, spacing: 0.7, fixedDistance: 0) == (1, 0.7))
        #expect(CurvedSlabSampling.planes(width: -3, spacing: 0.7, fixedDistance: 0) == (1, 0.7))
        #expect(CurvedSlabSampling.planes(width: 3, spacing: 0, fixedDistance: 0) == (1, 0))
        #expect(CurvedSlabSampling.planes(width: .nan, spacing: 0.7, fixedDistance: 0) == (1, 0.7))
        #expect(CurvedSlabSampling.planes(width: 3, spacing: .nan, fixedDistance: 0) == (1, 0))
        #expect(CurvedSlabSampling.planes(width: .infinity, spacing: 0.7, fixedDistance: 0) == (1, 0.7))
        #expect(CurvedSlabSampling.planes(width: 1e12, spacing: 1e-6, fixedDistance: 0).count == 1)
    }

    @Test func aSlabIsSampledAtTheThicknessShown() {
        // Every thickness a window shows, at the spacings of the series checked in the app.
        for width in [0.625, 0.7, 1, 2, 2.1, 2.5, 3, 4, 10] {
            for step in [0.625, 0.7, 1] {
                let planes = CurvedSlabSampling.planes(width: width, maximumStep: step)
                #expect(abs(Double(planes.count - 1) * planes.step - width) < 1e-9, "\(width) mm at \(step) mm")
                #expect(planes.step <= step + 1e-12, "\(width) mm at \(step) mm")
            }
        }
        // 3 mm at 0.7 mm: six planes 0.6 mm apart, where five covered 2.8 mm.
        let three = CurvedSlabSampling.planes(width: 3, maximumStep: 0.7)
        #expect(three.count == 6)
        #expect(abs(three.step - 0.6) < 1e-12)
        #expect(CurvedSlabSampling.planes(width: 0, maximumStep: 0.7).count == 1)
        #expect(CurvedSlabSampling.planes(width: .nan, maximumStep: 0.7).count == 1)
        #expect(CurvedSlabSampling.planes(width: 3, maximumStep: 0).count == 1)
        #expect(CurvedSlabSampling.planes(width: 3, maximumStep: -1).count == 1)
    }

    @Test func aFixedStepHasThePlanesThatFit() {
        #expect(CurvedSlabSampling.planes(width: 3, step: 0.1) == 31)
        #expect(CurvedSlabSampling.planes(width: 3, step: 1) == 4)
        #expect(CurvedSlabSampling.planes(width: 3, step: 0.7) == 5)
        // 0.3 / 0.1 is 2.9999999999999996: the last plane is there all the same.
        #expect(CurvedSlabSampling.planes(width: 0.3, step: 0.1) == 4)
        #expect(CurvedSlabSampling.planes(width: 0, step: 1) == 1)
        #expect(CurvedSlabSampling.planes(width: 3, step: 0) == 1)
        #expect(CurvedSlabSampling.planes(width: .nan, step: 1) == 1)
        #expect(CurvedSlabSampling.planes(width: -3, step: 1) == 1)
    }

    @Test func aRequestThatFixesTheDistanceKeepsIt() {
        #expect(CurvedSlabSampling.planes(width: 3, spacing: 0.7, fixedDistance: 1) == (4, 1))
        #expect(CurvedSlabSampling.planes(width: 3, spacing: 0.7, fixedDistance: 0.7) == (5, 0.7))
        #expect(CurvedSlabSampling.planes(width: 0, spacing: 0.7, fixedDistance: 2) == (1, 2))
        #expect(CurvedSlabSampling.planes(width: -3, spacing: 0.7, fixedDistance: 2) == (1, 2))
        #expect(CurvedSlabSampling.planes(width: .nan, spacing: 0.7, fixedDistance: 2) == (1, 2))
        #expect(CurvedSlabSampling.planes(width: 1e300, spacing: 0.7, fixedDistance: 1e-300).count == 1)
    }
}
