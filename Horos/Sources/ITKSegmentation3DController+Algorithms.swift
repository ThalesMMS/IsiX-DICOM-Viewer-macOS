/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Cocoa
import IsiXSegmentation

// The algorithms of the region growing window: the popup that chooses one
// (bound to the growingRegionAlgorithm preference), the parameter fields it
// takes (each bound to its preference), the layout of the window around them
// and the ITK documentation of each.
extension ITKSegmentation3DController {

    /// The titles of the algorithms, in the order of their tags.
    static var algorithmTitles: [String] {
        [NSLocalizedString("Threshold (interval)", comment: ""),
         NSLocalizedString("Threshold (lower/upper bounds)", comment: ""),
         NSLocalizedString("Neighborhood", comment: ""),
         NSLocalizedString("Confidence", comment: "")]
    }

    /// The titles of each algorithm's parameter fields.
    static func parameterTitles(_ algorithm: RegionGrowingAlgorithm) -> [String] {
        switch algorithm {
        case .interval:
            return [NSLocalizedString("Interval", comment: "")]
        case .threshold:
            return [NSLocalizedString("Lower Threshold", comment: ""), NSLocalizedString("Upper Threshold", comment: "")]
        case .neighborhood:
            return [NSLocalizedString("Lower Threshold", comment: ""), NSLocalizedString("Upper Threshold", comment: ""),
                    NSLocalizedString("Radius (pix.)", comment: "")]
        case .confidence:
            return [NSLocalizedString("Multiplier", comment: ""), NSLocalizedString("Num. of Iterations", comment: ""),
                    NSLocalizedString("Initial Radius (pix.)", comment: "")]
        }
    }

    /// The algorithm of the popup's selected item: its tag, as an index of the
    /// algorithms (an unknown tag is the range exception of the former array).
    var selectedAlgorithm: RegionGrowingAlgorithm {
        let tag = algorithmPopup?.selectedItem?.tag ?? 0
        guard let algorithm = RegionGrowingAlgorithm(rawValue: tag) else {
            NSException(name: .rangeException, reason: "*** -[__NSArrayI objectAtIndex:]: index \(tag) beyond bounds [0 .. 3]",
                        userInfo: nil).raise()
            return .interval
        }
        return algorithm
    }

    /// Fills the popup with the algorithms, tagged by their index, and binds
    /// its selection to the preference.
    @objc(fillAlgorithmPopup)
    func fillAlgorithmPopup() {
        let items = NSMenu(title: "")

        for (i, title) in Self.algorithmTitles.enumerated() {
            let item = NSMenuItem()
            item.title = title
            item.tag = i
            items.addItem(item)
        }
        algorithmPopup?.removeAllItems()
        algorithmPopup?.menu = items
        algorithmPopup?.bind(NSBindingName("selectedIndex"), to: NSUserDefaultsController.shared,
                             withKeyPath: "values.growingRegionAlgorithm", options: nil)
    }

    /// Shows the parameter fields of the chosen algorithm, bound to their
    /// preferences, then previews.
    @IBAction @objc(changeAlgorithm:)
    func changeAlgorithm(_ sender: Any!) {
        let algorithm = selectedAlgorithm
        setNumberOfParameters(Int32(algorithm.parameterCount))

        let titles = Self.parameterTitles(algorithm)
        let defaultValues = algorithm.defaultValues
        for (row, key) in algorithm.parameterDefaultsKeys.enumerated() {
            let cell = params?.cell(atRow: row, column: 0)

            cell?.title = titles[row]
            cell?.stringValue = defaultValues[row]
            cell?.bind(.value, to: NSUserDefaultsController.shared, withKeyPath: "values." + key, options: nil)
        }

        preview(self)
    }

    /// Makes the form `n` fields high, and, in a window laid out without
    /// constraints (the nibs before auto layout), the boxes, the button and
    /// the window around it.
    @objc(setNumberOfParameters:)
    func setNumberOfParameters(_ n: Int32) {
        guard let params else { return }
        params.translatesAutoresizingMaskIntoConstraints = true

        let frameBefore = params.frame
        // change the number of field in the matrix
        while params.numberOfRows != 0 {
            params.removeRow(0)
        }
        while params.numberOfRows != Int(n) {
            params.addRow()
        }
        // adjust the size of the matrix
        params.sizeToCells()
        var frameAfter = params.frame
        let deltaY = Float(frameBefore.size.height - frameAfter.size.height)
        frameAfter.origin.y = frameBefore.origin.y + CGFloat(deltaY)
        params.frame = frameAfter

        if (window?.contentView?.constraints.count ?? 0) == 0 { // backward compatibility : prior auto-layout xib
            guard let parametersBox, let resultsBox, let computeButton, let window else { return }

            // adjust the size of the parameters box
            let parametersBoxFrameBefore = parametersBox.frame
            parametersBox.contentViewMargins = NSSize(width: 4, height: 12)
            parametersBox.sizeToFit()
            parametersBox.frame = NSRect(x: parametersBoxFrameBefore.origin.x, y: parametersBox.frame.origin.y,
                                         width: parametersBoxFrameBefore.size.width, height: parametersBox.frame.size.height)

            // frames
            var parametersBoxFrame = parametersBox.frame
            var resultsBoxFrame = resultsBox.frame
            var computeButtonFrame = computeButton.frame

            // adjust the size & position of the window
            var windowFrame = window.frame
            let newWindowHeight = Float(parametersBoxFrame.size.height + resultsBoxFrame.size.height + computeButtonFrame.size.height + 20 + 15)
            let deltaHeight = newWindowHeight - Float(windowFrame.size.height)
            windowFrame.origin.y -= CGFloat(deltaHeight)
            windowFrame.size.height = CGFloat(newWindowHeight)
            window.setFrame(windowFrame, display: false)

            // adjust the position of the parameters box
            parametersBoxFrame.origin.y = windowFrame.size.height - parametersBoxFrame.size.height - 20
            parametersBox.frame = parametersBoxFrame

            // adjust the position of the results box and the compute button
            resultsBoxFrame.origin.y = parametersBoxFrame.origin.y - resultsBoxFrame.size.height - 5
            resultsBox.frame = resultsBoxFrame
            computeButtonFrame.origin.y = resultsBoxFrame.origin.y - computeButtonFrame.size.height - 5
            computeButton.frame = computeButtonFrame

            window.display()
        }
    }

    /// Opens the ITK documentation of the chosen algorithm.
    @IBAction @objc(algorithmGetHelp:)
    func algorithmGetHelp(_ sender: Any!) {
        if let url = URL(string: selectedAlgorithm.helpURL) {
            NSWorkspace.shared.open(url)
        }
    }
}
