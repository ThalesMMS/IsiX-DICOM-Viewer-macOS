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

// Selectors of DCMTKQueryNode in the Horos and OsiriX plugin SDK that take or
// answer a DCMTK dataset by its address. A plugin built with DCMTK's headers
// sends them without being rebuilt; the application itself builds its
// identifiers as DICOMQueryIdentifier and does not. The address is that of a
// DcmDataset, which Swift does not see: the DCMTK adapter copies it.
extension DCMTKQueryNode {
    /// A new DcmDataset with the identifier a retrieve of this node sends, for
    /// the caller to delete; NULL for a node that retrieves nothing.
    @objc(moveDataset)
    func legacyMoveDataset() -> UnsafeMutableRawPointer? {
        moveIdentifier()?.dataset().newDCMTKDatasetCopy()
    }

    @objc(setupNetworkWithSyntax:dataset:)
    func legacySetupNetwork(syntax: UnsafePointer<CChar>?, dataset: UnsafeRawPointer?) -> Bool {
        legacySetupNetwork(syntax: syntax, dataset: dataset, destination: nil)
    }

    /// The association for the service of the abstract syntax `syntax`, the
    /// service with a copy of the dataset at `dataset` as its identifier, and
    /// the release; whether it all went through. A syntax that is not one of
    /// the query and retrieve services is refused.
    @objc(setupNetworkWithSyntax:dataset:destination:)
    func legacySetupNetwork(syntax: UnsafePointer<CChar>?, dataset: UnsafeRawPointer?, destination: String?) -> Bool {
        guard let service = syntax.flatMap({ QueryRetrieveService(rawValue: String(cString: $0)) }) else {
            NSLog("-[DCMTKQueryNode setupNetworkWithSyntax:dataset:destination:]: %@ is not a query or retrieve service",
                  syntax.map { String(cString: $0) } ?? "(null)")
            return false
        }
        return setupNetwork(service: service, identifier: Self.identifier(copying: dataset), destination: destination)
    }

    /// The elements of the DcmDataset at `dataset` as an identifier; nil for NULL.
    private static func identifier(copying dataset: UnsafeRawPointer?) -> DICOMQueryIdentifier? {
        guard let copy = IsiXDCMTKDataset(copyingDCMTKDatasetAtAddress: dataset) else { return nil }
        var read = DICOMQueryIdentifier()
        try? copy.enumerateElements { tag, value in read.set(DICOMTag(rawValue: tag), bytes: value.map { [UInt8]($0) }) }
        return read
    }

    /// A copy of the response at `dataset` as a child of this node, as a
    /// search adds its answers.
    @objc(addChild:)
    func legacyAddChild(_ dataset: UnsafeRawPointer?) {
        addChild(IsiXDCMTKDataset(copyingDCMTKDatasetAtAddress: dataset))
    }

    /// A new DcmDataset with what a search of this node's children asks for,
    /// for the caller to delete; NULL for a node with no level below.
    @objc(queryPrototype)
    func legacyQueryPrototype() -> UnsafeMutableRawPointer? {
        queryPrototype()?.dataset().newDCMTKDatasetCopy()
    }

    /// The search of this node's children for `values`, starting from a copy
    /// of the dataset at `dataset` where the node's own prototype would be.
    @objc(queryWithValues:dataset:)
    func legacyQuery(withValues values: [Any]?, dataset: UnsafeRawPointer?) {
        query(withValues: values, identifier: Self.identifier(copying: dataset))
    }
}
