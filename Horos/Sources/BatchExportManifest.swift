//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation
import IsiXDatabase

/// The export by identifier list's rules under the names Objective-C calls;
/// the rules themselves are IdentifierListExport's (IsiXDatabase).
@objc(HorosBatchExportManifest)
public final class BatchExportManifest: NSObject {
    @objc(identifiersFromText:)
    public static func identifiers(fromText text: String) -> [String] {
        IdentifierListExport.identifiers(fromText: text)
    }

    @objc public static let header = IdentifierListExport.header

    @objc(rowForIdentifier:status:names:studies:files:bytes:digest:detail:)
    public static func row(identifier: String, status: String, names: [String], studies: Int,
                           files: Int, bytes: Int64, digest: String, detail: String) -> [String] {
        IdentifierListExport.row(identifier: identifier, status: status, names: names, studies: studies,
                                 files: files, bytes: bytes, digest: digest, detail: detail)
    }
}

/// IdentifierListExport.FileSetDigest under the name Objective-C calls.
@objc(HorosFileSetDigest)
public final class FileSetDigest: NSObject {
    private var digest = IdentifierListExport.FileSetDigest()

    @objc public var fileCount: Int { digest.fileCount }
    @objc public var byteCount: Int64 { digest.byteCount }
    @objc public var unreadable: [String] { digest.unreadable }

    @objc(addFileAtPath:)
    @discardableResult
    public func add(path: String) -> Bool {
        digest.add(path: path)
    }

    @objc public var hexDigest: String { digest.hexDigest }
}
