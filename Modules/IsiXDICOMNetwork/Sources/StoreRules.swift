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

/// The transfer syntaxes the send and the move sub-operations name.
public enum TransferSyntaxUID {
    public static let implicitLittleEndian = "1.2.840.10008.1.2"
    public static let explicitLittleEndian = "1.2.840.10008.1.2.1"
    public static let deflatedExplicitLittleEndian = "1.2.840.10008.1.2.1.99"
    public static let explicitBigEndian = "1.2.840.10008.1.2.2"
    /// JPEG Baseline (Process 1).
    public static let jpegBaseline = "1.2.840.10008.1.2.4.50"
    /// JPEG Extended (Process 2 & 4).
    public static let jpegExtended = "1.2.840.10008.1.2.4.51"
    /// JPEG Lossless, Non-Hierarchical, First-Order Prediction (Process 14, selection value 1).
    public static let jpegLossless = "1.2.840.10008.1.2.4.70"
    public static let jpegLSLossless = "1.2.840.10008.1.2.4.80"
    public static let jpegLSLossy = "1.2.840.10008.1.2.4.81"
    public static let jpeg2000Lossless = "1.2.840.10008.1.2.4.90"
    public static let jpeg2000 = "1.2.840.10008.1.2.4.91"
    public static let rleLossless = "1.2.840.10008.1.2.5"
}

/// The transfer syntax a send proposes, and the image quality its encoder is
/// given (the DCM_CompressionQuality value for JPEG 2000 and JPEG-LS, 0
/// lossless; the JPEG quality otherwise).
public struct StoreNetworkSyntax: Equatable, Sendable {
    public let transferSyntax: String
    public let quality: Int

    public init(transferSyntax: String, quality: Int) {
        self.transferSyntax = transferSyntax
        self.quality = quality
    }
}

/// The transfer syntax settings of the Send sheet and of Locations
/// (TransferSyntaxCodes: SendExplicitLittleEndian = 0 … SendJPEGLSLossy50 = 16).
public enum StoreSendSyntax {
    /// What a send with the setting `code` proposes; an unknown code sends
    /// Explicit VR Little Endian.
    public static func network(forSetting code: Int) -> StoreNetworkSyntax {
        typealias UID = TransferSyntaxUID
        // The encoders' quality when the setting names none.
        let standard = 90
        switch code {
        case 1: return StoreNetworkSyntax(transferSyntax: UID.jpeg2000Lossless, quality: 0)
        case 2: return StoreNetworkSyntax(transferSyntax: UID.jpeg2000, quality: 1)
        case 3: return StoreNetworkSyntax(transferSyntax: UID.jpeg2000, quality: 2)
        case 4: return StoreNetworkSyntax(transferSyntax: UID.jpeg2000, quality: 3)
        case 13: return StoreNetworkSyntax(transferSyntax: UID.jpegLSLossless, quality: 0)
        case 14: return StoreNetworkSyntax(transferSyntax: UID.jpegLSLossy, quality: 1)
        case 15: return StoreNetworkSyntax(transferSyntax: UID.jpegLSLossy, quality: 2)
        case 16: return StoreNetworkSyntax(transferSyntax: UID.jpegLSLossy, quality: 3)
        case 5: return StoreNetworkSyntax(transferSyntax: UID.jpegLossless, quality: standard)
        case 6: return StoreNetworkSyntax(transferSyntax: UID.jpegExtended, quality: 90)
        case 7: return StoreNetworkSyntax(transferSyntax: UID.jpegExtended, quality: 80)
        case 8: return StoreNetworkSyntax(transferSyntax: UID.jpegExtended, quality: 70)
        case 9: return StoreNetworkSyntax(transferSyntax: UID.implicitLittleEndian, quality: standard)
        case 10: return StoreNetworkSyntax(transferSyntax: UID.rleLossless, quality: standard)
        case 11: return StoreNetworkSyntax(transferSyntax: UID.explicitBigEndian, quality: standard)
        case 12: return StoreNetworkSyntax(transferSyntax: UID.deflatedExplicitLittleEndian, quality: standard)
        default: return StoreNetworkSyntax(transferSyntax: UID.explicitLittleEndian, quality: standard)
        }
    }

    /// The send setting that matches the listener's preferred syntax for
    /// incoming images (`uid`, "" for one DCMTK does not name): what the
    /// Bonjour and remote-database sends to this application use.
    public static func setting(forListenerTransferSyntax uid: String) -> Int {
        typealias UID = TransferSyntaxUID
        switch uid {
        case UID.jpeg2000, UID.jpeg2000Lossless: return 1
        case UID.jpegLossless, UID.jpegBaseline, UID.jpegExtended: return 5
        case UID.rleLossless: return 10
        case UID.implicitLittleEndian: return 9
        case UID.jpegLSLossless, UID.jpegLSLossy: return 13
        default: return 0
        }
    }
}

/// One presentation context a send proposes: an odd identifier, a storage
/// SOP class and the transfer syntaxes offered for it, in order of preference.
public struct StoragePresentationContext: Equatable, Sendable {
    public let identifier: Int
    public let abstractSyntax: String
    public let transferSyntaxes: [String]

    public init(identifier: Int, abstractSyntax: String, transferSyntaxes: [String]) {
        self.identifier = identifier
        self.abstractSyntax = abstractSyntax
        self.transferSyntaxes = transferSyntaxes
    }
}

/// The presentation contexts a send asks the peer for.
///
/// Each SOP class is proposed in two presentation contexts: one with the
/// preferred transfer syntax, one with the fallbacks (the uncompressed
/// syntaxes other than it), unless the syntaxes are combined into one context.
/// Implicit VR Little Endian, which every application must accept, needs no
/// fallback. Some SCP implementations take the first transfer syntax they
/// support, so the order matters.
///
/// The SOP classes of the files being sent come first, each once: DCMTK's
/// short list of storage classes does not hold every one (Segmentation, for
/// one), and optional classes must not use the association's 128 contexts
/// before the batch is represented. More than 64 classes with fallbacks are
/// combined so that up to 128 fit; more than that is refused before the
/// association is asked for.
public enum StoragePresentationPlan {
    public enum Failure: Error, Equatable, Sendable {
        /// The files hold more SOP classes than one association can propose.
        case tooManyRequiredContexts
        /// The identifiers ran past 255.
        case tooManyContexts
    }

    /// The contexts for the files' SOP classes `required` (in the order of the
    /// files, repeats allowed), followed, unless `proposeOnlyRequired`, by the
    /// classes of `optional` that still fit.
    public static func contexts(preferredTransferSyntax preferred: String, required: [String], optional: [String],
                                proposeOnlyRequired: Bool = false,
                                combineTransferSyntaxes: Bool = false) -> Result<[StoragePresentationContext], Failure> {
        typealias UID = TransferSyntaxUID
        var fallback = [UID.explicitLittleEndian, UID.explicitBigEndian, UID.implicitLittleEndian].filter { $0 != preferred }
        if preferred == UID.implicitLittleEndian { fallback.removeAll() }
        var combined = [preferred]
        for syntax in fallback where !combined.contains(syntax) { combined.append(syntax) }

        var classes: [String] = []
        for sopClass in required where !classes.contains(sopClass) { classes.append(sopClass) }
        let combine = combineTransferSyntaxes || (!fallback.isEmpty && classes.count > 64)
        let maximum = (combine || fallback.isEmpty) ? 128 : 64
        if classes.count > maximum { return .failure(.tooManyRequiredContexts) }
        if !proposeOnlyRequired {
            for sopClass in optional where classes.count < maximum && !classes.contains(sopClass) { classes.append(sopClass) }
        }

        var contexts: [StoragePresentationContext] = []
        var identifier = 1  // only odd presentation context identifiers
        for sopClass in classes {
            if identifier > 255 { return .failure(.tooManyContexts) }
            if combine {
                contexts.append(StoragePresentationContext(identifier: identifier, abstractSyntax: sopClass, transferSyntaxes: combined))
                identifier += 2
            } else {
                contexts.append(StoragePresentationContext(identifier: identifier, abstractSyntax: sopClass, transferSyntaxes: [preferred]))
                identifier += 2
                if !fallback.isEmpty {
                    if identifier > 255 { return .failure(.tooManyContexts) }
                    contexts.append(StoragePresentationContext(identifier: identifier, abstractSyntax: sopClass, transferSyntaxes: fallback))
                    identifier += 2
                }
            }
        }
        return .success(contexts)
    }
}

/// How the pixel data of a transfer syntax is held.
public struct TransferSyntaxTraits: Equatable, Sendable {
    /// Not encapsulated: the pixel data is in the dataset as is (deflated or not).
    public let native: Bool
    public let encapsulated: Bool
    public let pixelDataCompressed: Bool

    public init(native: Bool, encapsulated: Bool, pixelDataCompressed: Bool) {
        self.native = native
        self.encapsulated = encapsulated
        self.pixelDataCompressed = pixelDataCompressed
    }
}

/// What a file is turned into before it goes out in the accepted syntax.
public enum StoreConversion: Equatable, Sendable {
    /// Sent as it is.
    case none
    /// Compressed pixel data, an uncompressed syntax accepted: written in
    /// Explicit VR Little Endian.
    case decompress
    /// Written in the send's syntax. `warns` when a compressed file is
    /// compressed again in another family of syntaxes (the log says so).
    case compress(warns: Bool)

    /// The conversion of a file in `fileSyntax` for the send's syntax
    /// `networkSyntax`, given the syntax the peer accepted for it in the
    /// send's syntax (nil when it accepted none).
    ///
    /// A deflated send counts an uncompressed file as deflated, so that it
    /// looks for a context in Deflated Explicit VR Little Endian first; the
    /// caller passes the file's syntax and traits adjusted that way.
    public static func of(fileSyntax: String, file: TransferSyntaxTraits, accepted: TransferSyntaxTraits?,
                          networkSyntax: String) -> StoreConversion {
        typealias UID = TransferSyntaxUID
        guard let accepted else { return .none }
        if file.native && accepted.native { return .none }
        if file.encapsulated && file.pixelDataCompressed && accepted.native { return .decompress }
        if file.native && accepted.encapsulated && accepted.pixelDataCompressed { return .compress(warns: false) }
        if fileSyntax == networkSyntax { return .none }
        // A lossless and a lossy syntax of the same family are not worth a word.
        let sameFamily: Set<Set<String>> = [[UID.jpeg2000Lossless, UID.jpeg2000], [UID.jpegLSLossless, UID.jpegLSLossy]]
        return .compress(warns: !sameFamily.contains([fileSyntax, networkSyntax]))
    }
}

/// The transfer syntaxes the move sub-operations of the listener's C-MOVE
/// offer the destination, for every storage SOP class.
public enum MoveSubOperationSyntaxes {
    /// `withoutJPEG`: the DontSupportJPEGForCSMove preference.
    public static func proposed(withoutJPEG: Bool) -> [String] {
        typealias UID = TransferSyntaxUID
        let uncompressed = [UID.explicitLittleEndian, UID.explicitBigEndian, UID.implicitLittleEndian]
        if withoutJPEG { return uncompressed + [UID.jpeg2000, UID.jpeg2000Lossless] }
        return uncompressed + [UID.jpegLossless, UID.jpegBaseline, UID.jpegExtended, UID.jpeg2000, UID.jpeg2000Lossless, UID.rleLossless]
    }
}
