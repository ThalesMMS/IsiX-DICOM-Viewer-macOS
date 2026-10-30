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

/// The tag dictionaries the host's DCMTK adapter gives IsiXDICOMFile by this
/// name, reduced to the attributes these tests name.
@objc(HorosDICOMDictionaries)
final class TestDictionaries: NSObject {
    private static let entries: [(String, String, String)] = [
        ("0002,0000", "MetaElementGroupLength", "UL"), ("0002,0001", "FileMetaInformationVersion", "OB"),
        ("0002,0002", "MediaStorageSOPClassUID", "UI"), ("0002,0003", "MediaStorageSOPInstanceUID", "UI"),
        ("0002,0010", "TransferSyntaxUID", "UI"), ("0002,0012", "ImplementationClassUID", "UI"),
        ("0002,0013", "ImplementationVersionName", "SH"), ("0002,0016", "SourceApplicationEntityTitle", "AE"),
        ("0008,0016", "SOPClassUID", "UI"), ("0008,0018", "SOPInstanceUID", "UI"),
        ("0008,0060", "Modality", "CS"), ("0020,000D", "StudyInstanceUID", "UI"),
        ("0020,000E", "SeriesInstanceUID", "UI"), ("0028,0002", "SamplesperPixel", "US"),
        ("0028,0004", "PhotometricInterpretation", "CS"), ("0028,0010", "Rows", "US"),
        ("0028,0011", "Columns", "US"), ("0028,0100", "BitsAllocated", "US"), ("0028,0101", "BitsStored", "US"),
        ("0028,1101", "RedPaletteColorLookupTableDescriptor", "US"),
        ("0028,1102", "GreenPaletteColorLookupTableDescriptor", "US"),
        ("0028,1103", "BluePaletteColorLookupTableDescriptor", "US"),
        ("0028,1201", "RedPaletteColorLookupTableData", "OW"),
        ("0028,1202", "GreenPaletteColorLookupTableData", "OW"),
        ("0028,1203", "BluePaletteColorLookupTableData", "OW"),
        ("0042,0012", "MIMETypeOfEncapsulatedDocument", "LO"), ("7FE0,0010", "PixelData", "OW"),
    ]

    @objc static func tagDictionary() -> NSDictionary {
        var tags: [String: Any] = [:]
        for (key, name, vr) in entries {
            tags[key] = ["Description": name, "VR": vr, "VM": "1"]
        }
        return tags as NSDictionary
    }

    @objc static func tagForNameDictionary() -> NSDictionary {
        var names: [String: String] = [:]
        for (key, name, _) in entries {
            names[name] = key
        }
        return names as NSDictionary
    }
}
