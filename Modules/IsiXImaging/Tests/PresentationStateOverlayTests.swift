//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreGraphics
import Testing
import IsiXImaging

/// What a Grayscale Softcopy Presentation State puts over the images.
struct PresentationStateOverlayTests {

    let a = CGPoint(x: 10, y: 20), b = CGPoint(x: 13, y: 24)

    @Test func eachGraphicTypeBecomesItsShape() {
        #expect(PresentationStateOverlay.shape(kind: "text", text: "Hello", points: [a]) == .text(name: "Hello", anchor: a))
        #expect(PresentationStateOverlay.shape(kind: "TEXT", text: "", points: []) == .text(name: "GSPS", anchor: nil))
        #expect(PresentationStateOverlay.shape(kind: "TEXT", text: nil, points: [a]) == .text(name: "GSPS", anchor: a))
        #expect(PresentationStateOverlay.shape(kind: "POINT", text: nil, points: [a, b]) == .point(a))
        #expect(PresentationStateOverlay.shape(kind: "POLYLINE", text: nil, points: [a, b]) == .polyline([a, b]))
        #expect(PresentationStateOverlay.shape(kind: "INTERPOLATED", text: nil, points: [a, b]) == nil)
        #expect(PresentationStateOverlay.shape(kind: "POINT", text: nil, points: []) == nil)
    }

    @Test func aCircleIsItsCentreAndRimAndAnEllipseTheBoxOfItsPoints() {
        #expect(PresentationStateOverlay.shape(kind: "CIRCLE", text: nil, points: [a, b])
                == .oval(CGRect(x: 5, y: 15, width: 10, height: 10)))
        #expect(PresentationStateOverlay.shape(kind: "ELLIPSE", text: nil, points: [a, b, CGPoint(x: 8, y: 30)])
                == .oval(CGRect(x: 8, y: 20, width: 5, height: 10)))
        #expect(PresentationStateOverlay.shape(kind: "CIRCLE", text: nil, points: [a])
                == .oval(CGRect(x: 10, y: 20, width: 0, height: 0)))
    }

    @Test func thePresentationOfAnImageIsFoundByItsUIDAndTheFirstFrameThatMatches() {
        let frames = PresentationStateOverlay.candidateFrames(frameInFile: 0, recordedFrame: 0)
        #expect(frames == [1, 1, 1])
        #expect(PresentationStateOverlay.candidateFrames(frameInFile: 3, recordedFrame: 7) == [4, 3, 7])
        let presentations = [(sopInstanceUID: "1.2", frameNumber: 3), (sopInstanceUID: "1.2", frameNumber: 4), (sopInstanceUID: "1.3", frameNumber: 1)]
        #expect(PresentationStateOverlay.presentationIndex(sopInstanceUID: "1.2", frames: [4, 3, 7], in: presentations) == 1)
        #expect(PresentationStateOverlay.presentationIndex(sopInstanceUID: "1.2", frames: [9, 3], in: presentations) == 0)
        #expect(PresentationStateOverlay.presentationIndex(sopInstanceUID: "1.4", frames: [1], in: presentations) == nil)
    }

    @Test func onlyAMagnifiedAreaSetsTheScale() {
        #expect(PresentationStateOverlay.magnification(sizeMode: "MAGNIFY", magnification: 2) == 2)
        #expect(PresentationStateOverlay.magnification(sizeMode: "MAGNIFY", magnification: 0) == nil)
        #expect(PresentationStateOverlay.magnification(sizeMode: "SCALE TO FIT", magnification: 2) == nil)
        #expect(PresentationStateOverlay.fitsView(sizeMode: "SCALE TO FIT"))
        #expect(!PresentationStateOverlay.fitsView(sizeMode: "MAGNIFY") && !PresentationStateOverlay.fitsView(sizeMode: "TRUE SIZE"))
    }

    /// A displayed area that begins before the image and ends past it
    /// (PS 3.3 C.10.4), fitted to a view: its middle is the middle of the
    /// view, from which the view's coordinates are counted, and none of it is
    /// left out, however the image is turned or flipped.
    @Test func aDisplayedAreaOutsideTheImageIsFramedWhole() {
        let area = CGRect(x: -10, y: -1, width: 532, height: 258)
        let image = ViewTransform.ImageExtent(width: 512, height: 256, pixelRatio: 1)
        let size = CGSize(width: 800, height: 600), deg2rad = Double.pi / 180
        for rotation: Float in [0, 90, 180, 270] {
            for flips in [(false, false), (true, false), (false, true), (true, true)] {
                let scale = ViewTransform.fitScale(viewSize: size, width: area.width, height: area.height, pixelRatio: 1,
                                                   rotation: rotation, fallback: 1)
                let origin = ViewTransform.openingOrigin(content: area, width: 512, height: 256, scale: scale, pixelRatio: 1)
                var state = ViewportState()
                state.scale = scale
                state.rotation = rotation
                state.xFlipped = flips.0
                state.yFlipped = flips.1
                state.origin = CGPoint(x: CGFloat(origin.x), y: CGFloat(origin.y))
                func shown(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                    ViewTransform.imageToView(CGPoint(x: x, y: y), viewport: state, drawingSize: size, image: image, deg2rad: deg2rad)
                }
                let middle = shown(area.midX, area.midY)
                #expect(abs(middle.x) < 0.01 && abs(middle.y) < 0.01, "rotation \(rotation), flips \(flips): \(middle)")
                let corners = [shown(area.minX, area.minY), shown(area.maxX, area.minY), shown(area.minX, area.maxY), shown(area.maxX, area.maxY)]
                #expect(corners.allSatisfy { abs($0.x) < 400.01 && abs($0.y) < 300.01 }, "rotation \(rotation): \(corners)")
                // As large as the view allows: the area touches two opposite edges of it.
                let xs = corners.map(\.x), ys = corners.map(\.y)
                let touches = (xs.min()! < -399.99 && xs.max()! > 399.99) || (ys.min()! < -299.99 && ys.max()! > 299.99)
                #expect(touches, "rotation \(rotation): \(corners)")
            }
        }
        // Held to the image, the origin moved and the size stayed: the middle of that rectangle is not the area's.
        let shifted = ViewTransform.openingOrigin(content: CGRect(x: 0, y: 0, width: 532, height: 258), width: 512, height: 256, scale: 1, pixelRatio: 1)
        let kept = ViewTransform.openingOrigin(content: area, width: 512, height: 256, scale: 1, pixelRatio: 1)
        #expect(kept.x - shifted.x == 10 && shifted.y - kept.y == 1)
    }

    @Test func theFramesOfAMissingReferenceAreListedOrAll() {
        #expect(PresentationStateOverlay.framesDescription([]) == "all")
        #expect(PresentationStateOverlay.framesDescription([1, 2]) == "1,2")
    }
}
