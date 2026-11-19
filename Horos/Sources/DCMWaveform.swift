/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Â version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. Â See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. Â If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Â  OsiriX
 Â Copyright (c) OsiriX Team
 Â All rights reserved.
 Â Distributed under GNU - LGPL
 Â 
 Â See http://www.osirix-viewer.com/copyright.html for details.
 Â  Â  This software is distributed WITHOUT ANY WARRANTY; without even
 Â  Â  the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Â  Â  PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

// The implementation of the waveform classes declared in DCMWaveform.h: the
// waveform of a DICOM file as the plugin SDK of Horos and OsiriX described
// it. They are objects of values, which the SDK's reader of DICOM files
// filled; here a plugin fills them and reads them.
//
// Each value is kept in the instance variable the SDK declared for it, with
// its name and its type: a plugin built for the SDK binds those names when it
// loads, and reads and writes the variables directly, with no message. The
// properties of the SDK's classes were atomic, and a plugin reads and writes
// an object from the thread it is on: each object has a lock, under which
// the properties and the methods here read and write its variables. What a
// plugin writes directly takes no lock, as it took none in the SDK. An array
// or a buffer a plugin set to nil is an empty one, as a message to nil
// answered.

/// What the methods of these classes share: the values a DICOM file writes as
/// text, the bytes it gives, and the ownership of what a -new... answers.
private enum WaveformValue {
    /// The text of a code string of the file; nil for none.
    static func text(_ cs: UnsafeMutablePointer<CChar>?) -> String? {
        cs.map { String(cString: $0) }
    }

    /// A value the standard does not define, as the SDK's classes refused it.
    static func raiseInvalid(_ what: String, _ value: String?) {
        NSException(name: .genericException, reason: "Invalid \(what) value: \(value ?? "(null)")", userInfo: nil).raise()
    }

    /// A copy of `length` bytes; empty when there is no address to read.
    static func bytes(_ data: UnsafeMutableRawPointer?, _ length: Int) -> NSData {
        guard let data, length > 0 else { return NSData() }
        return NSData(bytes: data, length: length)
    }

    /// The object as a method of the SDK named -new... answered it: kept by
    /// the receiver and autoreleased, not owned by the caller. Swift gives the
    /// caller of a selector of that name an object it owns, which a plugin
    /// built for the SDK would never release; a method that answers this
    /// instead hands over no ownership.
    static func keptByItsParent<Object: AnyObject>(_ object: Object) -> Unmanaged<Object> {
        Unmanaged.passRetained(object).autorelease()
    }
}

// MARK: - DCMWaveform

@objc @implementation extension DCMWaveform {
    final var _sequences: NSMutableArray? = NSMutableArray()
    private final let lock = NSLock()

    @objc(newSequence)
    private func addedSequence() -> Unmanaged<DCMWaveformSequence> {
        let sequence = DCMWaveformSequence()
        lock.withLock { _sequences?.add(sequence) }
        return WaveformValue.keptByItsParent(sequence)
    }

    func sequences() -> [Any]! {
        lock.withLock { _sequences?.copy() as? [Any] }
    }
}

// MARK: - DCMWaveformSequence

@objc @implementation extension DCMWaveformSequence {
    final var _multiplexgroupTimeOffset: CGFloat = 0, _triggerTimeOffset: CGFloat = 0
    final var _triggerSamplePosition: UInt32 = 0
    final var _waveformOriginality: DCMWaveformOriginality = DCMWaveformOriginalityOriginal
    final var _numberOfWaveformChannels: UInt16 = 0
    final var _numberOfWaveformSamples: UInt32 = 0
    final var _samplingFrequency: CGFloat = 0
    final var _multiplexGroupLabel: NSString?
    final var _channelDefinitions: NSMutableArray? = NSMutableArray()
    final var _waveformBitsAllocated: UInt16 = 0
    final var _waveformSampleInterpretation: DCMWaveformSampleInterpretation = DCMWaveformSampleInterpretationSB
    final var _waveformPaddingValue: NSData?, _waveformData: NSData?
    /// The samples as numbers, once -getValues: has computed them.
    final var _buffer: NSMutableData?
    private final let lock = NSLock()

    var multiplexgroupTimeOffset: CGFloat {
        get { lock.withLock { _multiplexgroupTimeOffset } }
        set { lock.withLock { _multiplexgroupTimeOffset = newValue } }
    }

    var triggerTimeOffset: CGFloat {
        get { lock.withLock { _triggerTimeOffset } }
        set { lock.withLock { _triggerTimeOffset = newValue } }
    }

    var triggerSamplePosition: UInt32 {
        get { lock.withLock { _triggerSamplePosition } }
        set { lock.withLock { _triggerSamplePosition = newValue } }
    }

    var waveformOriginality: DCMWaveformOriginality {
        get { lock.withLock { _waveformOriginality } }
        set { lock.withLock { _waveformOriginality = newValue } }
    }

    var numberOfWaveformChannels: UInt16 {
        get { lock.withLock { _numberOfWaveformChannels } }
        set { lock.withLock { _numberOfWaveformChannels = newValue } }
    }

    var numberOfWaveformSamples: UInt32 {
        get { lock.withLock { _numberOfWaveformSamples } }
        set { lock.withLock { _numberOfWaveformSamples = newValue } }
    }

    var samplingFrequency: CGFloat {
        get { lock.withLock { _samplingFrequency } }
        set { lock.withLock { _samplingFrequency = newValue } }
    }

    var multiplexGroupLabel: String! {
        get { lock.withLock { _multiplexGroupLabel as String? } }
        set { lock.withLock { _multiplexGroupLabel = newValue as NSString? } }
    }

    var channelDefinitions: [Any]! {
        lock.withLock { _channelDefinitions?.copy() as? [Any] }
    }

    var waveformBitsAllocated: UInt16 {
        get { lock.withLock { _waveformBitsAllocated } }
        set { lock.withLock { _waveformBitsAllocated = newValue } }
    }

    var waveformSampleInterpretation: DCMWaveformSampleInterpretation {
        get { lock.withLock { _waveformSampleInterpretation } }
        set { lock.withLock { _waveformSampleInterpretation = newValue } }
    }

    func setWaveformOriginalityCS(_ cs: UnsafeMutablePointer<CChar>!) {
        switch WaveformValue.text(cs) {
        case "ORIGINAL": waveformOriginality = DCMWaveformOriginalityOriginal
        case "DERIVED": waveformOriginality = DCMWaveformOriginalityDerived
        case let other: WaveformValue.raiseInvalid("Waveform Originality", other)
        }
    }

    @objc(newChannelDefinition)
    private func addedChannelDefinition() -> Unmanaged<DCMWaveformChannelDefinition> {
        let definition = DCMWaveformChannelDefinition()
        lock.withLock { _channelDefinitions?.add(definition) }
        return WaveformValue.keptByItsParent(definition)
    }

    func setWaveformSampleInterpretationCS(_ cs: UnsafeMutablePointer<CChar>!) {
        switch WaveformValue.text(cs) {
        case "SB": waveformSampleInterpretation = DCMWaveformSampleInterpretationSB
        case "UB": waveformSampleInterpretation = DCMWaveformSampleInterpretationUB
        case "MB": waveformSampleInterpretation = DCMWaveformSampleInterpretationMB
        case "AB": waveformSampleInterpretation = DCMWaveformSampleInterpretationAB
        case "SS": waveformSampleInterpretation = DCMWaveformSampleInterpretationSS
        case "US": waveformSampleInterpretation = DCMWaveformSampleInterpretationUS
        case let other: WaveformValue.raiseInvalid("Waveform Sample Interpretation", other)
        }
    }

    func setWaveformPaddingValue(_ data: UnsafeMutableRawPointer!, length: Int) {
        let bytes = WaveformValue.bytes(data, length)
        lock.withLock { _waveformPaddingValue = bytes }
    }

    func setWaveformData(_ data: UnsafeMutableRawPointer!, length: Int) {
        let bytes = WaveformValue.bytes(data, length)
        lock.withLock { _waveformData = bytes }
    }

    /// The samples as numbers and how many they are. Computed once and kept,
    /// as the SDK's were: the samples set after that are not read again.
    func getValues(_ numberOfValues: UnsafeMutablePointer<UInt>!) -> UnsafeMutablePointer<CGFloat>! {
        let numbers: NSMutableData? = lock.withLock {
            if _buffer == nil, let converted = WaveformSamples.numbers(
                interpretation: _waveformSampleInterpretation, bitsAllocated: _waveformBitsAllocated,
                channels: _numberOfWaveformChannels, samples: _numberOfWaveformSamples, data: _waveformData) {
                _buffer = converted.numbers
                // Each channel's definition learns the range of its values;
                // a channel with no definition has nobody to tell.
                for (definition, range) in zip(_channelDefinitions as? [DCMWaveformChannelDefinition] ?? [], converted.ranges) {
                    definition.setValuesMin(range.least, max: range.greatest)
                }
            }
            return _buffer
        }
        guard let numbers else { return nil }
        numberOfValues?.pointee = UInt(numbers.length / MemoryLayout<CGFloat>.size)
        return numbers.mutableBytes.assumingMemoryBound(to: CGFloat.self)
    }
}

/// The samples of a multiplex group as numbers: the conversion the SDK's
/// -getValues: made, one number for each sample of each channel in the order
/// of the file, with the least and the greatest of each channel.
private enum WaveformSamples {
    typealias Range = (least: CGFloat, greatest: CGFloat)

    static func numbers(interpretation: DCMWaveformSampleInterpretation, bitsAllocated: UInt16, channels: UInt16, samples: UInt32,
                        data: NSData?) -> (numbers: NSMutableData, ranges: [Range])? {
        let bytesPerSample = Int(bitsAllocated) / 8
        let channels = Int(channels)
        let count = channels * Int(samples)
        let data = (data as Data?) ?? Data()

        // The data has one sample of that many bytes for each channel at each
        // time, and nothing more.
        guard count * bytesPerSample == data.count else { return nil }
        // A sample narrower than its interpretation reads would be read past
        // the end of the data.
        let sixteenBit = interpretation == DCMWaveformSampleInterpretationSS || interpretation == DCMWaveformSampleInterpretationUS
        guard count == 0 || bytesPerSample >= (sixteenBit ? 2 : 1) else { return nil }
        guard let numbers = NSMutableData(length: count * MemoryLayout<CGFloat>.size) else { return nil }

        var ranges = [Range](repeating: (0, 0), count: channels)
        let output = numbers.mutableBytes.assumingMemoryBound(to: CGFloat.self)
        data.withUnsafeBytes { (samples: UnsafeRawBufferPointer) in
            for index in 0 ..< count {
                let at = index * bytesPerSample
                let number: CGFloat
                switch interpretation {
                case DCMWaveformSampleInterpretationSB: // signed 8bit linear
                    number = CGFloat(samples.load(fromByteOffset: at, as: Int8.self))
                case DCMWaveformSampleInterpretationUB: // unsigned 8bit linear
                    number = CGFloat(samples[at])
                case DCMWaveformSampleInterpretationMB: // 8bit mu-law
                    number = CGFloat(muLawToLinear[Int(samples[at])])
                case DCMWaveformSampleInterpretationAB: // 8bit A-law
                    number = CGFloat(aLawToLinear[Int(samples[at])])
                case DCMWaveformSampleInterpretationSS: // 16bit signed
                    number = CGFloat(samples.loadUnaligned(fromByteOffset: at, as: Int16.self))
                case DCMWaveformSampleInterpretationUS: // 16bit unsigned
                    number = CGFloat(samples.loadUnaligned(fromByteOffset: at, as: UInt16.self))
                default:
                    number = 0
                }
                output[index] = number

                let channel = index % channels
                if index < channels {
                    ranges[channel] = (number, number)
                } else {
                    ranges[channel] = (min(ranges[channel].least, number), max(ranges[channel].greatest, number))
                }
            }
        }
        return (numbers, ranges)
    }

    private static let muLawToLinear: [Int16] = [
        -32124, -31100, -30076, -29052, -28028, -27004, -25980, -24956, -23932, -22908, -21884, -20860, -19836,
        -18812, -17788, -16764, -15996, -15484, -14972, -14460, -13948, -13436, -12924, -12412, -11900, -11388,
        -10876, -10364, -9852, -9340, -8828, -8316, -7932, -7676, -7420, -7164, -6908, -6652, -6396, -6140, -5884,
        -5628, -5372, -5116, -4860, -4604, -4348, -4092, -3900, -3772, -3644, -3516, -3388, -3260, -3132, -3004,
        -2876, -2748, -2620, -2492, -2364, -2236, -2108, -1980, -1884, -1820, -1756, -1692, -1628, -1564, -1500,
        -1436, -1372, -1308, -1244, -1180, -1116, -1052, -988, -924, -876, -844, -812, -780, -748, -716, -684, -652,
        -620, -588, -556, -524, -492, -460, -428, -396, -372, -356, -340, -324, -308, -292, -276, -260, -244, -228,
        -212, -196, -180, -164, -148, -132, -120, -112, -104, -96, -88, -80, -72, -64, -56, -48, -40, -32, -24, -16,
        -8, 0, 32124, 31100, 30076, 29052, 28028, 27004, 25980, 24956, 23932, 22908, 21884, 20860, 19836, 18812,
        17788, 16764, 15996, 15484, 14972, 14460, 13948, 13436, 12924, 12412, 11900, 11388, 10876, 10364, 9852,
        9340, 8828, 8316, 7932, 7676, 7420, 7164, 6908, 6652, 6396, 6140, 5884, 5628, 5372, 5116, 4860, 4604, 4348,
        4092, 3900, 3772, 3644, 3516, 3388, 3260, 3132, 3004, 2876, 2748, 2620, 2492, 2364, 2236, 2108, 1980, 1884,
        1820, 1756, 1692, 1628, 1564, 1500, 1436, 1372, 1308, 1244, 1180, 1116, 1052, 988, 924, 876, 844, 812, 780,
        748, 716, 684, 652, 620, 588, 556, 524, 492, 460, 428, 396, 372, 356, 340, 324, 308, 292, 276, 260, 244,
        228, 212, 196, 180, 164, 148, 132, 120, 112, 104, 96, 88, 80, 72, 64, 56, 48, 40, 32, 24, 16, 8, 0
    ]

    private static let aLawToLinear: [Int16] = [
        -5504, -5248, -6016, -5760, -4480, -4224, -4992, -4736, -7552, -7296, -8064, -7808, -6528, -6272, -7040,
        -6784, -2752, -2624, -3008, -2880, -2240, -2112, -2496, -2368, -3776, -3648, -4032, -3904, -3264, -3136,
        -3520, -3392, -22016, -20992, -24064, -23040, -17920, -16896, -19968, -18944, -30208, -29184, -32256,
        -31232, -26112, -25088, -28160, -27136, -11008, -10496, -12032, -11520, -8960, -8448, -9984, -9472, -15104,
        -14592, -16128, -15616, -13056, -12544, -14080, -13568, -344, -328, -376, -360, -280, -264, -312, -296,
        -472, -456, -504, -488, -408, -392, -440, -424, -88, -72, -120, -104, -24, -8, -56, -40, -216, -200, -248,
        -232, -152, -136, -184, -168, -1376, -1312, -1504, -1440, -1120, -1056, -1248, -1184, -1888, -1824, -2016,
        -1952, -1632, -1568, -1760, -1696, -688, -656, -752, -720, -560, -528, -624, -592, -944, -912, -1008, -976,
        -816, -784, -880, -848, 5504, 5248, 6016, 5760, 4480, 4224, 4992, 4736, 7552, 7296, 8064, 7808, 6528, 6272,
        7040, 6784, 2752, 2624, 3008, 2880, 2240, 2112, 2496, 2368, 3776, 3648, 4032, 3904, 3264, 3136, 3520, 3392,
        22016, 20992, 24064, 23040, 17920, 16896, 19968, 18944, 30208, 29184, 32256, 31232, 26112, 25088, 28160,
        27136, 11008, 10496, 12032, 11520, 8960, 8448, 9984, 9472, 15104, 14592, 16128, 15616, 13056, 12544, 14080,
        13568, 344, 328, 376, 360, 280, 264, 312, 296, 472, 456, 504, 488, 408, 392, 440, 424, 88, 72, 120, 104, 24,
        8, 56, 40, 216, 200, 248, 232, 152, 136, 184, 168, 1376, 1312, 1504, 1440, 1120, 1056, 1248, 1184, 1888,
        1824, 2016, 1952, 1632, 1568, 1760, 1696, 688, 656, 752, 720, 560, 528, 624, 592, 944, 912, 1008, 976, 816,
        784, 880, 848
    ]
}

// MARK: - DCMWaveformChannelDefinition

@objc @implementation extension DCMWaveformChannelDefinition {
    final var _waveformChannelNumber: Int = 0
    final var _channelLabel: NSString?
    final var _channelStatus: DCMWaveformChannelStatus = DCMWaveformChannelStatusOk
    final var _channelSource: DCMWaveformChannelSource?
    final var _channelSourceModifiers: NSMutableArray? = NSMutableArray(), _sourceWaveforms: NSMutableArray? = NSMutableArray()
    final var _channelDerivationDescription: NSString?
    final var _channelSensitivity: CGFloat = 0
    final var _channelSensitivityUnit: DCMWaveformChannelSensitivityUnit?
    final var _channelSensitivityCorrectionFactor: CGFloat = 0, _channelBaseline: CGFloat = 0, _channelTimeSkew: CGFloat = 0
    final var _channelSampleSkew: CGFloat = 0, _channelOffset: CGFloat = 0
    final var _waveformBitsStored: UInt16 = 0
    final var _filterLowFrequency: CGFloat = 0, _filterHighFrequency: CGFloat = 0
    final var _notchFilterFrequency: CGFloat = 0, _notchFilterBandwidth: CGFloat = 0
    final var _channelMinimumValue: NSData?, _channelMaximumValue: NSData?
    /// The least and the greatest of the channel's values.
    final var _min: CGFloat = 0, _max: CGFloat = 0
    private final let lock = NSLock()

    var waveformChannelNumber: Int {
        get { lock.withLock { _waveformChannelNumber } }
        set { lock.withLock { _waveformChannelNumber = newValue } }
    }

    var channelLabel: String! {
        get { lock.withLock { _channelLabel as String? } }
        set { lock.withLock { _channelLabel = newValue as NSString? } }
    }

    var channelStatus: DCMWaveformChannelStatus {
        get { lock.withLock { _channelStatus } }
        set { lock.withLock { _channelStatus = newValue } }
    }

    var channelSource: DCMWaveformChannelSource! {
        lock.withLock { _channelSource }
    }

    var channelSourceModifiers: [Any]! {
        lock.withLock { _channelSourceModifiers?.copy() as? [Any] }
    }

    var sourceWaveforms: [Any]! {
        lock.withLock { _sourceWaveforms?.copy() as? [Any] }
    }

    var channelDerivationDescription: String! {
        get { lock.withLock { _channelDerivationDescription as String? } }
        set { lock.withLock { _channelDerivationDescription = newValue as NSString? } }
    }

    var channelSensitivity: CGFloat {
        get { lock.withLock { _channelSensitivity } }
        set { lock.withLock { _channelSensitivity = newValue } }
    }

    var channelSensitivityUnit: DCMWaveformChannelSensitivityUnit! {
        lock.withLock { _channelSensitivityUnit }
    }

    var channelSensitivityCorrectionFactor: CGFloat {
        get { lock.withLock { _channelSensitivityCorrectionFactor } }
        set { lock.withLock { _channelSensitivityCorrectionFactor = newValue } }
    }

    var channelBaseline: CGFloat {
        get { lock.withLock { _channelBaseline } }
        set { lock.withLock { _channelBaseline = newValue } }
    }

    var channelTimeSkew: CGFloat {
        get { lock.withLock { _channelTimeSkew } }
        set { lock.withLock { _channelTimeSkew = newValue } }
    }

    var channelSampleSkew: CGFloat {
        get { lock.withLock { _channelSampleSkew } }
        set { lock.withLock { _channelSampleSkew = newValue } }
    }

    var channelOffset: CGFloat {
        get { lock.withLock { _channelOffset } }
        set { lock.withLock { _channelOffset = newValue } }
    }

    var waveformBitsStored: UInt16 {
        get { lock.withLock { _waveformBitsStored } }
        set { lock.withLock { _waveformBitsStored = newValue } }
    }

    var filterLowFrequency: CGFloat {
        get { lock.withLock { _filterLowFrequency } }
        set { lock.withLock { _filterLowFrequency = newValue } }
    }

    var filterHighFrequency: CGFloat {
        get { lock.withLock { _filterHighFrequency } }
        set { lock.withLock { _filterHighFrequency = newValue } }
    }

    var notchFilterFrequency: CGFloat {
        get { lock.withLock { _notchFilterFrequency } }
        set { lock.withLock { _notchFilterFrequency = newValue } }
    }

    var notchFilterBandwidth: CGFloat {
        get { lock.withLock { _notchFilterBandwidth } }
        set { lock.withLock { _notchFilterBandwidth = newValue } }
    }

    func setChannelStatusCS(_ cs: UnsafeMutablePointer<CChar>!) {
        switch WaveformValue.text(cs) {
        case "OK": channelStatus = DCMWaveformChannelStatusOk
        case "TEST DATA": channelStatus = DCMWaveformChannelStatusTestData
        case "DISCONNECTED": channelStatus = DCMWaveformChannelStatusDisconnected
        case "QUESTIONABLE": channelStatus = DCMWaveformChannelStatusQuestionable
        case "INVALID": channelStatus = DCMWaveformChannelStatusInvalid
        case "UNCALIBRATED": channelStatus = DCMWaveformChannelStatusUncalibrated
        case "UNZEROED": channelStatus = DCMWaveformChannelStatusUnzeroed
        case let other: WaveformValue.raiseInvalid("Channel Status", other)
        }
    }

    func setChannelMinimumValue(_ data: UnsafeMutableRawPointer!, length: Int) {
        let bytes = WaveformValue.bytes(data, length)
        lock.withLock { _channelMinimumValue = bytes }
    }

    func setChannelMaximumValue(_ data: UnsafeMutableRawPointer!, length: Int) {
        let bytes = WaveformValue.bytes(data, length)
        lock.withLock { _channelMaximumValue = bytes }
    }

    @objc(newChannelSource)
    private func addedChannelSource() -> Unmanaged<DCMWaveformChannelSource> {
        let source = DCMWaveformChannelSource()
        let free = lock.withLock {
            if _channelSource == nil { _channelSource = source }
            return _channelSource === source
        }
        if !free {
            NSException(name: .genericException,
                        reason: "Waveform Channel Definition Sequence can only contain one Channel Source Sequence item",
                        userInfo: nil).raise()
        }
        return WaveformValue.keptByItsParent(source)
    }

    @objc(newChannelSourceModifier)
    private func addedChannelSourceModifier() -> Unmanaged<DCMWaveformChannelSourceModifier> {
        let modifier = DCMWaveformChannelSourceModifier()
        lock.withLock { _channelSourceModifiers?.add(modifier) }
        return WaveformValue.keptByItsParent(modifier)
    }

    @objc(newSourceWaveform)
    private func addedSourceWaveform() -> Unmanaged<DCMWaveformSourceWaveform> {
        let waveform = DCMWaveformSourceWaveform()
        lock.withLock { _sourceWaveforms?.add(waveform) }
        return WaveformValue.keptByItsParent(waveform)
    }

    @objc(newChannelSensitivityUnit)
    private func addedChannelSensitivityUnit() -> Unmanaged<DCMWaveformChannelSensitivityUnit> {
        let unit = DCMWaveformChannelSensitivityUnit()
        let free = lock.withLock {
            if _channelSensitivityUnit == nil { _channelSensitivityUnit = unit }
            return _channelSensitivityUnit === unit
        }
        if !free {
            NSException(name: .genericException,
                        reason: "Waveform Channel Definition Sequence can only contain one Channel Sensitivity Units Sequence item",
                        userInfo: nil).raise()
        }
        return WaveformValue.keptByItsParent(unit)
    }

    func getValuesMin(_ min: UnsafeMutablePointer<CGFloat>!, max: UnsafeMutablePointer<CGFloat>!) {
        let (least, greatest) = lock.withLock { (_min, _max) }
        min?.pointee = least
        max?.pointee = greatest
    }

    func setValuesMin(_ min: CGFloat, max: CGFloat) {
        lock.withLock {
            _min = min
            _max = max
        }
    }
}

// MARK: - The macros

@objc @implementation extension DCMCodeSequenceMacro {
    final var _codeValue: NSString?, _codingSchemeDesignator: NSString?, _codingSchemeVersion: NSString?, _codeMeaning: NSString?
    final var _contextIdentifier: NSString?, _contextUID: NSString?
    final var _mappingResource: DCMMappingResource = DCMMappingResourceDCMR
    final var _contextGroupVersion: NSDate?
    final var _contextGroupExtensionFlag: DCMContextGroupExtensionFlag = DCMContextGroupExtensionFlagY
    final var _contextGroupLocalVersion: NSDate?
    final var _contextGroupExtensionCreatorUID: NSString?
    private final let lock = NSLock()

    var codeValue: String! {
        get { lock.withLock { _codeValue as String? } }
        set { lock.withLock { _codeValue = newValue as NSString? } }
    }

    var codingSchemeDesignator: String! {
        get { lock.withLock { _codingSchemeDesignator as String? } }
        set { lock.withLock { _codingSchemeDesignator = newValue as NSString? } }
    }

    var codingSchemeVersion: String! {
        get { lock.withLock { _codingSchemeVersion as String? } }
        set { lock.withLock { _codingSchemeVersion = newValue as NSString? } }
    }

    var codeMeaning: String! {
        get { lock.withLock { _codeMeaning as String? } }
        set { lock.withLock { _codeMeaning = newValue as NSString? } }
    }

    var contextIdentifier: String! {
        get { lock.withLock { _contextIdentifier as String? } }
        set { lock.withLock { _contextIdentifier = newValue as NSString? } }
    }

    var contextUID: String! {
        get { lock.withLock { _contextUID as String? } }
        set { lock.withLock { _contextUID = newValue as NSString? } }
    }

    var mappingResource: DCMMappingResource {
        get { lock.withLock { _mappingResource } }
        set { lock.withLock { _mappingResource = newValue } }
    }

    var contextGroupVersion: Date! {
        get { lock.withLock { _contextGroupVersion as Date? } }
        set { lock.withLock { _contextGroupVersion = newValue as NSDate? } }
    }

    var contextGroupExtensionFlag: DCMContextGroupExtensionFlag {
        get { lock.withLock { _contextGroupExtensionFlag } }
        set { lock.withLock { _contextGroupExtensionFlag = newValue } }
    }

    var contextGroupLocalVersion: Date! {
        get { lock.withLock { _contextGroupLocalVersion as Date? } }
        set { lock.withLock { _contextGroupLocalVersion = newValue as NSDate? } }
    }

    var contextGroupExtensionCreatorUID: String! {
        get { lock.withLock { _contextGroupExtensionCreatorUID as String? } }
        set { lock.withLock { _contextGroupExtensionCreatorUID = newValue as NSString? } }
    }

    func setMappingResourceCS(_ cs: UnsafeMutablePointer<CChar>!) {
        switch WaveformValue.text(cs) {
        case "DCMR": mappingResource = DCMMappingResourceDCMR
        case "SDM": mappingResource = DCMMappingResourceSDM
        case let other: WaveformValue.raiseInvalid("Mapping Resource", other)
        }
    }

    func setContextGroupExtensionFlagCS(_ cs: UnsafeMutablePointer<CChar>!) {
        switch WaveformValue.text(cs) {
        case "Y": contextGroupExtensionFlag = DCMContextGroupExtensionFlagY
        case "N": contextGroupExtensionFlag = DCMContextGroupExtensionFlagN
        case let other: WaveformValue.raiseInvalid("Context Group Extension Flag", other)
        }
    }
}

@objc @implementation extension DCMSOPInstanceReferenceMacro {
    final var _referencedSOPClassUID: NSString?, _referencedSOPInstanceUID: NSString?
    private final let lock = NSLock()

    var referencedSOPClassUID: String! {
        get { lock.withLock { _referencedSOPClassUID as String? } }
        set { lock.withLock { _referencedSOPClassUID = newValue as NSString? } }
    }

    var referencedSOPInstanceUID: String! {
        get { lock.withLock { _referencedSOPInstanceUID as String? } }
        set { lock.withLock { _referencedSOPInstanceUID = newValue as NSString? } }
    }
}

// MARK: - The items of a channel definition

@objc @implementation extension DCMWaveformChannelSource {
    override init() {
        super.init()
    }
}

@objc @implementation extension DCMWaveformChannelSourceModifier {
    override init() {
        super.init()
    }
}

@objc @implementation extension DCMWaveformSourceWaveform {
    final var _referencedWaveformChannels: UInt16 = 0
    private final let lock = NSLock()

    override init() {
        super.init()
    }

    var referencedWaveformChannels: UInt16 {
        get { lock.withLock { _referencedWaveformChannels } }
        set { lock.withLock { _referencedWaveformChannels = newValue } }
    }
}

@objc @implementation extension DCMWaveformChannelSensitivityUnit {
    override init() {
        super.init()
    }
}
