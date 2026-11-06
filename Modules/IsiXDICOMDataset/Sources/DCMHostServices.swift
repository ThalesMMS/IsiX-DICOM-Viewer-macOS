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

// The dataset model parses, writes and decodes nothing itself. The application
// and the Decompress helper provide those services on DCMTK, in their DCMTK
// adapter, and the model finds the adapter's classes by name at run time: no
// module may link the adapters. A process without them (a test that builds
// the module alone) reads and writes nothing.

/// Reads a file or a byte stream into a DCMObject (the adapter's
/// HorosDCMTKObject).
@objc(IsiXDCMReading)
public protocol DCMReading: NSObjectProtocol {
    /// Stops after group `lastGroup` (0xFFFF reads everything).
    @objc(objectWithContentsOfFile:decodingPixelData:lastGroup:)
    static func object(contentsOfFile path: String, decodingPixelData: Bool, lastGroup: UInt16) -> DCMObject?

    /// A bare dataset when `transferSyntax` is given, a Part 10 stream otherwise.
    @objc(objectWithData:transferSyntax:decodingPixelData:lastGroup:)
    static func object(data: Data, transferSyntax: String?, decodingPixelData: Bool, lastGroup: UInt16) -> DCMObject?
}

/// Writes a DCMObject and changes the encoding of its pixel data (the
/// adapter's IsiXDCMTKObjectWriter). `quality` is a DCMCompressionQuality.
@objc(IsiXDCMWriting)
public protocol DCMWriting: NSObjectProtocol {
    /// A file with meta header; nil `transferSyntax` keeps the object's own.
    @objc(writeObject:toFile:transferSyntax:quality:AET:)
    static func write(_ object: DCMObject, toFile path: String, transferSyntax: String?, quality: Int32,
                      aet: String?) -> Bool

    /// The dataset alone, as it is sent over the network.
    @objc(datasetOfObject:transferSyntax:quality:)
    static func dataset(of object: DCMObject, transferSyntax: String?, quality: Int32) -> Data?

    /// The object with its pixel data in another syntax, read back as a new object.
    @objc(objectByConvertingObject:toTransferSyntax:quality:)
    static func object(byConverting object: DCMObject, toTransferSyntax transferSyntax: String,
                       quality: Int32) -> DCMObject?
}

/// Where the frames of a Pixel Data value come from while they are still the
/// stored ones: the reader that parsed the file (the DCMTK adapter) keeps the
/// file and decodes a frame on request. The attribute owns its source and
/// does the rest itself: host byte order, interleaving and the conversion of
/// YBR and palette colour to RGB.
@objc(IsiXDCMPixelFrameSource)
public protocol DCMPixelFrameSource: NSObjectProtocol {
    /// The frame `index` of `attribute` as the codec gives it, or nil when it
    /// cannot be decoded. `colourModel` is the photometric interpretation the
    /// codec decoded into (empty when it decoded nothing or kept the stored
    /// one); `interleaved` is YES when the codec delivers interleaved samples
    /// whatever Planar Configuration says.
    @objc(frameAtIndex:ofAttribute:colourModel:interleaved:)
    func frame(at index: Int32, of attribute: DCMPixelDataAttribute,
               colourModel: AutoreleasingUnsafeMutablePointer<NSString?>,
               interleaved: UnsafeMutablePointer<ObjCBool>) -> Data?
}

enum DCMHost {
    static var reader: DCMReading.Type? {
        if let reader = NSClassFromString("HorosDCMTKObject") as? DCMReading.Type {
            return reader
        }
        _ = missingReader
        return nil
    }

    static var writer: DCMWriting.Type? {
        if let writer = writerClass {
            return writer
        }
        _ = missingWriter
        return nil
    }

    /// The writer, as the pixel data's codec.
    static var codec: DCMWriting.Type? {
        if let writer = writerClass {
            return writer
        }
        _ = missingCodec
        return nil
    }

    private static var writerClass: DCMWriting.Type? {
        NSClassFromString("IsiXDCMTKObjectWriter") as? DCMWriting.Type
    }

    /// The properties of a transfer syntax as DCMTK knows them (the adapter's
    /// HorosDICOMTransferSyntaxes +propertiesForTransferSyntax:):
    /// isEncapsulated, isLittleEndian, isExplicit and Name, nil for a UID it
    /// does not know; nil itself where there is no host, which is not the same.
    static func transferSyntaxProperties(_ uid: String) -> [String: Any]?? {
        let selector = NSSelectorFromString("propertiesForTransferSyntax:")
        guard let host = NSClassFromString("HorosDICOMTransferSyntaxes") as? NSObject.Type,
              host.responds(to: selector) else { return nil }
        return .some(host.perform(selector, with: uid)?.takeUnretainedValue() as? [String: Any])
    }

    // Said once per process, as the Objective-C model said it.
    private static let missingReader: Void = {
        NSLog("DCMObject: no DICOM reader in this process; DCMObject reads through the host's DCMTK")
    }()
    private static let missingWriter: Void = {
        NSLog("DCMObject: no DICOM writer in this process; DCMObject writes through the host's DCMTK")
    }()
    private static let missingCodec: Void = {
        NSLog("DCMPixelDataAttribute: no DICOM codec in this process; pixel data converts through the host's DCMTK")
    }()

    /// Runs `body` and returns the Objective-C exception it raised, if any.
    ///
    /// The host's Objective-C code (the adapter, Foundation underneath it) can
    /// raise where the Objective-C model caught with @try/@catch, and Swift
    /// cannot catch an Objective-C exception. The host's HorosObjCException
    /// can; it is found by name, like the other services. Without it `body`
    /// runs unprotected.
    static func catchingObjCException(_ body: () -> Void) -> NSException? {
        guard let catcher: AnyClass = NSClassFromString("HorosObjCException"),
              let method = class_getClassMethod(catcher, performSelector) else {
            body()
            return nil
        }
        typealias Perform = @convention(c) (AnyClass, Selector, @convention(block) () -> Void,
                                            AutoreleasingUnsafeMutablePointer<NSError?>?) -> ObjCBool
        let perform = unsafeBitCast(method_getImplementation(method), to: Perform.self)
        var error: NSError?
        withoutActuallyEscaping(body) { escapable in
            let block: @convention(block) () -> Void = { escapable() }
            _ = perform(catcher, performSelector, block, &error)
        }
        return error?.userInfo["HorosObjCException"] as? NSException
    }

    private static let performSelector = NSSelectorFromString("performBlock:error:")
}
