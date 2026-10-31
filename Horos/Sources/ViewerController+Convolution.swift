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

import AppKit

// The "convolution" block of ViewerController: the convolution filters of the
// 2D viewer, their menu, their editor and "apply on source". The work is the
// viewer's ViewerColourTables, with the stored filters and the editor's cells
// read through IsiXImaging's ConvolutionKernelBook and the filter applied to a
// whole series by its SeriesConvolution; these are the selectors of the former
// Objective-C methods, which the nibs, the menus and the former plugins send.

public extension ViewerController {

    // MARK: - convolution

    /// Applies the current filter to the pixels themselves and takes it off.
    @objc(applyConvolutionOnSource:)
    func applyConvolutionOnSource(_ sender: Any!) {
        sessionGraph.colourTables.applyFilterToPixels(in: self)
    }

    /// The "Sum" button of the filter editor.
    @objc(computeSum:)
    func computeSum(_ sender: Any!) {
        sessionGraph.colourTables.sumEditorWeights(in: self)
    }

    /// The size matrix of the filter editor: 3 × 3 or 5 × 5.
    @objc(changeMatrixSize:)
    func changeMatrixSize(_ sender: Any!) {
        sessionGraph.colourTables.editorSizeChanged(sender, in: self)
    }

    /// The end of the alert that asks before deleting a filter: `contextInfo`
    /// is the filter's name.
    @objc(deleteConv:returnCode:contextInfo:)
    func deleteConv(_ sheet: NSWindow!, returnCode: Int32, contextInfo: UnsafeMutableRawPointer!) {
        guard returnCode == 1, let contextInfo else { return }
        sessionGraph.colourTables.deleteFilter(Unmanaged<NSString>.fromOpaque(contextInfo).takeUnretainedValue() as String, in: self)
    }

    /// Hands the filter `m`, `s` × `s` weights divided by `norm`, to every
    /// slice; nil takes it off.
    @objc(setConv:::)
    func setConv(_ m: UnsafeMutablePointer<Float>!, _ s: Int16, _ norm: Float) {
        sessionGraph.colourTables.setFilter(m, size: s, normalization: norm, in: self)
    }

    /// Applies the filter `str`: "No Filter" or a stored filter.
    @objc(ApplyConvString:)
    func applyConvString(_ str: String!) {
        sessionGraph.colourTables.applyFilter(str, in: self)
    }

    /// A filter menu item: applies it; with Shift deletes it, with Option
    /// opens it in the filter editor.
    @objc(ApplyConv:)
    func applyConv(_ sender: Any!) {
        sessionGraph.colourTables.filterChosen(sender, in: self)
    }

    /// The weights of the filter editor for a filter of `size`, as numbers.
    @objc(getMatrix:)
    func getMatrix(_ size: Int16) -> NSMutableArray! {
        NSMutableArray(array: sessionGraph.colourTables.editorWeights(size: Int(size), in: self).map { NSNumber(value: $0) })
    }

    /// The end of the filter editor: OK stores its filter under its name.
    @objc(endConv:)
    func endConv(_ sender: Any!) {
        sessionGraph.colourTables.endFilterEditor(sender, in: self)
    }

    /// The filter editor changed: its filter is shown at once.
    @objc(convMatrixAction:)
    func convMatrixAction(_ sender: Any!) {
        sessionGraph.colourTables.editorChanged(in: self)
    }

    /// Opens the filter editor on a new filter.
    @objc(AddConv:)
    func addConv(_ sender: Any!) {
        sessionGraph.colourTables.addFilter(in: self)
    }
}
