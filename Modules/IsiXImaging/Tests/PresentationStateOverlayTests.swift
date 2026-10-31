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
    }

    @Test func theFramesOfAMissingReferenceAreListedOrAll() {
        #expect(PresentationStateOverlay.framesDescription([]) == "all")
        #expect(PresentationStateOverlay.framesDescription([1, 2]) == "1,2")
    }
}
