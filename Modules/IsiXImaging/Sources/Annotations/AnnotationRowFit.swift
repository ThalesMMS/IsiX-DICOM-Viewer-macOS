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

/// The room the lines of the two sides of an image view have in their row.
///
/// The layout stacks the lines of each corner from its own edge and aligns
/// them on it: a left line and a right line of one row grow towards each other
/// and, in a view too narrow for both, were drawn one over the other. Here
/// each keeps to its room, and a line longer than its room is cut at its end,
/// where «…» says so.
///
/// Two lines are of one row when their rasters are no more than half a line
/// apart. The lines of the top corners start at the same raster and so do
/// those of the middles; the lower right lines start a line above the lower
/// left ones, where the signature stands, so each is paired with the lower
/// left line of its own height and the signature with the lowest one.
///
/// - A row with a line on each side: when both and the gap between them fit
///   between their edges, nothing changes. When they do not, the side that
///   needs no more than half of that room stays whole and the other takes the
///   rest; when both need more than half, each has half.
/// - A row with one line: it may reach the edge the other side starts from,
///   and no further.
/// - What stands in the middle of a row keeps its place and its text: the
///   orientation letters, the notices under the top one and the lines of the
///   middle positions are never cut, and a side line ends, or starts, a gap
///   away from them. A row they stand in is two rows of one line each.
/// - The lines a plugin draws at a raster of its own are not known here and
///   take no room.
///
/// The widths are those of `width`, in the units of the commands (the view's
/// backing pixels). A line whose room does not hold «…» is not drawn.
public enum AnnotationRowFit {
    public typealias Command = AnnotationOverlayLayout.Command

    /// What ends a line that was cut.
    public static let ellipsis = "…"

    /// The widths the left and the right line of a row take, of the `row`
    /// between their edges, with `gap` kept between them.
    public static func widths(left: Double, right: Double, row: Double, gap: Double) -> (left: Double, right: Double) {
        let room = max(row - gap, 0)
        if left + right <= room { return (left, right) }
        let half = room / 2
        if left <= half { return (left, room - left) }
        if right <= half { return (room - right, right) }
        return (half, half)
    }

    /// `text` as it is when `room` holds it; else its longest beginning that
    /// `room` holds with «…» after it, without the spaces before the «…»; and
    /// nothing when `room` does not hold «…» itself. `width` measures a text.
    public static func cut(_ text: String, to room: Double, width: (String) -> Double) -> String {
        if width(text) <= room { return text }
        if width(ellipsis) > room { return "" }
        let characters = Array(text)
        func beginning(_ count: Int) -> String {
            var end = count
            while end > 0, characters[end - 1].isWhitespace { end -= 1 }
            return String(characters[..<end]) + ellipsis
        }
        // `kept` characters and «…» fit; no more than `most` can.
        var kept = 0, most = characters.count - 1
        while kept < most {
            let middle = (kept + most + 1) / 2
            if width(beginning(middle)) <= room { kept = middle } else { most = middle - 1 }
        }
        return beginning(kept)
    }

    private struct Kept {
        let minX: Double, maxX: Double, y: Double
    }

    private struct Line {
        let group: Int, index: Int
        let text: String
        let x: Double, y: Double, width: Double
        let right: Bool
    }

    /// The commands of `groups`, each group the lines of a position, with the
    /// side lines that have no room in their row cut to it; the same groups
    /// when every line has its room. `fixed` are the texts that keep their
    /// place beside those of the groups that are centred: the orientation
    /// letters and the notices. `bounds` are the edges the left lines start
    /// from and the right lines end at; `lineHeight` is the distance between
    /// two lines of a corner. `cut` gives a text cut to a room, as `cut(_:to:width:)` does.
    /// `widestCharacter` is the most a UTF-16 unit of a text may take, 0 when it is not known: where the lines
    /// have their room even at that width, none is measured.
    public static func fit(_ groups: [[Command]], fixed: [Command] = [], bounds: ClosedRange<Double>, lineHeight: Double, gap: Double,
                           widestCharacter: Double = 0, width: (String) -> Double, cut: (String, Double) -> String) -> [[Command]] {
        // A pass over the lines, which is the whole work of a view wide enough: where the left lines start and
        // end at the most, where the right ones do, and what keeps its place (where it starts, where it ends,
        // its raster). When the longest left line ends a gap before the longest right one starts, inside the
        // edges, and nothing that keeps its place stands in what either side takes, no line of any row lacks
        // room. `wide` says how wide a text is; nil when there is no side line at all.
        func roomy(_ wide: (String) -> Double) -> (roomy: Bool, lines: Int, kept: [Kept])? {
            var kept: [Kept] = []
            func keep(_ text: String, _ x: Int, _ y: Int, _ alignment: AnnotationOverlayLayout.TextAlignment) {
                if text.isEmpty { return }
                let wide = wide(text), x = Double(x)
                switch alignment {
                case .left: kept.append(Kept(minX: x, maxX: x + wide, y: Double(y)))
                case .center: kept.append(Kept(minX: x - wide / 2, maxX: x + wide / 2, y: Double(y)))
                case .right: kept.append(Kept(minX: x - wide, maxX: x, y: Double(y)))
                }
            }
            var count = 0
            var leftStart = Double.infinity, leftEnd = -Double.infinity, rightStart = Double.infinity, rightEnd = -Double.infinity
            for commands in groups {
                for command in commands {
                    guard case let .text(text, x, y, alignment) = command, !text.isEmpty else { continue }
                    switch alignment {
                    case .center:
                        keep(text, x, y, alignment)
                    case .left:
                        count += 1
                        leftStart = min(leftStart, Double(x))
                        leftEnd = max(leftEnd, Double(x) + wide(text))
                    case .right:
                        count += 1
                        rightEnd = max(rightEnd, Double(x))
                        rightStart = min(rightStart, Double(x) - wide(text))
                    }
                }
            }
            if count == 0 { return nil }
            for case let .text(text, x, y, alignment) in fixed {
                keep(text, x, y, alignment)
            }
            var roomy = leftEnd + gap <= rightStart && leftEnd <= bounds.upperBound && rightStart >= bounds.lowerBound
            if roomy {
                for other in kept where !((other.minX >= leftEnd + gap || other.minX <= leftStart)
                                          && (other.maxX <= rightStart - gap || other.maxX >= rightEnd)) {
                    roomy = false
                    break
                }
            }
            return (roomy, count, kept)
        }
        // First with what the texts take at the most, which asks for no measure: in a view wide enough for
        // that, nothing is measured at all.
        if widestCharacter > 0, roomy({ Double($0.utf16.count) * widestCharacter })?.roomy ?? true { return groups }
        guard let measured = roomy(width), !measured.roomy else { return groups }
        let kept = measured.kept, count = measured.lines

        var lines: [Line] = []
        lines.reserveCapacity(count)
        for (group, commands) in groups.enumerated() {
            for (index, command) in commands.enumerated() {
                guard case let .text(text, x, y, alignment) = command, !text.isEmpty, alignment != .center else { continue }
                lines.append(Line(group: group, index: index, text: text, x: Double(x), y: Double(y), width: width(text),
                                  right: alignment == .right))
            }
        }

        func sameRow(_ a: Double, _ b: Double) -> Bool { abs(a - b) * 2 <= lineHeight }
        var fitted: [[Command]]?
        for line in lines {
            // How far the line may go: to the other edge, or to what stands in its way.
            var limit = line.right ? bounds.lowerBound : bounds.upperBound
            for other in kept where sameRow(other.y, line.y) {
                if line.right {
                    if other.maxX < line.x { limit = max(limit, other.maxX + gap) }
                } else if other.minX > line.x {
                    limit = min(limit, other.minX - gap)
                }
            }
            var room = max(line.right ? line.x - limit : limit - line.x, 0)
            // The line of the other side, when nothing stands between the two.
            if let facing = lines.first(where: { $0.right != line.right && sameRow($0.y, line.y)
                                                 && (line.right ? $0.x < line.x && $0.x >= limit : $0.x > line.x && $0.x <= limit) }) {
                let shared = line.right ? widths(left: facing.width, right: line.width, row: line.x - facing.x, gap: gap).right
                                        : widths(left: line.width, right: facing.width, row: facing.x - line.x, gap: gap).left
                room = min(room, shared)
            }
            if line.width <= room { continue }
            if fitted == nil { fitted = groups }
            if case let .text(_, x, y, alignment) = groups[line.group][line.index] {
                fitted?[line.group][line.index] = .text(cut(line.text, room), x: x, y: y, alignment: alignment)
            }
        }
        guard var fitted else { return groups }
        // A line with no room for «…» is not drawn.
        for group in fitted.indices {
            fitted[group].removeAll { command in
                if case let .text(text, _, _, _) = command { return text.isEmpty }
                return false
            }
        }
        return fitted
    }
}
