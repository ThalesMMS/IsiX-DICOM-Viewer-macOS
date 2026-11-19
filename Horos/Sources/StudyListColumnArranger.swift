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
import IsiXDatabase

/// Does to the columns of the study list the steps IsiXDatabase's
/// StudyListColumnSteps gives, in their order: which columns are shown and
/// where comes first and the widths last, and nothing is fitted to the view
/// afterwards. Why that order, and why the list is not asked to fit its last
/// column, is said there.
@MainActor enum StudyListColumnArranger {

    /// The columns of the list as the steps of a change need them.
    static func columns(of outline: NSOutlineView) -> [StudyListColumnSteps.Column] {
        outline.tableColumns.map {
            StudyListColumnSteps.Column(identifier: $0.identifier.rawValue, width: Double($0.width), isHidden: $0.isHidden)
        }
    }

    static func apply(_ steps: [StudyListColumnStep], to outline: NSOutlineView) {
        guard !steps.isEmpty else { return }
        for step in steps {
            switch step {
            case .hide(let identifier):
                guard let column = column(identifier, of: outline), !column.isHidden else { continue }
                column.isHidden = true
            case .show(let identifier):
                guard let column = column(identifier, of: outline), column.isHidden else { continue }
                column.isHidden = false
            case .move(let identifier, let position):
                let current = outline.column(withIdentifier: NSUserInterfaceItemIdentifier(identifier))
                guard current >= 0, current != position, position >= 0, position < outline.numberOfColumns else { continue }
                outline.moveColumn(current, toColumn: position)
            case .width(let identifier, let width):
                guard let column = column(identifier, of: outline) else { continue }
                let width = CGFloat(width)
                if column.width != width {
                    column.width = width
                }
            }
        }
        outline.needsDisplay = true
    }

    private static func column(_ identifier: String, of outline: NSOutlineView) -> NSTableColumn? {
        outline.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(identifier))
    }
}
