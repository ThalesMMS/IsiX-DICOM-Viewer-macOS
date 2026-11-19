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
@testable import IsiXDICOMNetwork

/// A node counted as moving by whoever says so, as the move manager of the
/// former plugin SDK lets a plugin do, beside the operations that claim their
/// node for as long as they run.
@Suite struct RetrieveOperationsInsertionTests {

    @Test func aNodeIsCountedFromItsInsertionToItsRemoval() {
        let operations = RetrieveOperationsUnderWay()
        let node = NSObject(), other = NSObject()
        #expect(!operations.contains(node))
        #expect(operations.insert(node))
        #expect(operations.contains(node) && !operations.contains(other))
        // Inserted once: a second insertion changes nothing and says so.
        #expect(!operations.insert(node))
        #expect(operations.remove(node))
        #expect(!operations.contains(node))
        // Removing what is not counted changes nothing and says so.
        #expect(!operations.remove(node))
        #expect(!operations.remove(other))
    }

    // Nodes are told apart by identity, not by -isEqual:: two equal strings
    // are two nodes.
    @Test func nodesAreToldApartByIdentity() {
        let operations = RetrieveOperationsUnderWay()
        let one = NSMutableString(string: "node"), two = NSMutableString(string: "node")
        #expect(one == two && one !== two)
        operations.insert(one)
        #expect(operations.contains(one) && !operations.contains(two))
        #expect(!operations.remove(two))
        #expect(operations.contains(one))
    }

    // An inserted node is moving for an operation too: it is not run until
    // the node is removed.
    @Test func anInsertedNodeIsNotMovedUntilItIsRemoved() {
        let operations = RetrieveOperationsUnderWay(), node = NSObject()
        operations.insert(node)
        #expect(operations.run(for: node) { 1 } == nil)
        #expect(operations.contains(node))
        operations.remove(node)
        #expect(operations.run(for: node) { 2 } == 2)
        #expect(!operations.contains(node))
    }

    // A node removed while its operation runs is no longer counted, and the
    // end of the operation, which removes it again, changes nothing.
    @Test func aNodeRemovedDuringItsOperationStaysRemoved() {
        let operations = RetrieveOperationsUnderWay(), node = NSObject()
        let result = operations.run(for: node) { () -> Bool in
            #expect(operations.remove(node))
            #expect(!operations.contains(node))
            #expect(operations.insert(node))
            return true
        }
        #expect(result == true)
        // The operation's end let go the node inserted meanwhile, as the set
        // of the former SDK did: it held a node once, whoever added it.
        #expect(!operations.contains(node))
    }

    // Separate registries share nothing.
    @Test func registriesAreIndependent() {
        let shared = RetrieveOperationsUnderWay(), own = RetrieveOperationsUnderWay(), node = NSObject()
        own.insert(node)
        #expect(own.contains(node) && !shared.contains(node))
    }
}
