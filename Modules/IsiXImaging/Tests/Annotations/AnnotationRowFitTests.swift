//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation
import Testing
@testable import IsiXImaging

// The room of the side lines of an image view in their row. Every character
// is 10 wide here, «…» too, so a width is ten times a count.

private typealias Command = AnnotationOverlayLayout.Command

private func wide(_ text: String) -> Double { Double(text.count) * 10 }

private func letters(_ count: Int, _ letter: Character = "a") -> String { String(repeating: letter, count: count) }

/// The lines of a position as the layout stacks them, one text a line.
private func lines(_ layout: AnnotationOverlayLayout, _ position: String, _ texts: [String]) -> [Command] {
    let start = layout.start(of: position), increment = Int(layout.increment(of: position))
    return texts.enumerated().map { index, text in
        .text(text, x: Int(start.x), y: Int(start.y) + index * increment, alignment: AnnotationOverlayLayout.alignment(of: position))
    }
}

private func layout(width: Double, height: Double = 400, orientation: Bool = false) -> AnnotationOverlayLayout {
    let layout = AnnotationOverlayLayout(originX: 0, originY: 0, width: width, height: height, scale: 1, characterWidth: 10, lineHeight: 16)
    return orientation ? layout.withOrientationDrawn() : layout
}

private func fit(_ layout: AnnotationOverlayLayout, _ groups: [[Command]], fixed: [Command] = [], measures: inout Int) -> [[Command]] {
    var count = 0
    let fitted = AnnotationRowFit.fit(groups, fixed: fixed, in: layout,
                                      width: { count += 1; return wide($0) },
                                      cut: { AnnotationRowFit.cut($0, to: $1, width: wide) })
    measures = count
    return fitted
}

private func fit(_ layout: AnnotationOverlayLayout, _ groups: [[Command]], fixed: [Command] = []) -> [[Command]] {
    var measures = 0
    return fit(layout, groups, fixed: fixed, measures: &measures)
}

private func texts(_ commands: [Command]) -> [String] {
    commands.compactMap { if case let .text(text, _, _, _) = $0 { return text } else { return nil } }
}

struct AnnotationRowFitTests {
    // MARK: - The two widths of a row

    @Test func bothLinesKeepTheirWidthWhenTheRowHoldsThemAndTheGap() {
        #expect(AnnotationRowFit.widths(left: 100, right: 80, row: 190, gap: 10) == (100, 80))
        #expect(AnnotationRowFit.widths(left: 100, right: 80, row: 500, gap: 10) == (100, 80))
    }

    @Test func theSideThatNeedsNoMoreThanHalfStaysWholeAndTheOtherTakesTheRest() {
        #expect(AnnotationRowFit.widths(left: 60, right: 300, row: 210, gap: 10) == (60, 140))
        #expect(AnnotationRowFit.widths(left: 300, right: 60, row: 210, gap: 10) == (140, 60))
        // Exactly half is no more than half.
        #expect(AnnotationRowFit.widths(left: 100, right: 300, row: 210, gap: 10) == (100, 100))
    }

    @Test func twoLinesThatBothNeedMoreThanHalfHaveHalfEach() {
        #expect(AnnotationRowFit.widths(left: 150, right: 300, row: 210, gap: 10) == (100, 100))
        #expect(AnnotationRowFit.widths(left: 101, right: 101, row: 210, gap: 10) == (100, 100))
    }

    @Test func aRowNarrowerThanItsGapLeavesNoRoom() {
        #expect(AnnotationRowFit.widths(left: 50, right: 50, row: 8, gap: 10) == (0, 0))
    }

    // MARK: - The cut

    @Test func aTextItsRoomHoldsIsNotCut() {
        #expect(AnnotationRowFit.cut("Im: 12/120", to: 100, width: wide) == "Im: 12/120")
    }

    @Test func aTextIsCutAtItsEndWithTheEllipsisInsideItsRoom() {
        let cut = AnnotationRowFit.cut("Thickness: 2.00 mm Location: -32.58 mm", to: 150, width: wide)
        #expect(cut == "Thickness: 2.0…")
        #expect(wide(cut) <= 150)
        // One character more would not fit.
        #expect(wide("Thickness: 2.00…") > 150)
    }

    @Test func theSpacesBeforeTheEllipsisAreLeftOut() {
        #expect(AnnotationRowFit.cut("DOE JOHN, 56 y", to: 50, width: wide) == "DOE…")
    }

    @Test func aRoomThatHoldsOnlyTheEllipsisShowsItAndANarrowerOneNothing() {
        #expect(AnnotationRowFit.cut("Uncompressed", to: 10, width: wide) == "…")
        #expect(AnnotationRowFit.cut("Uncompressed", to: 9, width: wide) == "")
        #expect(AnnotationRowFit.cut("Uncompressed", to: 0, width: wide) == "")
    }

    // MARK: - The rows of a view

    @Test func aViewWideEnoughDrawsTheSameStringsAtTheSamePlaces() {
        let layout = layout(width: 1024, height: 768, orientation: true)
        let groups = [
            lines(layout, "TopLeft", ["Image size: 512 x 512", "View size: 1024 x 768", "WL: 40 WW: 400"]),
            lines(layout, "TopRight", ["DOE^JOHN ( 56 y , 56 y )", "Head", "12"]),
            lines(layout, "LowerLeft", ["Thickness: 2.00 mm Location: -32.58 mm", "Uncompressed", "Im: 1/120", "Zoom: 287% Angle: 0"]),
            lines(layout, "LowerRight", ["14/11/2026, 12:00:00 PM", "IsiX"]),
            lines(layout, "MiddleLeft", ["3"]),
            lines(layout, "TopMiddle", ["Key image"]),
            [.plugin(x: 6, y: 100, alignment: .left), .orientation],
            [.text("Made In IsiX DICOM Viewer", x: layout.signature.x, y: layout.signature.y, alignment: .right)],
        ]
        let letters = layout.orientationCommands(left: "R", right: "L", top: "A", bottom: "P", notices: ["VOI LUT Applied"])
        #expect(fit(layout, groups, fixed: letters) == groups)
        #expect(fit(layout, groups) == groups)
    }

    @Test func theShortSideStaysWholeAndTheLongOneIsCutToTheRest() {
        // Left edge 6, right edge 298: a row of 292, 282 without the gap.
        let layout = layout(width: 300)
        let patient = letters(40, "p")
        let groups = [lines(layout, "TopLeft", ["WL: 40"]), lines(layout, "TopRight", [patient])]
        let fitted = fit(layout, groups)
        #expect(fitted[0] == groups[0])
        // 282 - 60 = 222: twenty-one characters and «…».
        #expect(texts(fitted[1]) == [letters(21, "p") + "…"])
        // The line is where it was: only its text changes.
        if case let .text(_, x, y, alignment) = fitted[1][0], case let .text(_, formerX, formerY, formerAlignment) = groups[1][0] {
            #expect(x == formerX && y == formerY && alignment == formerAlignment)
        } else {
            Issue.record("the right line is not a text")
        }
        // The same with the sides exchanged.
        let exchanged = fit(layout, [lines(layout, "TopLeft", [patient]), lines(layout, "TopRight", ["WL: 40"])])
        #expect(texts(exchanged[0]) == [letters(21, "p") + "…"])
        #expect(texts(exchanged[1]) == ["WL: 40"])
    }

    @Test func twoLongLinesHaveHalfTheRowEach() {
        let layout = layout(width: 300)
        let fitted = fit(layout, [lines(layout, "TopLeft", [letters(30, "l")]), lines(layout, "TopRight", [letters(40, "r")])])
        // Half of 282 is 141: thirteen characters and «…» each.
        #expect(texts(fitted[0]) == [letters(13, "l") + "…"])
        #expect(texts(fitted[1]) == [letters(13, "r") + "…"])
    }

    @Test func onlyTheRowsThatDoNotFitAreCut() {
        let layout = layout(width: 300)
        let groups = [lines(layout, "TopLeft", ["Image size", letters(30, "l"), "WL: 40"]),
                      lines(layout, "TopRight", [letters(18, "r"), letters(40, "r"), "12"])]
        let fitted = fit(layout, groups)
        #expect(texts(fitted[0]) == ["Image size", letters(13, "l") + "…", "WL: 40"])
        #expect(texts(fitted[1]) == [letters(18, "r"), letters(13, "r") + "…", "12"])
    }

    @Test func aLineAloneInItsRowTakesTheWholeRowAndNoMore() {
        let layout = layout(width: 300)
        // 292 between the edges: twenty-nine characters fit, thirty do not.
        let fits = [lines(layout, "TopLeft", [letters(29)])]
        #expect(fit(layout, fits) == fits)
        #expect(texts(fit(layout, [lines(layout, "TopLeft", [letters(30)])])[0]) == [letters(28) + "…"])
        #expect(texts(fit(layout, [lines(layout, "LowerRight", [letters(30)])])[0]) == [letters(28) + "…"])
        // A line of another row on the other side takes nothing from it.
        let apart: [[Command]] = [[.text(letters(29), x: 6, y: 18, alignment: .left)], [.text(letters(29), x: 298, y: 34, alignment: .right)]]
        #expect(fit(layout, apart) == apart)
    }

    @Test func aRowTooNarrowForTheEllipsisDrawsNothing() {
        // 20 between the edges, 10 without the gap, 5 a side: less than «…».
        let layout = layout(width: 28)
        let fitted = fit(layout, [lines(layout, "TopLeft", ["WL: 40", "x"]), lines(layout, "TopRight", ["DOE^JOHN"]),
                                  [.plugin(x: 6, y: 50, alignment: .left)]])
        // The second left line is alone in its row and fits; the first of each side is gone.
        #expect(texts(fitted[0]) == ["x"])
        #expect(fitted[1].isEmpty)
        #expect(fitted[2] == [.plugin(x: 6, y: 50, alignment: .left)])
    }

    @Test func theLowerRightLinesFaceTheLowerLeftLinesOfTheirHeightAndTheSignatureTheLowestOne() {
        let layout = layout(width: 300)
        let lowerLeft = lines(layout, "LowerLeft", [letters(40, "a"), letters(40, "b"), "Im: 1/1"])
        let lowerRight = lines(layout, "LowerRight", [letters(8, "d")])
        let signature: [Command] = [.text(letters(10, "s"), x: layout.signature.x, y: layout.signature.y, alignment: .right)]
        let fitted = fit(layout, [lowerLeft, lowerRight, signature])
        // The lowest left line shares its row with the signature (ten characters), the one above it with the
        // lower right line (eight), and the third is alone.
        #expect(texts(fitted[0]) == [letters(17, "a") + "…", letters(19, "b") + "…", "Im: 1/1"])
        #expect(fitted[1] == lowerRight)
        #expect(fitted[2] == signature)
    }

    @Test func whatStandsInTheMiddleKeepsItsPlaceAndTheSideLinesStopAGapFromIt() {
        let layout = layout(width: 300, orientation: true)
        let letters = layout.orientationCommands(left: "R", right: "L", top: "A", bottom: "P", notices: [])
        // The top letter starts at 145 and ends at 155; the bottom one starts at 150.
        let groups = [lines(layout, "TopLeft", [String(repeating: "l", count: 20)]), lines(layout, "TopRight", [String(repeating: "r", count: 20)]),
                      lines(layout, "LowerLeft", [String(repeating: "b", count: 20)]), lines(layout, "LowerMiddle", ["Key"])]
        let fitted = fit(layout, groups, fixed: letters)
        // Left: from 6 to 135. Right: from 165 to 298. Each side for itself, though the two would not share the row.
        #expect(texts(fitted[0]) == [String(repeating: "l", count: 11) + "…"])
        #expect(texts(fitted[1]) == [String(repeating: "r", count: 12) + "…"])
        // The lower left line stops before the lower middle line (centred on 150, a line above the bottom letter's row
        // once the letters are drawn) or the bottom letter, whichever is in its row.
        #expect(wide(texts(fitted[2])[0]) <= 150 - 10 - 6)
        // The line of the middle is as it was.
        #expect(fitted[3] == groups[3])
    }

    @Test func aViewWideEnoughForTheWidestCharactersMeasuresNothing() {
        let broad = layout(width: 1024, orientation: true)
        let groups = [lines(broad, "TopLeft", [letters(20)]), lines(broad, "TopRight", [letters(20)]), lines(broad, "LowerLeft", [letters(20)])]
        let fixed = broad.orientationCommands(left: "R", right: "L", top: "A", bottom: "P", notices: ["VOI LUT Applied"])
        let bounds = Double(broad.start(of: "MiddleLeft").x)...Double(broad.start(of: "MiddleRight").x)
        var measures = 0
        // Twenty units of 18 at the most are 360 a side, short of the letters in the middle of 1024.
        let roomy = AnnotationRowFit.fit(groups, fixed: fixed, bounds: bounds, lineHeight: 16, gap: 10, widestCharacter: 18,
                                         width: { measures += 1; return wide($0) }, cut: { text, _ in text })
        #expect(roomy == groups)
        #expect(measures == 0)
        // At 30 a unit the lines could reach the letters: they are measured, and fit.
        let measured = AnnotationRowFit.fit(groups, fixed: fixed, bounds: bounds, lineHeight: 16, gap: 10, widestCharacter: 30,
                                            width: { measures += 1; return wide($0) }, cut: { text, _ in text })
        #expect(measured == groups)
        #expect(measures > 0)
        // The widest character changes no cut: a row that has no room is cut the same with it and without.
        let narrow = layout(width: 300)
        let long = [lines(narrow, "TopLeft", [letters(30, "l")]), lines(narrow, "TopRight", [letters(40, "r")])]
        let narrowBounds = Double(narrow.start(of: "MiddleLeft").x)...Double(narrow.start(of: "MiddleRight").x)
        let with = AnnotationRowFit.fit(long, bounds: narrowBounds, lineHeight: 16, gap: 10, widestCharacter: 18, width: wide,
                                        cut: { AnnotationRowFit.cut($0, to: $1, width: wide) })
        #expect(with == fit(narrow, long))
    }

    @Test func aLineThatFitsIsMeasuredOnceAndNothingIsCut() {
        let layout = layout(width: 1024)
        let groups = [lines(layout, "TopLeft", ["a", "b"]), lines(layout, "TopRight", ["c"])]
        var measures = 0
        var cuts = 0
        let bounds = Double(layout.start(of: "MiddleLeft").x)...Double(layout.start(of: "MiddleRight").x)
        let fitted = AnnotationRowFit.fit(groups, bounds: bounds, lineHeight: 16, gap: 10, width: { measures += 1; return wide($0) },
                                          cut: { text, _ in cuts += 1; return text })
        #expect(fitted == groups)
        #expect(measures == 3)
        #expect(cuts == 0)
    }

    // MARK: - A view narrower than its margins

    /// A layout as a view of `width` points gives it at `scale`: its sizes are backing pixels.
    private func shrunk(width: Double, scale: Float, edgeReserve: Double = 0) -> AnnotationOverlayLayout {
        AnnotationOverlayLayout(originX: 0, originY: 0, width: width * Double(scale), height: 400 * Double(scale), scale: scale,
                                characterWidth: 10 * Double(scale), lineHeight: 16 * Double(scale), edgeReserve: edgeReserve)
    }

    @Test func aViewNarrowerThanItsMarginsHasNoSideEdges() {
        // The left lines start 6 points in and the right ones end 2 points in: 8 points of margins.
        for scale: Float in [1, 2] {
            for width in [0.0, 1, 7] {
                #expect(shrunk(width: width, scale: scale).sideEdges == nil, "width \(width), scale \(scale)")
            }
            let edges = shrunk(width: 8, scale: scale).sideEdges
            #expect(edges?.lowerBound == Double(6 * scale))
            #expect(edges?.upperBound == Double(6 * scale))
            #expect(shrunk(width: 9, scale: scale).sideEdges != nil)
            // The frame of a 2D viewer takes its room on each side as well.
            #expect(shrunk(width: 15, scale: scale, edgeReserve: 4).sideEdges == nil)
            #expect(shrunk(width: 16, scale: scale, edgeReserve: 4).sideEdges != nil)
        }
        #expect(layout(width: 1024).sideEdges == 6...1022)
    }

    @Test func aViewNarrowerThanItsMarginsDrawsNoSideLineAndMeasuresNothing() {
        for scale: Float in [1, 2] {
            for width in [0.0, 1, 7] {
                let layout = shrunk(width: width, scale: scale)
                let signature = layout.signature
                let groups = [lines(layout, "TopLeft", ["name", "study"]), lines(layout, "TopRight", ["hospital"]),
                              lines(layout, "MiddleLeft", ["left"]), lines(layout, "MiddleRight", ["right"]),
                              lines(layout, "LowerLeft", ["zoom"]), lines(layout, "LowerRight", ["date"]),
                              lines(layout, "TopMiddle", ["top"]) + [.orientation, .plugin(x: 3, y: 40, alignment: .left)],
                              [.text("signature", x: signature.x, y: signature.y, alignment: .right)]]
                var measures = 0
                let fitted = fit(layout, groups, fixed: layout.orientationCommands(left: "R", right: "L", top: "A", bottom: "P", notices: ["notice"]),
                                 measures: &measures)
                #expect(fitted.count == groups.count)
                #expect(fitted.flatMap { texts($0) } == ["top"], "width \(width), scale \(scale)")
                #expect(fitted[6] == groups[6])
                #expect(fitted[7].isEmpty)
                #expect(measures == 0)
            }
        }
    }

    @Test func aViewAsWideAsItsMarginsCutsItsSideLinesToNothingWithoutASideEdgeCrossingTheOther() {
        // The two edges meet: no line has room for «…», and none is drawn.
        let layout = shrunk(width: 8, scale: 1)
        let fitted = fit(layout, [lines(layout, "TopLeft", ["name"]), lines(layout, "TopRight", ["hospital"])])
        #expect(fitted.flatMap { texts($0) }.isEmpty)
    }
}
