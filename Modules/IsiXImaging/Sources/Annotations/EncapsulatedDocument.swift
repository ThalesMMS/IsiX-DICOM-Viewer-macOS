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

/// The DICOM objects DCMPix shows as a document rather than as pixel data
/// (-[DCMPix loadDICOMWithDCMTK]): an encapsulated PDF or CDA, a structured
/// report rendered to PDF, and an object of a class that is not an image.
public enum EncapsulatedDocument {
    public enum Kind: Equatable {
        /// Encapsulated PDF: a page of the document is the frame.
        case pdf
        /// Encapsulated CDA: nothing is drawn.
        case cda
        /// A structured report, drawn from the PDF made of its rendering.
        case structuredReport
        /// Anything else.
        case other
    }

    /// The SOP class prefix of the structured reports.
    public static let structuredReportPrefix = "1.2.840.10008.5.1.4.1.1.88"

    /// The kind of an object of `sopClassUID`, given the UIDs of the PDF and CDA storage classes.
    public static func kind(sopClassUID: String?, pdfStorage: String?, cdaStorage: String?) -> Kind {
        guard let sopClassUID else { return .other }
        if sopClassUID == pdfStorage { return .pdf }
        if sopClassUID == cdaStorage { return .cda }
        if sopClassUID.hasPrefix(structuredReportPrefix) { return .structuredReport }
        return .other
    }

    /// Where a structured report's rendering goes: the XML dsr2html writes and
    /// the PDF made of it, by the file's name, in `folder`.
    public static func renderings(of file: String, in folder: String) -> (xml: String, pdf: String) {
        let xml = (((folder as NSString).appendingPathComponent("dicomsr_osirix") as NSString)
            .appendingPathComponent((file as NSString).lastPathComponent) as NSString).appendingPathExtension("xml") ?? ""
        return (xml, (xml as NSString).appendingPathExtension("pdf") ?? "")
    }

    /// The side of the empty square shown for an object that is not an image.
    public static let emptyFrameSide = 128

    /// How long the PDF of a structured report may take to be made, in seconds.
    public static let renderingTimeout: TimeInterval = 10
}
