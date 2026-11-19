//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import IsiXImaging

/// The large description of an image view as its box draws it: the lines that
/// identify the series in the large font, then the comments of the study and
/// of the series in a smaller one, broken to the width of the view.
enum LargeDescriptionText {
    /// The size of the font of the identification and of the comments, in points.
    static let identificationFontSize: CGFloat = 30, commentFontSize: CGFloat = 20
    /// What the box and the edges of the view take from the width left to a line of comment.
    static let sideMargin: CGFloat = 24

    static func attributed(patientName: String?, studyName: String?, seriesName: String?, date: String?,
                           openPatientNames: [String?], openStudyNames: [String?],
                           studyComment: String?, seriesComment: String?, width: CGFloat) -> NSAttributedString {
        let identification = DescriptionInLarge.text(patientName: patientName, studyName: studyName, seriesName: seriesName, date: date,
                                                     openPatientNames: openPatientNames, openStudyNames: openStudyNames)
        let identificationFont: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Helvetica-Bold", size: identificationFontSize) as Any]
        let commentFont: [NSAttributedString.Key: Any] =
            [.font: NSFont(name: "Helvetica", size: commentFontSize) ?? NSFont.systemFont(ofSize: commentFontSize)]
        let room = width - sideMargin
        let text = DescriptionInLarge.text(patientName: patientName, studyName: studyName, seriesName: seriesName, date: date,
                                           openPatientNames: openPatientNames, openStudyNames: openStudyNames,
                                           studyComment: studyComment, seriesComment: seriesComment,
                                           commentFits: { NSAttributedString(string: $0, attributes: commentFont).size().width <= room })
        let attributed = NSMutableAttributedString(string: text, attributes: identificationFont)
        // The comments are what the text has beyond the identification.
        let identified = (identification as NSString).length, whole = (text as NSString).length
        if whole > identified {
            attributed.setAttributes(commentFont, range: NSRange(location: identified, length: whole - identified))
        }
        return attributed
    }
}
