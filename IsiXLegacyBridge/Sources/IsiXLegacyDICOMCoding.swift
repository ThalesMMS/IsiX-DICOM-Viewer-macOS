//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The DICOM encoding behind the kit's DCMObject: a dictionary of the
// attributes plugins name, and the reading and writing of datasets in
// uncompressed little endian, explicit or implicit VR (PS3.5, 7.1 and
// PS3.10, 7.1). The application's own DICOM libraries are not reachable from
// a plugin; this is all a legacy plugin's DCMObject needs to read a file of
// the database or write one to add to it.

import Foundation

/// One data element, in the terms the kit's Objective-C DCMAttribute keeps:
/// strings, NSNumber, Data, or DCMCalendarDate values (given back as their
/// DICOM text by the Objective-C side before writing).
@objc final class IsiXLegacyDICOMElement: NSObject {
    @objc let tag: UInt32
    @objc let vr: String
    @objc let values: [Any]

    @objc init(tag: UInt32, vr: String, values: [Any]) {
        self.tag = tag
        self.vr = vr
        self.values = values
    }
}

/// What reading a file gives: the transfer syntax and the elements, meta
/// information included.
@objc final class IsiXLegacyDICOMDataset: NSObject {
    @objc let transferSyntax: String
    @objc let elements: [IsiXLegacyDICOMElement]

    init(transferSyntax: String, elements: [IsiXLegacyDICOMElement]) {
        self.transferSyntax = transferSyntax
        self.elements = elements
    }
}

@objc final class IsiXLegacyDICOMCoder: NSObject {
    static let implicitLittleEndian = "1.2.840.10008.1.2"
    static let explicitLittleEndian = "1.2.840.10008.1.2.1"
    static let explicitBigEndian = "1.2.840.10008.1.2.2"
    static let deflatedExplicitLittleEndian = "1.2.840.10008.1.2.1.99"
    /// The implementation the files the kit writes name.
    static let implementationClassUID = "2.25.98260317411934532779413069128410613277"

    // MARK: dictionary

    /// Keyword, tag and VR of the attributes the kit knows by name.
    private static let entries: [(String, UInt32, String)] = [
        ("FileMetaInformationGroupLength", 0x0002_0000, "UL"), ("FileMetaInformationVersion", 0x0002_0001, "OB"),
        ("MediaStorageSOPClassUID", 0x0002_0002, "UI"), ("MediaStorageSOPInstanceUID", 0x0002_0003, "UI"),
        ("TransferSyntaxUID", 0x0002_0010, "UI"), ("ImplementationClassUID", 0x0002_0012, "UI"),
        ("ImplementationVersionName", 0x0002_0013, "SH"), ("SourceApplicationEntityTitle", 0x0002_0016, "AE"),
        ("SpecificCharacterSet", 0x0008_0005, "CS"), ("ImageType", 0x0008_0008, "CS"),
        ("InstanceCreationDate", 0x0008_0012, "DA"), ("InstanceCreationTime", 0x0008_0013, "TM"),
        ("SOPClassUID", 0x0008_0016, "UI"), ("SOPInstanceUID", 0x0008_0018, "UI"),
        ("StudyDate", 0x0008_0020, "DA"), ("SeriesDate", 0x0008_0021, "DA"), ("AcquisitionDate", 0x0008_0022, "DA"),
        ("ContentDate", 0x0008_0023, "DA"), ("AcquisitionDateTime", 0x0008_002A, "DT"),
        ("StudyTime", 0x0008_0030, "TM"), ("SeriesTime", 0x0008_0031, "TM"), ("AcquisitionTime", 0x0008_0032, "TM"),
        ("ContentTime", 0x0008_0033, "TM"), ("AccessionNumber", 0x0008_0050, "SH"), ("Modality", 0x0008_0060, "CS"),
        ("ConversionType", 0x0008_0064, "CS"), ("Manufacturer", 0x0008_0070, "LO"), ("InstitutionName", 0x0008_0080, "LO"),
        ("InstitutionAddress", 0x0008_0081, "ST"), ("ReferringPhysicianName", 0x0008_0090, "PN"),
        ("StationName", 0x0008_1010, "SH"), ("StudyDescription", 0x0008_1030, "LO"), ("SeriesDescription", 0x0008_103E, "LO"),
        ("InstitutionalDepartmentName", 0x0008_1040, "LO"), ("PerformingPhysicianName", 0x0008_1050, "PN"),
        ("OperatorsName", 0x0008_1070, "PN"), ("ManufacturerModelName", 0x0008_1090, "LO"),
        ("DerivationDescription", 0x0008_2111, "ST"),
        ("PatientName", 0x0010_0010, "PN"), ("PatientID", 0x0010_0020, "LO"), ("PatientBirthDate", 0x0010_0030, "DA"),
        ("PatientSex", 0x0010_0040, "CS"), ("OtherPatientIDs", 0x0010_1000, "LO"), ("PatientAge", 0x0010_1010, "AS"),
        ("PatientSize", 0x0010_1020, "DS"), ("PatientWeight", 0x0010_1030, "DS"), ("PatientComments", 0x0010_4000, "LT"),
        ("ContrastBolusAgent", 0x0018_0010, "LO"), ("BodyPartExamined", 0x0018_0015, "CS"),
        ("ScanningSequence", 0x0018_0020, "CS"), ("SliceThickness", 0x0018_0050, "DS"), ("KVP", 0x0018_0060, "DS"),
        ("RepetitionTime", 0x0018_0080, "DS"), ("EchoTime", 0x0018_0081, "DS"), ("InversionTime", 0x0018_0082, "DS"),
        ("MagneticFieldStrength", 0x0018_0087, "DS"), ("SpacingBetweenSlices", 0x0018_0088, "DS"),
        ("DeviceSerialNumber", 0x0018_1000, "LO"), ("SoftwareVersions", 0x0018_1020, "LO"),
        ("ProtocolName", 0x0018_1030, "LO"), ("ReconstructionDiameter", 0x0018_1100, "DS"),
        ("GantryDetectorTilt", 0x0018_1120, "DS"), ("ExposureTime", 0x0018_1150, "IS"), ("XRayTubeCurrent", 0x0018_1151, "IS"),
        ("Exposure", 0x0018_1152, "IS"), ("ConvolutionKernel", 0x0018_1210, "SH"), ("ImagerPixelSpacing", 0x0018_1164, "DS"),
        ("PatientPosition", 0x0018_5100, "CS"),
        ("StudyInstanceUID", 0x0020_000D, "UI"), ("SeriesInstanceUID", 0x0020_000E, "UI"), ("StudyID", 0x0020_0010, "SH"),
        ("SeriesNumber", 0x0020_0011, "IS"), ("AcquisitionNumber", 0x0020_0012, "IS"), ("InstanceNumber", 0x0020_0013, "IS"),
        ("PatientOrientation", 0x0020_0020, "CS"), ("ImagePositionPatient", 0x0020_0032, "DS"),
        ("ImageOrientationPatient", 0x0020_0037, "DS"), ("FrameOfReferenceUID", 0x0020_0052, "UI"),
        ("Laterality", 0x0020_0060, "CS"), ("PositionReferenceIndicator", 0x0020_1040, "LO"),
        ("SliceLocation", 0x0020_1041, "DS"), ("ImageComments", 0x0020_4000, "LT"),
        ("SamplesPerPixel", 0x0028_0002, "US"), ("PhotometricInterpretation", 0x0028_0004, "CS"),
        ("PlanarConfiguration", 0x0028_0006, "US"), ("NumberOfFrames", 0x0028_0008, "IS"),
        ("Rows", 0x0028_0010, "US"), ("Columns", 0x0028_0011, "US"), ("PixelSpacing", 0x0028_0030, "DS"),
        ("BitsAllocated", 0x0028_0100, "US"), ("BitsStored", 0x0028_0101, "US"), ("HighBit", 0x0028_0102, "US"),
        ("PixelRepresentation", 0x0028_0103, "US"), ("SmallestImagePixelValue", 0x0028_0106, "US"),
        ("LargestImagePixelValue", 0x0028_0107, "US"), ("WindowCenter", 0x0028_1050, "DS"), ("WindowWidth", 0x0028_1051, "DS"),
        ("RescaleIntercept", 0x0028_1052, "DS"), ("RescaleSlope", 0x0028_1053, "DS"), ("RescaleType", 0x0028_1054, "LO"),
        ("LossyImageCompression", 0x0028_2110, "CS"),
        ("StudyComments", 0x0032_4000, "LT"), ("RequestedProcedureDescription", 0x0032_1060, "LO"),
        ("PerformedProcedureStepDescription", 0x0040_0254, "LO"), ("InterpretationStatusID", 0x4008_0212, "CS"),
        ("PixelData", 0x7FE0_0010, "OW"), ("FloatPixelData", 0x7FE0_0008, "OF"),
    ]

    /// Keywords of the legacy framework that the dictionary spells otherwise.
    private static let legacySpellings: [String: String] = [
        "PatientsName": "PatientName", "PatientsBirthDate": "PatientBirthDate", "PatientsSex": "PatientSex",
        "PatientsAge": "PatientAge", "PatientsSize": "PatientSize", "PatientsWeight": "PatientWeight",
        "ReferringPhysiciansName": "ReferringPhysicianName", "PerformingPhysiciansName": "PerformingPhysicianName",
        "ManufacturersModelName": "ManufacturerModelName", "OperatorName": "OperatorsName",
    ]

    private static let byName: [String: (UInt32, String)] = {
        var table: [String: (UInt32, String)] = [:]
        for (name, tag, vr) in entries { table[name.lowercased()] = (tag, vr) }
        for (legacy, name) in legacySpellings { table[legacy.lowercased()] = table[name.lowercased()] }
        return table
    }()

    private static let byTag: [UInt32: (String, String)] = {
        var table: [UInt32: (String, String)] = [:]
        for (name, tag, vr) in entries { table[tag] = (name, vr) }
        return table
    }()

    /// The tag of a keyword, in either spelling and any case; nil when unknown.
    @objc static func tag(forName name: String) -> NSNumber? {
        byName[name.lowercased()].map { NSNumber(value: $0.0) }
    }

    @objc static func name(forTag tag: UInt32) -> String? { byTag[tag]?.0 }

    /// The VR of a tag: the dictionary's, UL for group lengths, else UN.
    @objc static func vr(forTag tag: UInt32) -> String {
        if let known = byTag[tag] { return known.1 }
        if tag & 0xFFFF == 0 { return "UL" }
        return "UN"
    }

    // MARK: writing

    private static let longVRs: Set<String> = ["OB", "OD", "OF", "OL", "OV", "OW", "SQ", "UC", "UR", "UT", "UN"]
    private static let textVRs: Set<String> = ["AE", "AS", "CS", "DA", "DS", "DT", "IS", "LO", "LT", "PN", "SH", "ST", "TM", "UC", "UI", "UR", "UT"]

    private static func text(_ value: Any, vr: String) -> String {
        switch value {
        case let string as String: return string
        case let number as NSNumber:
            if vr == "IS" { return String(number.intValue) }
            if vr == "DS" {
                let double = number.doubleValue
                if double == double.rounded(), abs(double) < 1e15 { return String(Int64(double)) }
                var text = String(format: "%.10g", double)
                if text.count > 16 { text = String(format: "%.8g", double) }
                return text
            }
            return number.stringValue
        default:
            return (value as AnyObject).description ?? ""
        }
    }

    /// The VRs whose text follows the Specific Character Set.
    private static let characterSetVRs: Set<String> = ["LO", "LT", "PN", "SH", "ST", "UC", "UT"]

    /// The bytes of a value: text padded to an even length (UI with a null,
    /// the others with a space), numbers in little endian, binary as given.
    /// Text of the character set VRs is in `encoding`, the others in ASCII.
    static func valueBytes(_ element: IsiXLegacyDICOMElement, encoding: String.Encoding = .utf8) -> Data {
        let vr = element.vr
        var data = Data()
        if textVRs.contains(vr) {
            let joined = element.values.map { text($0, vr: vr) }.joined(separator: "\\")
            data = joined.data(using: characterSetVRs.contains(vr) ? encoding : .ascii, allowLossyConversion: true) ?? Data()
            if data.count % 2 == 1 { data.append(vr == "UI" ? 0 : 0x20) }
            return data
        }
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        for value in element.values {
            if let bytes = value as? Data { data.append(bytes); continue }
            let number = (value as? NSNumber) ?? NSNumber(value: Double(text(value, vr: "DS")) ?? 0)
            switch vr {
            case "US": append(number.uint16Value.littleEndian)
            case "SS": append(number.int16Value.littleEndian)
            case "UL": append(number.uint32Value.littleEndian)
            case "SL": append(number.int32Value.littleEndian)
            case "FL": append(number.floatValue.bitPattern.littleEndian)
            case "FD": append(number.doubleValue.bitPattern.littleEndian)
            case "AT": append(UInt16(truncatingIfNeeded: number.uint32Value >> 16).littleEndian)
                append(UInt16(truncatingIfNeeded: number.uint32Value).littleEndian)
            default: append(number.uint8Value)
            }
        }
        if data.count % 2 == 1 { data.append(0) }
        return data
    }

    private static func header(_ tag: UInt32, vr: String, length: Int, explicit: Bool) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append(UInt16(tag >> 16))
        append(UInt16(tag & 0xFFFF))
        if explicit {
            data.append(contentsOf: Array((vr.count == 2 ? vr : "UN").utf8))
            if longVRs.contains(vr) {
                append(UInt16(0))
                append(UInt32(length))
            } else {
                append(UInt16(length))
            }
        } else {
            append(UInt32(length))
        }
        return data
    }

    /// A Part 10 file: preamble, meta information (explicit VR) and the
    /// dataset in the transfer syntax, explicit or implicit VR little endian.
    /// Sequences are not written; nil when an element's value is too long for
    /// its VR or the syntax is another one.
    @objc static func fileData(elements: [IsiXLegacyDICOMElement], transferSyntax: String) -> Data? {
        guard transferSyntax == explicitLittleEndian || transferSyntax == implicitLittleEndian else { return nil }
        let explicit = transferSyntax == explicitLittleEndian
        var dataset = elements.filter { $0.tag >> 16 != 0x0002 && $0.vr != "SQ" && $0.tag & 0xFFFF != 0 }.sorted { $0.tag < $1.tag }
        // Text that is not ASCII is written in Latin-1 when the plugin declared
        // ISO_IR 100, and otherwise in UTF-8, declared as ISO_IR 192.
        let declared = (dataset.first { $0.tag == 0x0008_0005 }?.values.first as? String)?.trimmingCharacters(in: .whitespaces)
        let encoding: String.Encoding = declared == "ISO_IR 100" ? .isoLatin1 : .utf8
        let nonASCII = dataset.contains { element in
            characterSetVRs.contains(element.vr) && element.values.contains { !text($0, vr: element.vr).allSatisfy(\.isASCII) }
        }
        if nonASCII && declared == nil {
            dataset.append(IsiXLegacyDICOMElement(tag: 0x0008_0005, vr: "CS", values: ["ISO_IR 192"]))
            dataset.sort { $0.tag < $1.tag }
        }
        let value: (UInt32) -> Any? = { tag in dataset.first { $0.tag == tag }?.values.first }
        let sopClass = (value(0x0008_0016) as? String) ?? "1.2.840.10008.5.1.4.1.1.7"
        let sopInstance = (value(0x0008_0018) as? String) ?? IsiXLegacyDatabaseBridge.freshUID()
        let meta = [IsiXLegacyDICOMElement(tag: 0x0002_0001, vr: "OB", values: [Data([0, 1])]),
                    IsiXLegacyDICOMElement(tag: 0x0002_0002, vr: "UI", values: [sopClass]),
                    IsiXLegacyDICOMElement(tag: 0x0002_0003, vr: "UI", values: [sopInstance]),
                    IsiXLegacyDICOMElement(tag: 0x0002_0010, vr: "UI", values: [transferSyntax]),
                    IsiXLegacyDICOMElement(tag: 0x0002_0012, vr: "UI", values: [implementationClassUID]),
                    IsiXLegacyDICOMElement(tag: 0x0002_0013, vr: "SH", values: ["ISIXLEGACY"])]
        var metaBody = Data()
        for element in meta {
            let bytes = valueBytes(element)
            metaBody += header(element.tag, vr: element.vr, length: bytes.count, explicit: true) + bytes
        }
        var file = Data(count: 128)
        file.append(contentsOf: Array("DICM".utf8))
        let groupLength = IsiXLegacyDICOMElement(tag: 0x0002_0000, vr: "UL", values: [NSNumber(value: metaBody.count)])
        file += header(groupLength.tag, vr: "UL", length: 4, explicit: true) + valueBytes(groupLength) + metaBody
        for element in dataset {
            let bytes = valueBytes(element, encoding: encoding)
            if explicit && !longVRs.contains(element.vr) && bytes.count > 0xFFFF { return nil }
            file += header(element.tag, vr: element.vr, length: bytes.count, explicit: explicit) + bytes
        }
        return file
    }

    // MARK: reading

    private struct Reader {
        let data: Data
        var offset: Int

        func u16(_ at: Int) -> UInt16? {
            guard at + 2 <= data.count else { return nil }
            return UInt16(data[data.startIndex + at]) | UInt16(data[data.startIndex + at + 1]) << 8
        }

        func u32(_ at: Int) -> UInt32? {
            guard let low = u16(at), let high = u16(at + 2) else { return nil }
            return UInt32(low) | UInt32(high) << 16
        }

        func bytes(_ at: Int, _ count: Int) -> Data? {
            guard count >= 0, at + count <= data.count else { return nil }
            return data.subdata(in: (data.startIndex + at)..<(data.startIndex + at + count))
        }
    }

    private static let undefinedLength: UInt32 = 0xFFFF_FFFF

    /// Values of an element as the legacy framework gave them.
    private static func values(of bytes: Data, vr: String) -> [Any] {
        if textVRs.contains(vr) {
            var text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1) ?? ""
            while let last = text.last, last == " " || last == "\0" { text.removeLast() }
            let parts = ["LT", "ST", "UT", "UR"].contains(vr) ? [text] : text.components(separatedBy: "\\")
            return parts.map { part -> Any in
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                switch vr {
                case "DS": return Double(trimmed).map { NSNumber(value: $0) } ?? trimmed
                case "IS": return Int(trimmed).map { NSNumber(value: $0) } ?? trimmed
                case "DA", "TM", "DT": return IsiXLegacyDICOMDate(kind: vr, value: trimmed)
                default: return vr == "UI" ? trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\0")) : trimmed
                }
            }
        }
        func numbers<T>(_ size: Int, _ make: (Data) -> T) -> [Any] {
            stride(from: 0, to: bytes.count - size + 1, by: size).map { make(bytes.subdata(in: (bytes.startIndex + $0)..<(bytes.startIndex + $0 + size))) as Any }
        }
        func integer<T: FixedWidthInteger>(_ data: Data, _: T.Type) -> T {
            data.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
        }
        switch vr {
        case "US": return numbers(2) { NSNumber(value: integer($0, UInt16.self)) }
        case "SS": return numbers(2) { NSNumber(value: integer($0, Int16.self)) }
        case "UL": return numbers(4) { NSNumber(value: integer($0, UInt32.self)) }
        case "SL": return numbers(4) { NSNumber(value: integer($0, Int32.self)) }
        case "FL": return numbers(4) { NSNumber(value: Float(bitPattern: integer($0, UInt32.self))) }
        case "FD": return numbers(8) { NSNumber(value: Double(bitPattern: integer($0, UInt64.self))) }
        case "AT": return numbers(4) { data in
            let group = integer(data.prefix(2), UInt16.self), element = integer(data.suffix(2), UInt16.self)
            return NSNumber(value: UInt32(group) << 16 | UInt32(element))
        }
        default: return [bytes]
        }
    }

    /// Skips a sequence or an item of undefined length; returns the offset
    /// after its delimiter.
    private static func skipUndefined(_ reader: Reader, from start: Int, explicit: Bool) -> Int? {
        var offset = start
        var depth = 1
        while depth > 0 {
            guard let group = reader.u16(offset), let element = reader.u16(offset + 2) else { return nil }
            let tag = UInt32(group) << 16 | UInt32(element)
            if group == 0xFFFE {
                guard let length = reader.u32(offset + 4) else { return nil }
                offset += 8
                if tag == 0xFFFE_E0DD || tag == 0xFFFE_E00D { depth -= 1 }
                else if length == undefinedLength { depth += 1 }
                else { offset += Int(length) }
                continue
            }
            guard let parsed = elementHeader(reader, at: offset, explicit: explicit) else { return nil }
            offset = parsed.valueOffset
            if parsed.length == undefinedLength { depth += 1 } else { offset += Int(parsed.length) }
        }
        return offset
    }

    private static func elementHeader(_ reader: Reader, at offset: Int, explicit: Bool) -> (vr: String, length: UInt32, valueOffset: Int)? {
        guard let group = reader.u16(offset), let element = reader.u16(offset + 2) else { return nil }
        let tag = UInt32(group) << 16 | UInt32(element)
        if explicit, let vrBytes = reader.bytes(offset + 4, 2), let vr = String(data: vrBytes, encoding: .ascii),
           vr.allSatisfy({ $0.isUppercase }) {
            if longVRs.contains(vr) {
                guard let length = reader.u32(offset + 8) else { return nil }
                return (vr, length, offset + 12)
            }
            guard let length = reader.u16(offset + 6) else { return nil }
            return (vr, UInt32(length), offset + 8)
        }
        guard let length = reader.u32(offset + 4) else { return nil }
        return (vr(forTag: tag), length, offset + 8)
    }

    /// Reads a file: Part 10 (with its preamble) or a bare dataset in
    /// implicit VR little endian. Big endian and deflated files are not
    /// read; compressed pixel data is kept undecoded, in one value.
    @objc static func read(_ data: Data) -> IsiXLegacyDICOMDataset? {
        var reader = Reader(data: data, offset: 0)
        var elements: [IsiXLegacyDICOMElement] = []
        var transferSyntax = implicitLittleEndian
        if data.count >= 132, String(data: data.subdata(in: (data.startIndex + 128)..<(data.startIndex + 132)), encoding: .ascii) == "DICM" {
            reader.offset = 132
            while let group = reader.u16(reader.offset), group == 0x0002,
                  let header = elementHeader(reader, at: reader.offset, explicit: true),
                  header.length != undefinedLength, let element = reader.u16(reader.offset + 2),
                  let bytes = reader.bytes(header.valueOffset, Int(header.length)) {
                let tag = UInt32(group) << 16 | UInt32(element)
                let decoded = values(of: bytes, vr: header.vr)
                elements.append(IsiXLegacyDICOMElement(tag: tag, vr: header.vr, values: decoded))
                if tag == 0x0002_0010, let syntax = decoded.first as? String { transferSyntax = syntax }
                reader.offset = header.valueOffset + Int(header.length)
            }
        }
        if transferSyntax == explicitBigEndian || transferSyntax == deflatedExplicitLittleEndian { return nil }
        let explicit = transferSyntax != implicitLittleEndian
        while reader.offset < data.count {
            guard let group = reader.u16(reader.offset), let element = reader.u16(reader.offset + 2),
                  let header = elementHeader(reader, at: reader.offset, explicit: explicit) else { return nil }
            let tag = UInt32(group) << 16 | UInt32(element)
            if header.length == undefinedLength {
                if tag == 0x7FE0_0010 {
                    // Encapsulated pixel data: everything up to the sequence delimiter, as it is.
                    guard let end = skipUndefined(reader, from: header.valueOffset, explicit: explicit),
                          let bytes = reader.bytes(header.valueOffset, end - header.valueOffset) else { return nil }
                    elements.append(IsiXLegacyDICOMElement(tag: tag, vr: "OB", values: [bytes]))
                    reader.offset = end
                } else {
                    guard let end = skipUndefined(reader, from: header.valueOffset, explicit: explicit) else { return nil }
                    elements.append(IsiXLegacyDICOMElement(tag: tag, vr: "SQ", values: []))
                    reader.offset = end
                }
                continue
            }
            guard let bytes = reader.bytes(header.valueOffset, Int(header.length)) else { return nil }
            elements.append(IsiXLegacyDICOMElement(tag: tag, vr: header.vr, values: header.vr == "SQ" ? [] : values(of: bytes, vr: header.vr)))
            reader.offset = header.valueOffset + Int(header.length)
        }
        return IsiXLegacyDICOMDataset(transferSyntax: transferSyntax, elements: elements)
    }
}

/// A DA, TM or DT value read from a file, before the Objective-C side makes
/// a DCMCalendarDate of it.
@objc final class IsiXLegacyDICOMDate: NSObject {
    @objc let kind: String
    @objc let value: String

    init(kind: String, value: String) {
        self.kind = kind
        self.value = value
    }
}
