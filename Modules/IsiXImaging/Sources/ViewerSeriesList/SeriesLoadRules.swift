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

/// The rules of a 2D viewer's series load and of the change of the series it
/// shows, without the viewer: how many decoders a compressed series gets, the
/// share decoded, where a new series of the same study opens, whether only key
/// images are listed, the tables a series opens with, the tiling a study saved
/// for its series, the screen a new viewer opens on and the resampling of
/// small images.
public enum SeriesLoadRules {

    // MARK: - Decoding

    /// The decoders of a compressed series on `processors` processors: one
    /// processor is left to the rest of the application above four.
    public static func compressedDecoders(processors: Int) -> Int {
        processors > 4 ? processors - 1 : max(1, processors)
    }

    /// The share of `total` slices that `decoded` are; a series of no slice is
    /// entirely decoded.
    public static func decodedShare(decoded: Int, of total: Int) -> Float {
        total != 0 ? Float(decoded) / Float(total) : 1
    }

    // MARK: - Changing the series shown

    /// Whether two image orientations (the six direction cosines and the
    /// normal) are equal, and whether the new one is set at all (a vector of
    /// zeros means none).
    public static func compareOrientations(_ previous: [Float], _ new: [Float]) -> (equal: Bool, newIsSet: Bool) {
        var equal = true, set = false
        for index in 0..<min(previous.count, new.count) {
            if previous[index] != new[index] { equal = false }
            if new[index] != 0 { set = true }
        }
        return (equal, set)
    }

    /// The slice a new series of the same study opens on, to stay where the
    /// operator was (`location`, in mm): the slice nearest to it, the first of
    /// equally near ones, when it lies between the locations of the first and
    /// the last slices. Nil when it does not, or when the nearest is the first
    /// slice, which the viewer shows anyway.
    public static func nearestSlice(to location: Float, sliceLocations: [Float]) -> Int? {
        guard var start = sliceLocations.first, var end = sliceLocations.last else { return nil }
        if start > end { swap(&start, &end) }
        guard location >= start && location <= end else { return nil }
        var index = 0
        var smallest: Float = -1
        for (candidate, slice) in sliceLocations.enumerated() {
            let difference = abs(slice - location)
            if difference < smallest || smallest == -1 {
                smallest = difference
                index = candidate
            }
        }
        return index != 0 ? index : nil
    }

    /// `index` in a list of `count` images shown upside down (a flipped series).
    public static func flippedIndex(_ index: Int, count: Int) -> Int {
        count &- 1 &- index
    }

    /// Whether a list of images shows only the key images of its series: it
    /// lists fewer or more images than the series has (`seriesCount`), was not
    /// made by post-processing, and every one is a key image.
    public static func showsOnlyKeyImages(listed: [Bool], seriesCount: Int, postprocessed: Bool) -> Bool {
        guard listed.count != seriesCount && !postprocessed else { return false }
        return listed.allSatisfy { $0 }
    }

    // MARK: - Tables a series opens with

    /// A table applied when a series opens: the one of no colour (No CLUT) or
    /// the linear opacity table, or one by its stored name.
    public enum OpeningTable: Equatable, Sendable {
        case plain
        case named(String?)
    }

    /// The colour table a series of `modality` opens with: PET and, when the
    /// preference says so, NM take the inverted grey ramp or the PET default;
    /// the others and RGB images, none.
    public static func colourTable(modality: String?, isRGB: Bool, nmAsPET: Bool, petMode: String?, petDefault: String?) -> OpeningTable {
        guard !isRGB, modality == "PT" || (nmAsPET && modality == "NM") else { return .plain }
        return petMode == "B/W Inverse" ? .named("B/W Inverse") : .named(petDefault)
    }

    /// The opacity table a series of `modality` opens with: PET and, when the
    /// preference says so, NM take the PET default when its preference is on;
    /// the others and RGB images, the linear table.
    public static func opacityTable(modality: String?, isRGB: Bool, nmAsPET: Bool, petOpacity: Bool, petDefault: String?) -> OpeningTable {
        guard !isRGB, modality == "PT" || (nmAsPET && modality == "NM"), petOpacity else { return .plain }
        return .named(petDefault)
    }

    /// Whether a series of `modality` opens on the 12-bit display: the
    /// projection radiography modalities, grey images, when asked for and the
    /// display can show it.
    public static func opensTwelveBit(modality: String?, isRGB: Bool, automatic: Bool, displayCanShow: () -> Bool) -> Bool {
        guard !isRGB, let modality, ["CR", "DR", "DX", "MG", "XA", "RF"].contains(modality), automatic else { return false }
        return displayCanShow()
    }

    // MARK: - Saved tiling

    /// The rows and columns a study's saved windows state gives the series
    /// `seriesUID` of study `studyUID`: the last of its viewers that showed it.
    /// A count is a number or a string, read as an integer.
    public static func savedTiling(in viewers: [Any], studyUID: String?, seriesUID: String?) -> (rows: Int32, columns: Int32)? {
        var found: (rows: Int32, columns: Int32)?
        for case let viewer as [String: Any] in viewers {
            guard sameText(viewer["studyInstanceUID"], studyUID), sameText(viewer["seriesInstanceUID"], seriesUID) else { continue }
            found = (integer(viewer["rows"]), integer(viewer["columns"]))
        }
        return found
    }

    // MARK: - Opening a viewer

    /// The screen, by its index among `screenCount`, a new viewer opens on
    /// for the MULTIPLESCREENS preference: the second for 1 (the only one when
    /// there is one), the first otherwise.
    public static func openingScreen(multipleScreens: Int, screenCount: Int) -> Int {
        multipleScreens == 1 && screenCount > 1 ? 1 : 0
    }

    /// The factor a series of `width` × `height` pixels is resampled by when
    /// it opens: when the smaller side is at most `smallerOrEqual`, the ratio
    /// of it to `destination`; nil when it is larger or the ratio is not positive.
    public static func resampleRatio(width: Int32, height: Int32, smallerOrEqual: Int32, destination: Float) -> Float? {
        guard width <= smallerOrEqual || height <= smallerOrEqual else { return nil }
        let ratio = width < height ? Float(width) / destination : Float(height) / destination
        return ratio > 0 ? ratio : nil
    }

    // MARK: - Values as Objective-C read them

    /// `[a isEqualToString: b]`: false when either is not a string.
    private static func sameText(_ a: Any?, _ b: String?) -> Bool {
        guard let a = a as? String, let b else { return false }
        return (a as NSString).isEqual(to: b)
    }

    /// `[value intValue]` of a number or a string, 0 otherwise.
    private static func integer(_ value: Any?) -> Int32 {
        if let number = value as? NSNumber { return number.int32Value }
        if let string = value as? String { return (string as NSString).intValue }
        return 0
    }
}
