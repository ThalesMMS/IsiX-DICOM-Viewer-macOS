/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

/// The time the rebuild sheet announces: nine seconds per thousand files,
/// rounded down.
public enum RebuildEstimate {
    public static func seconds(forFileCount files: Int) -> Int {
        return files * 9 / 1000
    }
}

/// The comment "Regenerate Auto Comments" leaves on a study when comments are
/// filled at study level only: the text read from the study's first image
/// series replaces the study's comment when it is longer, and otherwise the
/// comment is cleared.
public enum AutoCommentRule {
    public static func studyComment(read candidate: String?, current: String?) -> String? {
        let candidateLength = (candidate as NSString?)?.length ?? 0
        let currentLength = (current as NSString?)?.length ?? 0
        return candidateLength > currentLength ? candidate : nil
    }
}

/// The lookups of an album made from a list of patients.
public enum PatientListLookup {
    /// The identifier as matched against Patient ID: without the spaces and
    /// line breaks around it; nil when nothing is left.
    public static func identifier(_ identifier: String?) -> String? {
        let trimmed = (identifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed as NSString).length > 0 ? trimmed : nil
    }

    /// The name search for the words of a listed name: every word anywhere in
    /// the stored name, in any order, which a leading `*` asks of the
    /// browser's name predicate. Nil without words.
    public static func nameQuery(words: [String]) -> String? {
        return words.isEmpty ? nil : "*" + words.joined(separator: " ")
    }
}

/// The series whose files make the surgical procedure timeline.
public enum SurgicalTimelineQuery {
    /// The series with exactly this description that belong to a study:
    /// those the timeline found by walking every study's series and comparing
    /// the description code unit by code unit (`==` in a fetch is that
    /// comparison, case and accents included). Every refresh of the study
    /// list asks for the timeline; one fetch of the series replaces fetching
    /// every study and faulting in all of their series.
    public static func seriesPredicate(description: String) -> NSPredicate {
        return NSPredicate(format: "seriesDescription == %@ AND study != nil", description)
    }
}
