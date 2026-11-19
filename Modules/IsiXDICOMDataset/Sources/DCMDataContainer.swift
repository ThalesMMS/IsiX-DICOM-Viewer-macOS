/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation
import IsiXDICOMFile

/// The bytes of a DICOM object as DCM.framework read and wrote them: a
/// mutable buffer, a reading position, the transfer syntaxes of the meta
/// header and of the dataset, and the primitives that take the next value or
/// add one. The model reads and writes through the host's DCMTK now; the
/// container stays for a plugin built for Horos or OsiriX, which makes one,
/// has a DCMObject written into it and takes its `dicomData`.
///
/// As they did, the readers raise DCMInvalidLengthException when the value
/// asked for goes past the end of the bytes, and the writers add every number
/// in the byte order of the machine, which is little-endian, whatever the
/// syntax in use says: the former writers never swapped to big-endian either.
/// The dates are DCMCalendarDate objects, the date class of the DICOM files.
///
/// A subclass a plugin makes in Objective-C of a Swift class of a module has
/// no Swift metadata of its own: none is known, and the class is final.
@objc(DCMDataContainer)
public class DCMDataContainer: NSObject {
    @objc public private(set) var dicomData: NSMutableData
    @objc public private(set) var offset: Int32 = 0
    @objc public private(set) var position: Int32 = 0

    // The two flags the setters write. As in the former class, the answers of
    // -isLittleEndian and -isExplicitTS come from the syntax in use, not from them.
    private var littleEndianFlag = true
    private var explicitFlag = false
    private var encoding = String.Encoding.isoLatin1.rawValue
    private var datasetSyntax: DCMTransferSyntax?
    private var metaheaderSyntax: DCMTransferSyntax?
    private var syntaxInUse: DCMTransferSyntax?

    // MARK: Making one

    /// An empty container, to write into: explicit little-endian for its meta header.
    @objc public override init() {
        dicomData = NSMutableData()
        metaheaderSyntax = .explicitVRLittleEndianTransferSyntax()
        super.init()
        initValues()
    }

    /// A container over a copy of `data`, with the syntax its first bytes
    /// show; nil for bytes too few to tell.
    @objc(initWithData:) public convenience init?(data: Data?) {
        guard let data else { return nil }
        self.init(taking: NSMutableData(data: data), syntax: nil)
        if !determineSyntax() { return nil }
    }

    /// A container over a copy of `data` that is in `syntax`.
    @objc(initWithData:transferSyntax:) public convenience init(data: Data?, transferSyntax syntax: DCMTransferSyntax?) {
        self.init(taking: NSMutableData(data: data ?? Data()), syntax: syntax)
    }

    /// A container over `data` itself, which what is added goes into.
    @objc(initWithMutableData:transferSyntax:) public convenience init(mutableData data: NSMutableData?, transferSyntax syntax: DCMTransferSyntax?) {
        self.init(taking: data ?? NSMutableData(), syntax: syntax)
    }

    @objc(initWithContentsOfFile:) public convenience init?(contentsOfFile path: String?) {
        self.init(data: path.flatMap { FileManager.default.contents(atPath: $0) })
    }

    @objc(initWithContentsOfURL:) public convenience init?(contentsOf url: URL?) {
        self.init(data: url.flatMap { try? Data(contentsOf: $0) })
    }

    @objc(initWithBytes:length:) public convenience init?(bytes: UnsafeRawPointer?, length: UInt) {
        guard let bytes else { return nil }
        self.init(taking: NSMutableData(bytes: bytes, length: Int(length)), syntax: nil)
        if !determineSyntax() { return nil }
    }

    /// Over the bytes themselves, which the container frees with free() when it goes.
    @objc(initWithBytesNoCopy:length:) public convenience init?(bytesNoCopy bytes: UnsafeMutableRawPointer?, length: UInt) {
        self.init(bytesNoCopy: bytes, length: length, freeWhenDone: true)
    }

    @objc(initWithBytesNoCopy:length:freeWhenDone:)
    public convenience init?(bytesNoCopy bytes: UnsafeMutableRawPointer?, length: UInt, freeWhenDone: Bool) {
        guard let bytes else { return nil }
        self.init(taking: NSMutableData(bytesNoCopy: bytes, length: Int(length), freeWhenDone: freeWhenDone), syntax: nil)
        if !determineSyntax() { return nil }
    }

    private init(taking data: NSMutableData, syntax: DCMTransferSyntax?) {
        dicomData = data
        metaheaderSyntax = syntax
        datasetSyntax = syntax
        syntaxInUse = syntax
        super.init()
    }

    @objc(dataContainer) public class func dataContainer() -> DCMDataContainer { DCMDataContainer() }
    @objc(dataContainerWithBytes:length:) public class func dataContainer(bytes: UnsafeRawPointer?, length: UInt) -> DCMDataContainer? {
        DCMDataContainer(bytes: bytes, length: length)
    }
    @objc(dataContainerWithBytesNoCopy:length:) public class func dataContainer(bytesNoCopy bytes: UnsafeMutableRawPointer?, length: UInt) -> DCMDataContainer? {
        DCMDataContainer(bytesNoCopy: bytes, length: length)
    }
    @objc(dataContainerWithBytesNoCopy:length:freeWhenDone:)
    public class func dataContainer(bytesNoCopy bytes: UnsafeMutableRawPointer?, length: UInt, freeWhenDone: Bool) -> DCMDataContainer? {
        DCMDataContainer(bytesNoCopy: bytes, length: length, freeWhenDone: freeWhenDone)
    }
    @objc(dataContainerWithContentsOfFile:) public class func dataContainer(contentsOfFile path: String?) -> DCMDataContainer? {
        DCMDataContainer(contentsOfFile: path)
    }
    @objc(dataContainerWithContentsOfURL:) public class func dataContainer(contentsOf url: URL?) -> DCMDataContainer? {
        DCMDataContainer(contentsOf: url)
    }
    @objc(dataContainerWithData:) public class func dataContainer(data: Data?) -> DCMDataContainer? { DCMDataContainer(data: data) }
    @objc(dataContainerWithData:transferSyntax:) public class func dataContainer(data: Data?, transferSyntax syntax: DCMTransferSyntax?) -> DCMDataContainer {
        DCMDataContainer(data: data, transferSyntax: syntax)
    }
    /// As the former method did, over a copy of `data`, not over `data` itself.
    @objc(dataContainerWithMutableData:transferSyntax:)
    public class func dataContainer(mutableData data: NSMutableData?, transferSyntax syntax: DCMTransferSyntax?) -> DCMDataContainer {
        DCMDataContainer(data: data as Data?, transferSyntax: syntax)
    }

    /// The state of a container about to be read from its start: Latin-1
    /// strings, and the position after the preamble and «DICM» when the bytes
    /// have them.
    @objc public func initValues() {
        littleEndianFlag = true
        explicitFlag = false
        offset = 0
        position = 0
        encoding = String.Encoding.isoLatin1.rawValue
        if dicomData.length >= 132, bytes(at: 128, count: 4) == Array("DICM".utf8) {
            offset = 132
            position = 132
        }
    }

    // MARK: State

    @objc public var length: UInt32 { UInt32(truncatingIfNeeded: dicomData.length) }
    @objc public func isLittleEndian() -> Bool { syntaxInUse?.isLittleEndian ?? true }
    @objc public func isExplicitTS() -> Bool { syntaxInUse?.isExplicit ?? true }
    @objc public func isEncapsulated() -> Bool { syntaxInUse?.isEncapsulated ?? false }
    @objc public func dataRemaining() -> Bool { Int(position) < dicomData.length }
    @objc public func stringEncoding() -> UInt { encoding }
    @objc(setLittleEndian:) public func setLittleEndian(_ value: Bool) { littleEndianFlag = value }
    @objc(setExplicitTS:) public func setExplicitTS(_ value: Bool) { explicitFlag = value }
    @objc(setStringEncoding:) public func setStringEncoding(_ value: UInt) { encoding = value }

    @objc public func transferSyntaxForDataset() -> DCMTransferSyntax? { datasetSyntax }
    @objc public func transferSyntaxForMetaheader() -> DCMTransferSyntax? { metaheaderSyntax }
    @objc public func transferSyntaxInUse() -> DCMTransferSyntax? { syntaxInUse }
    @objc(setTransferSyntaxForDataset:) public func setTransferSyntaxForDataset(_ syntax: DCMTransferSyntax?) { datasetSyntax = syntax }
    @objc(setTransferSyntaxForMetaheader:) public func setTransferSyntaxForMetaheader(_ syntax: DCMTransferSyntax?) { metaheaderSyntax = syntax }
    @objc(setUseMetaheaderTS:) public func setUseMetaheaderTS(_ flag: Bool) { syntaxInUse = flag ? metaheaderSyntax : datasetSyntax }
    @objc public func startReadingMetaHeader() { syntaxInUse = metaheaderSyntax }
    @objc public func startReadingDataSet() { syntaxInUse = datasetSyntax }

    // MARK: Reading

    /// The exception a reader raises for `elementLength` bytes that are not
    /// there, or nil when they are.
    @objc(testForLength:) public func testForLength(_ elementLength: Int32) -> NSException? {
        if has(Int(elementLength)) { return nil }
        return NSException(name: NSExceptionName("DCMInvalidLengthException"), reason: "Length of element exceeds length remaining in data.",
                           userInfo: ["position": NSNumber(value: position), "elementLength": NSNumber(value: elementLength),
                                      "dataLength": NSNumber(value: Int32(truncatingIfNeeded: dicomData.length))])
    }

    private func has(_ count: Int) -> Bool {
        count >= 0 && position >= 0 && Int(position) + count <= dicomData.length
    }

    private func bytes(at start: Int, count: Int) -> [UInt8] {
        guard start >= 0, count >= 0, start + count <= dicomData.length else { return [] }
        return [UInt8](UnsafeRawBufferPointer(start: dicomData.bytes + start, count: count))
    }

    /// The next `count` bytes, the position moved past them; nil when they are not there.
    private func take(_ count: Int) -> [UInt8]? {
        guard has(count) else { return nil }
        defer { position += Int32(count) }
        return bytes(at: Int(position), count: count)
    }

    /// The same, raising as the readers of the former class did.
    private func next(_ count: Int32) -> [UInt8]? {
        if let taken = take(Int(count)) { return taken }
        testForLength(count)?.raise()
        return nil
    }

    private func number<Value: FixedWidthInteger>(_ bytes: [UInt8]?, as type: Value.Type) -> Value {
        guard let bytes, bytes.count == MemoryLayout<Value>.size else { return 0 }
        let value = bytes.withUnsafeBytes { $0.loadUnaligned(as: Value.self) }
        return isLittleEndian() ? Value(littleEndian: value) : Value(bigEndian: value)
    }

    @objc public func nextUnsignedChar() -> UInt8 { next(1)?.first ?? 0 }
    @objc public func nextUnsignedShort() -> UInt16 { number(next(2), as: UInt16.self) }
    @objc public func nextSignedShort() -> Int16 { number(next(2), as: Int16.self) }
    @objc public func nextUnsignedLong() -> UInt32 { number(next(4), as: UInt32.self) }
    @objc public func nextSignedLong() -> Int32 { number(next(4), as: Int32.self) }
    @objc public func nextUnsignedLongLong() -> UInt64 { number(next(8), as: UInt64.self) }
    /// In the byte order of the machine whatever the syntax, as it always was.
    @objc public func nextSignedLongLong() -> Int64 {
        guard let bytes = next(8) else { return 0 }
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }
    }
    @objc public func nextFloat() -> Float { Float(bitPattern: nextUnsignedLong()) }
    @objc public func nextDouble() -> Double { Double(bitPattern: nextUnsignedLongLong()) }

    private static func trimmed(_ string: String?) -> String? {
        string?.trimmingCharacters(in: .controlCharacters).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc(nextStringWithLength:) public func nextString(withLength length: Int32) -> String? {
        if encoding == 0 { encoding = String.Encoding.isoLatin1.rawValue }
        return nextString(withLength: length, encoding: encoding)
    }

    @objc(nextStringWithLength:encoding:) public func nextString(withLength length: Int32, encoding: UInt) -> String? {
        guard let bytes = next(length) else { return nil }
        return Self.trimmed(String(bytes: bytes, encoding: String.Encoding(rawValue: encoding)))
    }

    /// The next string of a value that may change character set on the way:
    /// `encodings` are the ten of its Specific Character Set.
    @objc(nextStringWithLength:encodings:) public func nextString(withLength length: Int32, encodings: UnsafeMutablePointer<UInt>?) -> String? {
        guard let bytes = next(length) else { return nil }
        guard let encodings else { return Self.trimmed(String(bytes: bytes, encoding: .isoLatin1)) }
        let string = bytes.withUnsafeBufferPointer { buffer in
            buffer.withMemoryRebound(to: CChar.self) {
                DICOMCharacterSet.string(withBytes: $0.baseAddress, length: UInt32(bytes.count), encodings: UnsafePointer(encodings))
            }
        }
        return Self.trimmed(string)
    }

    private func nextText(_ length: Int32) -> String? {
        guard let bytes = next(length) else { return nil }
        return Self.trimmed(String(bytes: bytes, encoding: .utf8))
    }

    /// The values of a text of several, separated by a backslash, each made a date by `make`.
    private func dates(_ length: Int32, needsNumber: Bool, _ make: (String?) -> DICOMCalendarDate?) -> NSMutableArray? {
        guard let text = nextText(length) else { return nil }
        let dates = NSMutableArray()
        if needsNumber && (text as NSString).intValue == 0 { return dates }
        for value in text.components(separatedBy: "\\") {
            if let date = make(value) { dates.add(date) }
        }
        return dates
    }

    @objc public func nextDate() -> DICOMCalendarDate? { nextText(8).flatMap { DICOMCalendarDate.dicomDate($0) } }
    @objc(nextDatesWithLength:) public func nextDates(withLength length: Int32) -> NSMutableArray? {
        dates(length, needsNumber: true) { DICOMCalendarDate.dicomDate($0) }
    }
    @objc(nextTimeWithLength:) public func nextTime(withLength length: Int32) -> DICOMCalendarDate? {
        nextText(length).flatMap { DICOMCalendarDate.dicomTime($0) }
    }
    @objc(nextTimesWithLength:) public func nextTimes(withLength length: Int32) -> NSMutableArray? {
        dates(length, needsNumber: true) { DICOMCalendarDate.dicomTime($0) }
    }
    @objc(nextDateTimeWithLength:) public func nextDateTime(withLength length: Int32) -> DICOMCalendarDate? {
        nextText(length).flatMap { DICOMCalendarDate.dicomDateTime($0) }
    }
    @objc(nextDateTimesWithLength:) public func nextDateTimes(withLength length: Int32) -> NSMutableArray? {
        dates(length, needsNumber: false) { DICOMCalendarDate.dicomDateTime($0) }
    }

    @objc(nextDataWithLength:) public func nextData(withLength length: Int32) -> NSMutableData? {
        next(length).map { NSMutableData(data: Data($0)) }
    }

    @objc(skipLength:) public func skipLength(_ length: Int32) -> Bool { next(length) != nil }

    // MARK: Writing

    private func add<Value: FixedWidthInteger>(_ value: Value) {
        withUnsafeBytes(of: value.littleEndian) { dicomData.append($0.baseAddress!, length: $0.count) }
    }

    @objc(addUnsignedChar:) public func addUnsignedChar(_ value: UInt8) { add(value) }
    @objc(addSignedChar:) public func addSignedChar(_ value: Int8) { add(value) }
    @objc(addUnsignedShort:) public func addUnsignedShort(_ value: UInt16) { add(value) }
    @objc(addSignedShort:) public func addSignedShort(_ value: Int16) { add(value) }
    // The SDK declared these two with a long, of which four bytes were written.
    @objc(addUnsignedLong:) public func addUnsignedLong(_ value: UInt) { add(UInt32(truncatingIfNeeded: value)) }
    @objc(addSignedLong:) public func addSignedLong(_ value: Int) { add(Int32(truncatingIfNeeded: value)) }
    @objc(addUnsignedLongLong:) public func addUnsignedLongLong(_ value: UInt64) { add(value) }
    @objc(addSignedLongLong:) public func addSignedLongLong(_ value: Int64) { add(value) }
    @objc(addFloat:) public func addFloat(_ value: Float) { add(value.bitPattern) }
    @objc(addDouble:) public func addDouble(_ value: Double) { add(value.bitPattern) }

    /// The bytes of `string` in `encoding`, and `padding` after an odd number of them.
    private func add(_ string: String?, encoding: UInt, padding: UInt8?) {
        let data = (string ?? "").data(using: String.Encoding(rawValue: encoding)) ?? Data()
        dicomData.append(data)
        if let padding, data.count % 2 != 0 { add(padding) }
    }

    @objc(addString:) public func addString(_ string: String?) { add(string, encoding: encoding, padding: 0x20) }
    @objc(addStringWithZeroPadding:) public func addStringWithZeroPadding(_ string: String?) { add(string, encoding: encoding, padding: 0) }
    @objc(addString:withEncoding:) public func addString(_ string: String?, withEncoding encoding: UInt) { add(string, encoding: encoding, padding: 0x20) }
    /// In the first of the encodings, as it was.
    @objc(addString:withEncodings:) public func addString(_ string: String?, withEncodings encodings: UnsafeMutablePointer<UInt>?) {
        add(string, encoding: encodings?.pointee ?? encoding, padding: 0x20)
    }
    @objc(addStringWithoutPadding:) public func addStringWithoutPadding(_ string: String?) { add(string, encoding: encoding, padding: nil) }

    @objc(addDate:) public func addDate(_ date: DICOMCalendarDate?) { add(date?.dateString(), encoding: String.Encoding.utf8.rawValue, padding: nil) }
    @objc(addTime:) public func addTime(_ time: DICOMCalendarDate?) { add(time?.timeString(), encoding: String.Encoding.utf8.rawValue, padding: nil) }
    @objc(addDateTime:) public func addDateTime(_ dateTime: DICOMCalendarDate?) {
        add(dateTime?.dateTimeString(false), encoding: String.Encoding.utf8.rawValue, padding: nil)
    }

    /// The bytes of `data`, and a zero after an odd number of them.
    @objc(addData:) public func addData(_ data: Data?) {
        guard let data else { return }
        dicomData.append(data)
        if data.count % 2 != 0 { add(UInt8(0)) }
    }

    /// The 128 zero bytes and «DICM» a DICOM file starts with. The selector keeps the SDK's spelling.
    @objc(addPremable) public func addPreamble() {
        dicomData.increaseLength(by: 128)
        addString("DICM")
    }

    // MARK: The syntax of bytes to read

    /// Reads the first bytes to tell how the rest is encoded: a Part 10 file
    /// by its «DICM», with an explicit or implicit meta header; without it,
    /// a dataset in explicit little-endian or big-endian when its first
    /// element shows a value representation, in implicit little-endian
    /// otherwise. It answers YES for any bytes it could read, as it did.
    @objc public func determineTransferSyntax() -> Bool {
        if determineSyntax() { return true }
        NSLog("Not a valid DICOM file")
        return false
    }

    private func determineSyntax() -> Bool {
        syntaxInUse = .explicitVRLittleEndianTransferSyntax()
        position = 128
        if take(4).map({ $0 == Array("DICM".utf8) }) == true {
            guard take(4) != nil, let vr = take(2) else { return false }
            metaheaderSyntax = DCMValueRepresentation.isValidVR(String(bytes: vr, encoding: .isoLatin1))
                ? .explicitVRLittleEndianTransferSyntax() : .implicitVRLittleEndianTransferSyntax()
            syntaxInUse = metaheaderSyntax
            offset = 132
            position = 132
            return true
        }
        position = 0
        offset = 0
        guard take(4) != nil, let vr = take(2) else { return false }
        if DCMValueRepresentation.isValidVR(String(bytes: vr, encoding: .isoLatin1)) {
            datasetSyntax = .explicitVRLittleEndianTransferSyntax()
        } else if DCMValueRepresentation.isValidVR(String(bytes: [vr[1], vr[0]], encoding: .isoLatin1)) {
            datasetSyntax = .explicitVRBigEndianTransferSyntax()
        } else {
            metaheaderSyntax = .implicitVRLittleEndianTransferSyntax()
            datasetSyntax = metaheaderSyntax
        }
        syntaxInUse = datasetSyntax
        position = 0
        offset = 0
        return true
    }
}
