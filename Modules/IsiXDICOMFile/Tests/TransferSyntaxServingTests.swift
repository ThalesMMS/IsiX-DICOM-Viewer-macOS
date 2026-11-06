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
import Testing
@testable import IsiXDICOMFile

@Suite struct TransferSyntaxServingTests {

    @Test func servesTheSameSyntaxAndTheOtherFlavourOfJPEG2000AndJPEGLS() {
        #expect(TransferSyntaxServing.servesOriginal(original: "1.2.840.10008.1.2.1", requested: "1.2.840.10008.1.2.1"))
        #expect(TransferSyntaxServing.servesOriginal(original: "1.2.840.10008.1.2.4.91", requested: "1.2.840.10008.1.2.4.90"))
        #expect(TransferSyntaxServing.servesOriginal(original: "1.2.840.10008.1.2.4.90", requested: "1.2.840.10008.1.2.4.91"))
        #expect(TransferSyntaxServing.servesOriginal(original: "1.2.840.10008.1.2.4.81", requested: "1.2.840.10008.1.2.4.80"))
        #expect(TransferSyntaxServing.servesOriginal(original: "1.2.840.10008.1.2.4.80", requested: "1.2.840.10008.1.2.4.81"))
    }

    @Test func transcodesAnythingElse() {
        #expect(!TransferSyntaxServing.servesOriginal(original: "1.2.840.10008.1.2.1", requested: "1.2.840.10008.1.2.4.50"))
        #expect(!TransferSyntaxServing.servesOriginal(original: "1.2.840.10008.1.2.4.91", requested: "1.2.840.10008.1.2.4.80"))
        #expect(!TransferSyntaxServing.servesOriginal(original: "1.2.840.10008.1.2.4.70", requested: "1.2.840.10008.1.2.4.57"))
        #expect(!TransferSyntaxServing.servesOriginal(original: "1.2.840.10008.1.2.1", requested: ""))
    }
}
