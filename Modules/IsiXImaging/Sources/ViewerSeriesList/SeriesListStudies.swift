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

// The studies of the 2D viewer's series list and series menu: which of a
// patient's studies they show, the number and colour of each study, the
// lines of its title, and the state of the comparatives button.

/// The studies the list shows, out of the patient's studies in their order.
public struct SeriesListStudySelection: Equatable {
    /// The indexes of the studies shown.
    public var shown: [Int]
    /// Some study is a comparative not loaded (only on a PACS).
    public var hasComparatives: Bool
    /// Such a comparative is more recent than the first loaded study.
    public var hasComparativesNewerThanLoaded: Bool

    public init(shown: [Int], hasComparatives: Bool, hasComparativesNewerThanLoaded: Bool) {
        self.shown = shown
        self.hasComparatives = hasComparatives
        self.hasComparativesNewerThanLoaded = hasComparativesNewerThanLoaded
    }

    /// A comparative not loaded shows when it has local series or when the
    /// list shows the PACS comparatives (`listsComparatives`, read only
    /// when needed); the studies come most recent first.
    public static func select(notLoaded: [Bool], seriesCounts: [Int], listsComparatives: () -> Bool) -> SeriesListStudySelection {
        var selection = SeriesListStudySelection(shown: [], hasComparatives: false, hasComparativesNewerThanLoaded: false)
        var iteratedFirstLoaded = false
        for index in notLoaded.indices {
            let isNonLoadedComparative = notLoaded[index]
            if !isNonLoadedComparative || seriesCounts[index] != 0 || listsComparatives() {
                selection.shown.append(index)
            }
            if isNonLoadedComparative {
                selection.hasComparatives = true
                if !iteratedFirstLoaded { selection.hasComparativesNewerThanLoaded = true }
            } else {
                iteratedFirstLoaded = true
            }
        }
        return selection
    }
}

public enum SeriesListStudyNumbers {
    /// The colour of the study at `index` among the patient's studies: its
    /// own, or the last one past the end (nil without colours). `index` may
    /// be NSNotFound.
    public static func colorIndex(studyIndex index: Int, colorCount: Int) -> Int? {
        if colorCount == 0 { return nil }
        // The index is unsigned in the comparison: NSNotFound is past the end.
        return UInt(bitPattern: index) >= UInt(colorCount) ? colorCount - 1 : index
    }

    /// The number written on the study, `(int) index + 1`.
    public static func number(studyIndex index: Int) -> Int32 {
        Int32(truncatingIfNeeded: index) &+ 1
    }

    /// The state of the study: its index in the list of states, nil for none
    /// (0) or one out of the list. The stored value is an int read as
    /// unsigned.
    public static func stateIndex(_ stored: Int32, stateCount: Int) -> Int? {
        let index = UInt(bitPattern: Int(stored))
        return index != 0 && index < UInt(stateCount) ? Int(index) : nil
    }
}

public enum SeriesListTitles {
    /// The patient line of another patient's study: the name and the birth
    /// date (formatted only when both exist), empty for the viewer's own
    /// patient or when the annotations hide the name.
    public static func patientLine(name: String?, hasDateOfBirth: Bool, formattedDateOfBirth: () -> String?, separator: String,
                                   isViewerPatient: (String) -> Bool, showsPatientName: Bool) -> String {
        var line = ""
        if let name, hasDateOfBirth {
            line = name + separator + (formattedDateOfBirth() ?? "(null)")
        }
        if let name, isViewerPatient(name) { line = "" }
        if !showsPatientName { line = "" }
        return line
    }

    /// The parts of a title that are not empty, in order.
    static func present(_ parts: [String?]) -> [String] {
        parts.compactMap { part in
            guard let part, !part.isEmpty else { return nil }
            return part
        }
    }

    /// The series menu's line of a study: the date when the study has one,
    /// then patient, name, modality and comment when not empty.
    public static func menuTitle(date: String?, patient: String, name: String?, modality: String, comment: String?) -> String {
        ((date.map { [$0] } ?? []) + present([patient, name, modality, comment])).joined(separator: " / ")
    }

    /// The lines of a study's cell in the list: its number, a blank line,
    /// patient and name when not empty, the date when it has one, modality
    /// and number of series, state, comment and the action of a click when
    /// not empty. The number is the first line.
    public static func cellLines(number: String, patient: String, name: String?, date: String?, modalityAndSeries: String,
                                 state: String, comment: String, action: String?) -> [String] {
        var lines = [number, ""]
        lines += present([patient, name])
        if let date { lines.append(date) }
        lines.append(modalityAndSeries)
        lines += present([state, comment])
        if let action, !action.isEmpty { lines.append("\r" + action) }
        return lines
    }

    /// The lines of a comparative on a PACS: patient and name when not empty,
    /// the date when it has one, the modality when not empty.
    public static func comparativeCellLines(patient: String, name: String?, date: String?, modality: String) -> [String] {
        present([patient, name]) + (date.map { [$0] } ?? []) + present([modality])
    }
}

/// The comparatives button under the list.
public struct SeriesListComparativesButton: Equatable {
    public enum Tint: Equatable {
        case plain
        /// There are PACS comparatives.
        case available
        /// There are PACS comparatives more recent than the loaded studies.
        case newer
    }

    public enum Hint: Equatable {
        case available
        case newer
    }

    /// The title has a check mark: the list shows the comparatives.
    public var checked: Bool
    public var tint: Tint
    /// What the tool tip says first, if anything.
    public var hint: Hint?
    /// The tool tip then says a click shows (false) or hides (true) them;
    /// nil when there are none.
    public var clickHides: Bool?

    public init(checked: Bool, tint: Tint, hint: Hint?, clickHides: Bool?) {
        self.checked = checked
        self.tint = tint
        self.hint = hint
        self.clickHides = clickHides
    }

    public static func state(hasComparatives: Bool, newerThanLoaded: Bool, listsComparatives: Bool) -> SeriesListComparativesButton {
        var button = SeriesListComparativesButton(checked: listsComparatives, tint: .plain, hint: nil, clickHides: nil)
        if !listsComparatives {
            if hasComparatives { button.tint = .available; button.hint = .available }
            if newerThanLoaded { button.tint = .newer; button.hint = .newer }
        }
        if hasComparatives { button.clickHides = listsComparatives }
        return button
    }
}
