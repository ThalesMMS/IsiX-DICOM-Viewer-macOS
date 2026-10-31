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
import IsiXDICOMNetwork

/// The client is the application's side of the retrieve's port: the module
/// decides, and the client sends over the DICOM-Swift package, which the
/// module never imports.
extension DICOMwebClient: DICOMwebRetrieving {
    /// A client error in the terms the retrieve decides on, the error itself kept.
    static func requestFailure(_ error: Error) -> DICOMwebRequestFailure {
        let error = error as NSError
        return DICOMwebRequestFailure(kind: DICOMwebFailureKind(rawValue: errorKind(for: error).rawValue) ?? .invalidResponse,
                                      code: error.code,
                                      retryAfter: error.userInfo[retryAfterKey] as? String,
                                      objectsHandedOver: (error.userInfo[objectsHandedOverKey] as? NSNumber)?.intValue ?? 0,
                                      underlying: error)
    }

    public func retrieveObjects(path: String, stagingDirectory: String, fallbackOnly: Bool,
                                handler: @escaping (String) -> String?) throws(DICOMwebRequestFailure) -> Int {
        do {
            return try retrieve(path: path, stagingDirectory: stagingDirectory, fallbackOnly: fallbackOnly,
                                objectHandler: handler).intValue
        } catch {
            throw Self.requestFailure(error)
        }
    }

    public func previewPicture(study: String, series: String, instance: String?) throws(DICOMwebRequestFailure) -> Data {
        do {
            return try previewImage(study: study, series: series, instance: instance)
        } catch {
            throw Self.requestFailure(error)
        }
    }
}

extension DICOMwebRequestFailure {
    /// The client's error, as the retrieve reports it.
    var error: NSError { underlying as NSError }
}
