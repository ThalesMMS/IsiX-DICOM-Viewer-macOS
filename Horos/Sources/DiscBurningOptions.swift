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

import Foundation

/// The options of a disc burn, archivable with the same keys as before.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/DiscBurningOptions.h> are those of the former class. As before, the
/// class adopts NSCopying and answers -encodeWithCoder: and -initWithCoder:
/// without declaring NSCoding.
///
/// The `compression` property is declared and implemented by the Objective-C
/// category of DiscBurningOptions+CAPI.mm, over `compressionValue`: its type
/// is the C enum Compression of DicomCompressor.h, which the generated
/// interface would name before the Objective-C++ files that import it have
/// declared it.
@objc(DiscBurningOptions)
public final class DiscBurningOptions: NSObject, NSCopying {
    @objc public var anonymize: Bool = false
    @objc public var anonymizationTags: NSArray?
    @objc public var includeWeasis: Bool = false
    @objc public var includeOsirixLite: Bool = false
    @objc public var includeHTMLQT: Bool = false
    @objc public var includeReports: Bool = false
    @objc public var includeAuxiliaryDir: Bool = false
    @objc public var auxiliaryDirPath: String?
    /// The enum Compression value of `compression`.
    @objc(compressionValue) var compressionValue: UInt32 = 0
    @objc public var compressJPEGNotJPEG2000: Bool = false
    @objc public var zip: Bool = false
    @objc public var zipEncrypt: Bool = false
    @objc public var zipEncryptPassword: String?

    public override init() {
        super.init()
    }

    @objc(copyWithZone:)
    public func copy(with zone: NSZone? = nil) -> Any {
        let copy = DiscBurningOptions()
        copy.anonymize = anonymize
        copy.anonymizationTags = anonymizationTags?.copy(with: zone) as? NSArray
        copy.includeWeasis = includeWeasis
        copy.includeOsirixLite = includeOsirixLite
        copy.includeHTMLQT = includeHTMLQT
        copy.includeReports = includeReports
        copy.includeAuxiliaryDir = includeAuxiliaryDir
        copy.auxiliaryDirPath = (auxiliaryDirPath as NSString?)?.copy(with: zone) as? String
        copy.compressionValue = compressionValue
        copy.compressJPEGNotJPEG2000 = compressJPEGNotJPEG2000
        copy.zip = zip
        copy.zipEncrypt = zipEncrypt
        copy.zipEncryptPassword = (zipEncryptPassword as NSString?)?.copy(with: zone) as? String

        return copy
    }

    private static let anonymizeArchivingKey = "anonymize"
    private static let anonymizationTagsArchivingKey = "anonymizationTags"
    private static let includeWeasisArchivingKey = "includeWeasis"
    private static let includeOsirixLiteArchivingKey = "includeOsirixLite"
    private static let includeHTMLQTArchivingKey = "includeHTMLQT"
    private static let includeReportsArchivingKey = "includeReports"
    private static let includeAuxiliaryDirArchivingKey = "includeAuxiliaryDir"
    private static let auxiliaryDirPathArchivingKey = "auxiliaryDirPath"
    private static let compressionArchivingKey = "compression"
    private static let compressJPEGNotJPEG2000ArchivingKey = "compressJPEGNotJPEG2000"
    private static let zipArchivingKey = "zip"
    private static let zipEncryptArchivingKey = "zipEncrypt"
    private static let zipEncryptPasswordArchivingKey = "zipEncryptPassword"

    @objc(encodeWithCoder:)
    public func encode(with encoder: NSCoder) {
        let keys = DiscBurningOptions.self
        encoder.encode(anonymize, forKey: keys.anonymizeArchivingKey)
        encoder.encode(anonymizationTags, forKey: keys.anonymizationTagsArchivingKey)
        encoder.encode(includeWeasis, forKey: keys.includeWeasisArchivingKey)
        encoder.encode(includeOsirixLite, forKey: keys.includeOsirixLiteArchivingKey)
        encoder.encode(includeHTMLQT, forKey: keys.includeHTMLQTArchivingKey)
        encoder.encode(includeReports, forKey: keys.includeReportsArchivingKey)
        encoder.encode(includeAuxiliaryDir, forKey: keys.includeAuxiliaryDirArchivingKey)
        encoder.encode(auxiliaryDirPath as NSString?, forKey: keys.auxiliaryDirPathArchivingKey)
        // -encodeInt:forKey:, (int)self.compression.
        encoder.encodeCInt(Int32(bitPattern: compressionValue), forKey: keys.compressionArchivingKey)
        encoder.encode(compressJPEGNotJPEG2000, forKey: keys.compressJPEGNotJPEG2000ArchivingKey)
        encoder.encode(zip, forKey: keys.zipArchivingKey)
        encoder.encode(zipEncrypt, forKey: keys.zipEncryptArchivingKey)
        encoder.encode(zipEncryptPassword as NSString?, forKey: keys.zipEncryptPasswordArchivingKey)
    }

    @objc(initWithCoder:)
    public init(coder decoder: NSCoder) {
        super.init()
        decode(decoder)
    }

    /// The assignments of the former -initWithCoder:, through the setters.
    private func decode(_ decoder: NSCoder) {
        let keys = DiscBurningOptions.self
        anonymize = decoder.decodeBool(forKey: keys.anonymizeArchivingKey)
        anonymizationTags = decoder.decodeObject(forKey: keys.anonymizationTagsArchivingKey) as? NSArray
        includeWeasis = decoder.decodeBool(forKey: keys.includeWeasisArchivingKey)
        includeOsirixLite = decoder.decodeBool(forKey: keys.includeOsirixLiteArchivingKey)
        includeHTMLQT = decoder.decodeBool(forKey: keys.includeHTMLQTArchivingKey)
        includeReports = decoder.decodeBool(forKey: keys.includeReportsArchivingKey)
        includeAuxiliaryDir = decoder.decodeBool(forKey: keys.includeAuxiliaryDirArchivingKey)
        auxiliaryDirPath = decoder.decodeObject(forKey: keys.auxiliaryDirPathArchivingKey) as? String
        // (Compression)[decoder decodeIntForKey:].
        compressionValue = UInt32(bitPattern: decoder.decodeCInt(forKey: keys.compressionArchivingKey))
        compressJPEGNotJPEG2000 = decoder.decodeBool(forKey: keys.compressJPEGNotJPEG2000ArchivingKey)
        zip = decoder.decodeBool(forKey: keys.zipArchivingKey)
        zipEncrypt = decoder.decodeBool(forKey: keys.zipEncryptArchivingKey)
        zipEncryptPassword = decoder.decodeObject(forKey: keys.zipEncryptPasswordArchivingKey) as? String
    }
}
