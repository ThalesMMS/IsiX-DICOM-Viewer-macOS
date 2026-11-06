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
@testable import IsiXHTTPServer

/// The XML-RPC interface's published methods and how it encodes its answers.
/// The dispatch over a connection is tests/test-xmlrpc-request-contract.py.
struct XMLRPCMethodTableTests {

    @Test func everyPublishedNameHasItsSelector() {
        let expected: [String: String] = [
            "KillOsiriX": "KillOsiriX:error:", "DownloadURL": "DownloadURL:error:",
            "DisplayStudy": "DisplayStudy:error:", "DisplaySeries": "DisplaySeries:error:",
            "DBWindowFind": "FindObject:error:", "FindObject": "FindObject:error:",
            "SwitchToDefaultDBIfNeeded": "SelectDefaultDatabase:error:", "OpenDB": "OpenDatabase:error:",
            "SelectAlbum": "SelectAlbum:error:", "CloseAllWindows": "CloseAllWindows:error:",
            "GetDisplayed2DViewerSeries": "GetDisplayed2DViewerSeries:error:",
            "GetDisplayed2DViewerStudies": "GetDisplayed2DViewerStudies:error:",
            "Close2DViewerWithSeriesUID": "Close2DViewerWithSeriesUID:error:",
            "Close2DViewerWithStudyUID": "Close2DViewerWithStudyUID:error:",
            "Retrieve": "Retrieve:error:", "CMove": "CMove:error:",
            "DisplayStudyListByPatientName": "DisplayStudyListByPatientName:error:",
            "DisplayStudyListByPatientId": "DisplayStudyListByPatientId:error:",
            "PathToFrontDCM": "PathToFrontDCM:error:",
        ]
        #expect(XMLRPCMethodTable.selectors.count == expected.count)
        for (name, selector) in expected {
            #expect(XMLRPCMethodTable.selector(forMethodName: name) == selector)
            #expect(XMLRPCMethodTable.selector(forMethodName: name.uppercased()) == selector)
            #expect(XMLRPCMethodTable.selector(forMethodName: name.lowercased()) == selector)
        }
    }

    @Test func anUnpublishedNameIsNotDispatched() {
        #expect(XMLRPCMethodTable.selector(forMethodName: "isEqualTo") == nil)
        #expect(XMLRPCMethodTable.selector(forMethodName: "DisplayStudy:error:") == nil)
        #expect(XMLRPCMethodTable.selector(forMethodName: "") == nil)
    }

    @Test func theErrorMemberIsTheCodeAsAnInt() {
        #expect(XMLRPCMethodResult.errorMember(0) == "0")
        #expect(XMLRPCMethodResult.errorMember(-3) == "-3")
        #expect(XMLRPCMethodResult.errorMember(400) == "400")
        #expect(XMLRPCMethodResult.errorMember(0x1_0000_0001) == "1")
        #expect(XMLRPCMethodResult.errorDocument(code: 400)
                == "<?xml version=\"1.0\"?><methodResponse><params><param><value><struct><member><name>error</name><value>400</value></member></struct></value></param></params></methodResponse>")
    }
}
