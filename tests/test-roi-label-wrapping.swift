//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit

@main struct Test {
    static func main() {
        let font = NSFont(name: "Geneva", size: 12)!
        let text = "Mean: 123.456 HU SDev: 78.900 HU Sum: 123456789 Median: 123.456 HU"
        for width: CGFloat in [48, 100, 200, 400] {
            let lines = ROILabelPresentation.wrapLines([text], font: font, maximumWidth: width)
            precondition(lines.joined() == text)
            precondition(lines.allSatisfy { ($0 as NSString).size(withAttributes: [.font: font]).width <= width })
            precondition(lines == ROILabelPresentation.wrapLines([text], font: font, maximumWidth: width))
        }
        let unicode = String(repeating: "é👩🏽‍⚕️測", count: 200)
        let chunks = ROILabelPresentation.wrapLines([unicode], font: font, maximumWidth: 100)
        precondition(chunks.joined() == unicode)
        precondition(chunks.allSatisfy { $0.utf16.count <= 300 })
        precondition(ROILabelPresentation.wrapLines(["Length: 2.000 cm"], font: font, maximumWidth: 400) == ["Length: 2.000 cm"])
        precondition(ROILabelPresentation.wrapLines([text], font: font, maximumWidth: 0) == [text])
        let large = NSFont(name: "Geneva", size: 30)!
        let smallLines = ROILabelPresentation.wrapLines([text], font: font, maximumWidth: 100)
        let largeLines = ROILabelPresentation.wrapLines([text], font: large, maximumWidth: 100)
        precondition(largeLines.count > smallLines.count)
        print("PASS: wrapping width, full text, Unicode clusters, font changes, cache reuse and unwrapped short labels")
    }
}
