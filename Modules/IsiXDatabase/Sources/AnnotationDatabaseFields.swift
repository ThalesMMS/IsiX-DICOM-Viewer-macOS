/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, �version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. �See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. �If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: � OsiriX
 �Copyright (c) OsiriX Team
 �All rights reserved.
 �Distributed under GNU - LGPL
 �
 �See http://www.osirix-viewer.com/copyright.html for details.
 � � This software is distributed WITHOUT ANY WARRANTY; without even
 � � the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 � � PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

/// The database fields an image's custom annotations show: where each is read
/// from the image's row and the key it is kept under
/// (-[DCMPix loadCustomImageAnnotationsDBFields:]).
public enum AnnotationDatabaseFields {
    /// How a field of `level` is read from the image's row.
    public enum Lookup: Equatable {
        /// valueForKey: on the image.
        case key(String)
        /// valueForKeyPath: from the image, through its series (and study).
        case keyPath(String)
        /// A level that is none of image, series and study: no value.
        case none
    }

    /// Where `field` of `level` ("image", "series", "study") is read.
    public static func lookup(field: String?, level: String?) -> Lookup {
        switch level {
        case "image": return .key(field ?? "")
        case "series": return .keyPath("series." + text(field))
        case "study": return .keyPath("series.study." + text(field))
        default: return .none
        }
    }

    /// The key a field's value is kept under: its name, a space, its level.
    public static func key(field: String?, level: String?) -> String {
        text(field) + " " + text(level)
    }

    /// A value as %@ prints it: nil as "(null)".
    private static func text(_ value: String?) -> String { value ?? "(null)" }
}
