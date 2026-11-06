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

/// What a Grayscale Softcopy Presentation State puts over the images of a 2D
/// viewer, in values: the presentation that belongs to an image and frame,
/// the shape each graphic annotation becomes, the magnification of its
/// displayed area and the lines that report what could not be applied. The
/// parsing of the file and the viewer's ROIs and views are the application's.
public enum PresentationStateOverlay {

    /// The shape a graphic annotation becomes in the viewer.
    public enum Shape: Equatable, Sendable {
        /// A text label named `name`, anchored at its first point when it has one.
        case text(name: String, anchor: CGPoint?)
        /// A point.
        case point(CGPoint)
        /// An ellipse in the rectangle given.
        case oval(CGRect)
        /// An open polyline through its points.
        case polyline([CGPoint])
    }

    /// The name of every shape but a text with its own.
    public static let shapeName = "GSPS"

    /// The shape of an annotation of graphic type `kind` (case ignored), with
    /// its text and its points in image pixels; nil for a type the viewer
    /// does not show, or one without the points it needs. A circle is its
    /// centre and a point of its rim; an ellipse the box of its points.
    public static func shape(kind: String, text: String?, points: [CGPoint]) -> Shape? {
        let kind = (kind as NSString).uppercased
        if same(kind, "TEXT") {
            let name = ((text as NSString?)?.length ?? 0) != 0 ? text ?? shapeName : shapeName
            return .text(name: name, anchor: points.first)
        }
        guard let first = points.first else { return nil }
        if same(kind, "POINT") {
            return .point(first)
        }
        if same(kind, "CIRCLE") || same(kind, "ELLIPSE") {
            var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
            var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
            if same(kind, "CIRCLE") && points.count >= 2 {
                let rim = points[1]
                let radius = hypot(rim.x - first.x, rim.y - first.y)
                minX = first.x - radius
                minY = first.y - radius
                maxX = first.x + radius
                maxY = first.y + radius
            } else {
                // Foundation's MIN and MAX, which treat a NaN as they always did.
                for point in points {
                    minX = minX < point.x ? minX : point.x
                    minY = minY < point.y ? minY : point.y
                    maxX = maxX < point.x ? point.x : maxX
                    maxY = maxY < point.y ? point.y : maxY
                }
            }
            return .oval(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
        }
        if same(kind, "POLYLINE") {
            return .polyline(points)
        }
        return nil
    }

    /// The frame numbers (from 1) a presentation of the image may name, in
    /// the order they are tried: the frame of the image in its file plus one,
    /// that frame (at least 1), and the frame its database record keeps (at
    /// least 1).
    public static func candidateFrames(frameInFile: Int32, recordedFrame: Int32) -> [Int] {
        [Int(frameInFile &+ 1), Int(max(1, frameInFile)), Int(max(1, recordedFrame))]
    }

    /// The index of the presentation of the image `sopInstanceUID` among
    /// `presentations` (their SOP Instance UID and frame), trying each of
    /// `frames` in turn; nil when none matches. UIDs are compared exactly.
    public static func presentationIndex(sopInstanceUID: String, frames: [Int],
                                         in presentations: [(sopInstanceUID: String, frameNumber: Int)]) -> Int? {
        for frame in frames {
            if let index = presentations.firstIndex(where: { same($0.sopInstanceUID, sopInstanceUID) && $0.frameNumber == frame }) {
                return index
            }
        }
        return nil
    }

    /// The scale a displayed area sets: its magnification in MAGNIFY mode
    /// when it is positive, nil otherwise.
    public static func magnification(sizeMode: String, magnification: Double) -> Double? {
        same(sizeMode, "MAGNIFY") && magnification > 0 ? magnification : nil
    }

    /// The frames of a missing reference as the log names them: joined by
    /// commas, or "all" when it names none.
    public static func framesDescription(_ frames: [Int]) -> String {
        frames.isEmpty ? "all" : frames.map(String.init).joined(separator: ",")
    }

    /// An exact UTF-16 comparison, as -isEqualToString: compares.
    private static func same(_ a: String, _ b: String) -> Bool {
        (a as NSString).isEqual(to: b)
    }
}
