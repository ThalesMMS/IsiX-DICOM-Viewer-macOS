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
import Foundation
import Testing
import IsiXROI

private typealias Item = ROIEditingSession.Item
private let sleep = ROISelection.sleep, drawing = ROISelection.drawing
private let selected = ROISelection.selected, modify = ROISelection.selectedModify

struct ROIEditingSessionTests {

    // MARK: - Successor after a deletion

    @Test func successorIsTheFrontOfTheList() {
        // Created a, b, c: each new ROI went to the front, so the list is c, b, a.
        let session = ROIEditingSession(items: [Item(mode: sleep), Item(mode: sleep), Item(mode: sleep)])
        #expect(session.successorAfterDeletion(enabled: true) == 0)
        #expect(session.successorAfterDeletion(enabled: false) == nil)
        #expect(ROIEditingSession(items: []).successorAfterDeletion(enabled: true) == nil)
    }

    @Test func successorSkipsHiddenLockedAndUnselectableROIs() {
        let session = ROIEditingSession(items: [Item(mode: sleep, hidden: true), Item(mode: sleep, locked: true),
                                                Item(mode: sleep, selectable: false), Item(mode: sleep)])
        #expect(session.successorAfterDeletion(enabled: true) == 3)
    }

    @Test func aROIStillSelectedOrEditedKeepsTheSelection() {
        for mode in [drawing, selected, modify] {
            let session = ROIEditingSession(items: [Item(mode: mode), Item(mode: sleep)])
            #expect(session.successorAfterDeletion(enabled: true) == nil)
        }
    }

    // MARK: - Invalid ROIs and stopping the edition

    @Test func anInvalidROIGoesAndLetsTheCurrentOneGo() {
        #expect(ROIEditingSession.invalidRemoval(isValid: true, isCurrentROI: true) == nil)
        #expect(ROIEditingSession.invalidRemoval(isValid: false, isCurrentROI: false)?.releasesCurrentROI == false)
        #expect(ROIEditingSession.invalidRemoval(isValid: false, isCurrentROI: true)?.releasesCurrentROI == true)
    }

    @Test func stoppingEndsTheEditionUnlessShownElsewhere() {
        for mode in [drawing, modify] {
            #expect(ROIEditingSession.stopping(mode: mode, force: false) { 1 } == .ends(checksValidity: true))
            #expect(ROIEditingSession.stopping(mode: mode, force: false) { 0 } == .ends(checksValidity: true))
            #expect(ROIEditingSession.stopping(mode: mode, force: false) { 2 } == .keepsEditing)
            #expect(ROIEditingSession.stopping(mode: mode, force: true) { 2 } == .ends(checksValidity: true))
        }
        for mode in [sleep, selected] {
            #expect(ROIEditingSession.stopping(mode: mode, force: false) { 3 } == .ends(checksValidity: false))
        }
        #expect([sleep, drawing, selected, modify].map(ROIEditingSession.modeWhenStopped) == [sleep, selected, selected, selected])
    }

    // MARK: - A click of a ROI tool

    /// The former -mouseDown: of DCMView, on the hits of each ROI.
    private func formerToolClick(_ modes: [Int], handles: Set<Int>, bodies: Set<Int>, shift: Bool, command: Bool)
        -> (target: Int, doNothing: Bool, deselectAll: Bool) {
        var selected = -1, roiFound = false, doNothing = false, deselectAll = false
        if !(command && shift) {
            for i in modes.indices where handles.contains(i) { selected = i; roiFound = true; break }
        }
        if !roiFound {
            for i in modes.indices where bodies.contains(i) { selected = i; break }
        }
        if shift && !command {
            if selected != -1 && modes[selected] == ROISelection.selected { doNothing = true }
        } else if selected == -1 || (modes[selected] != ROISelection.selected && modes[selected] != ROISelection.selectedModify) {
            deselectAll = true
        }
        return (selected, doNothing, deselectAll)
    }

    @Test func toolClickTakesTheROIUnderItAsTheFormerMouseDownDid() {
        let modeSets: [[Int]] = [[], [sleep], [selected, sleep], [modify, drawing, selected], [sleep, selected, sleep]]
        for modes in modeSets {
            let all = Array(modes.indices)
            let subsets: [Set<Int>] = [[], Set(all), Set(all.suffix(1)), Set(all.prefix(1))]
            for handles in subsets {
                for bodies in subsets {
                    for (shift, command) in [(false, false), (true, false), (false, true), (true, true)] {
                        var asked: [String] = []
                        let click = ROIEditingSession(items: modes.map { Item(mode: $0) })
                            .toolClick(shift: shift, command: command) { index, isHandle in
                                asked.append("\(isHandle ? "h" : "b")\(index)")
                                return isHandle ? handles.contains(index) : bodies.contains(index)
                            }
                        let former = formerToolClick(modes, handles: handles, bodies: bodies, shift: shift, command: command)
                        #expect((click.target ?? -1) == former.target)
                        #expect(click.deselectsTarget == former.doNothing)
                        #expect(click.deselectsAll == former.deselectAll)
                        // The hit tests are asked as the former loops asked them, up to the first hit.
                        var expected: [String] = []
                        var found = false
                        if !(command && shift) {
                            for i in modes.indices { expected.append("h\(i)"); if handles.contains(i) { found = true; break } }
                        }
                        if !found { for i in modes.indices { expected.append("b\(i)"); if bodies.contains(i) { break } } }
                        #expect(asked == expected)
                    }
                }
            }
        }
    }

    // MARK: - Paste

    @Test func aPastedLengthFitsItsOwnSeriesAndFrame() {
        #expect(ROIEditingSession.pastedLengthFits(series: "s", frameOfReference: "f", imageSeries: "s", imageFrameOfReference: "f"))
        #expect(!ROIEditingSession.pastedLengthFits(series: "s", frameOfReference: "f", imageSeries: "t", imageFrameOfReference: "f"))
        #expect(!ROIEditingSession.pastedLengthFits(series: "s", frameOfReference: "f", imageSeries: "s", imageFrameOfReference: nil))
        #expect(!ROIEditingSession.pastedLengthFits(series: nil, frameOfReference: "f", imageSeries: nil, imageFrameOfReference: "f"))
        #expect(!ROIEditingSession.pastedLengthFits(series: "s", frameOfReference: nil, imageSeries: "s", imageFrameOfReference: nil))
    }

    // MARK: - Joining a finished contour

    @Test func joinedImagesAreTheNeighboursNearestFirst() {
        let images = ROIEditingSession.joinedImages(around: 3, reach: 2, imageCount: 8, roiListCount: 8)
        #expect(images.map(\.image) == [2, 4, 1, 5] && images.map(\.distance) == [1, 1, 2, 2])
        // The ends of the series, and lists shorter than the images.
        #expect(ROIEditingSession.joinedImages(around: 0, reach: 2, imageCount: 8, roiListCount: 8).map(\.image) == [1, 2])
        #expect(ROIEditingSession.joinedImages(around: 3, reach: 2, imageCount: 8, roiListCount: 5).map(\.image) == [2, 4, 1])
        #expect(ROIEditingSession.joinedImages(around: 3, reach: 0, imageCount: 8, roiListCount: 8).isEmpty)
        #expect(ROIEditingSession.joinedImages(around: 0, reach: 1, imageCount: 1, roiListCount: 1).isEmpty)
    }

    @Test func joinedImagesOfAWholeSeriesAreEveryOtherImageNearestFirst() {
        let images = ROIEditingSession.joinedImages(around: 4, imageCount: 7, roiListCount: 7)
        #expect(images.map(\.image) == [3, 5, 2, 6, 1, 0] && images.map(\.distance) == [1, 1, 2, 2, 3, 4])
        // The first image, lists shorter than the images, and a single image.
        #expect(ROIEditingSession.joinedImages(around: 0, imageCount: 4, roiListCount: 4).map(\.image) == [1, 2, 3])
        #expect(ROIEditingSession.joinedImages(around: 1, imageCount: 6, roiListCount: 3).map(\.image) == [0, 2])
        #expect(ROIEditingSession.joinedImages(around: 0, imageCount: 1, roiListCount: 1).isEmpty)
        #expect(ROIEditingSession.joinedImages(around: 0, imageCount: 0, roiListCount: 0).isEmpty)
    }

    @Test func onlyParallelPlanesAreCompared() {
        let axial: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        let flipped: [Double] = [1, 0, 0, 0, -1, 0, 0, 0, -1]
        let sagittal: [Double] = [0, 1, 0, 0, 0, 1, 1, 0, 0]
        #expect(ROIEditingSession.planesAreParallel(axial, axial))
        #expect(ROIEditingSession.planesAreParallel(axial, flipped))
        #expect(!ROIEditingSession.planesAreParallel(axial, sagittal))
        // The dot product, fused as the Objective-C compiler fused it.
        let a: [Double] = [0, 0, 0, 0, 0, 0, 0.1, 0.2, 0.97467943448]
        let b: [Double] = [0, 0, 0, 0, 0, 0, 0.1, 0.2, 0.97467943448]
        let fused = abs((a[7] * b[7]).addingProduct(a[6], b[6]).addingProduct(a[8], b[8]))
        #expect(ROIEditingSession.planesAreParallel(a, b) == !(fused < 0.99))
        // As the former test, an orientation that is not a number is compared.
        #expect(ROIEditingSession.planesAreParallel(axial, [0, 0, 0, 0, 0, 0, .nan, 0, 0]))
    }

    @Test func aJoinedContourTakesTheCandidatesName() {
        #expect(ROIEditingSession.joinedName(candidate: 1, names: ["Oval 1", "Lesion"], current: "Oval 3") == "Lesion")
        #expect(ROIEditingSession.joinedName(candidate: -1, names: ["Oval 1"], current: "Oval 3") == nil)
        #expect(ROIEditingSession.joinedName(candidate: 0, names: ["Oval 1"], current: "Oval 1") == nil)
        #expect(ROIEditingSession.joinedName(candidate: 0, names: ["Oval 1"], current: nil) == "Oval 1")
    }
}
