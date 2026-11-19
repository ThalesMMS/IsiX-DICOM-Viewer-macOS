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
import IsiXHTTPServer

@Suite struct XMLRPCRequestGuardsTests {

    private func refusal(method: String? = "POST", _ fields: [String: String], local: Bool = true,
                         own: Set<String> = ["mac.local", "mac"]) -> XMLRPCWebPageRequest.Refusal? {
        XMLRPCWebPageRequest.refusal(method: method, field: { name in fields.first { $0.key.lowercased() == name.lowercased() }?.value },
                                     peerIsThisComputer: local) { host in
            XMLRPCWebPageRequest.isOwnHost(host, names: own) { ["127.0.0.1", "::1", "192.168.1.20"].contains($0) }
        }
    }

    /// What a RIS, a script or curl sends is answered: no field of a browser,
    /// and a Host that is this Mac, by name or by address, or none at all.
    @Test func aProgramsCallIsAnswered() {
        #expect(refusal(["Host": "127.0.0.1:8080", "Content-Type": "text/xml", "User-Agent": "curl/8.7.1"]) == nil)
        #expect(refusal(["Host": "localhost:8080"]) == nil)
        #expect(refusal(["Host": "LOCALHOST"]) == nil)
        #expect(refusal(["Host": "Mac.local.:8080"]) == nil)
        #expect(refusal(["Host": "192.168.1.20:8080"]) == nil)
        #expect(refusal(["Host": "[::1]:8080"]) == nil)
        #expect(refusal([:]) == nil)
        #expect(refusal(method: "post", ["Host": "localhost"]) == nil)
        // A program's Referer that is no page's address is not a browser's.
        #expect(refusal(["Host": "localhost", "Referer": "ris-client"]) == nil)
    }

    /// A page open in a browser marks its request, whichever way it is sent
    /// (fetch, a form, a script), and is refused whoever the peer is.
    @Test func whatAWebPageSendsIsRefused() {
        #expect(refusal(["Host": "127.0.0.1:8080", "Origin": "https://example.org"]) == .fromWebPage(field: "Origin"))
        #expect(refusal(["Host": "127.0.0.1:8080", "Origin": "null"]) == .fromWebPage(field: "Origin"))
        #expect(refusal(["Host": "127.0.0.1:8080", "origin": ""]) == .fromWebPage(field: "Origin"))
        #expect(refusal(["Host": "localhost", "Sec-Fetch-Site": "cross-site"]) == .fromWebPage(field: "Sec-Fetch-Site"))
        #expect(refusal(["Host": "localhost", "Sec-Fetch-Mode": "no-cors"]) == .fromWebPage(field: "Sec-Fetch-Mode"))
        #expect(refusal(["Host": "localhost", "Referer": "https://example.org/page"]) == .fromWebPage(field: "Referer"))
        #expect(refusal(["Host": "192.168.1.20", "Origin": "http://intranet"], local: false) == .fromWebPage(field: "Origin"))
        #expect(XMLRPCWebPageRequest.Refusal.fromWebPage(field: "Origin").status == 403)
    }

    /// A request made on this Mac to a name that is not this Mac's (a DNS name
    /// made to resolve to a local address) is refused; from another computer
    /// the name is not judged, as a RIS may know this Mac by one it does not.
    @Test func aHostThatIsNotThisMacIsRefusedOnThisMac() {
        #expect(refusal(["Host": "attacker.example:8080"]) == .foreignHost("attacker.example"))
        #expect(refusal(["Host": "10.0.0.9:8080"]) == .foreignHost("10.0.0.9"))
        #expect(refusal(["Host": "viewer.hospital.lan:8080"], local: false) == nil)
        #expect(XMLRPCWebPageRequest.Refusal.foreignHost("x").status == 403)
    }

    /// An XML-RPC call is a POST: anything else is answered 405.
    @Test func onlyAPostIsACall() {
        #expect(refusal(method: "GET", ["Host": "localhost"]) == .notAPost("GET"))
        #expect(refusal(method: "OPTIONS", ["Host": "localhost", "Origin": "https://example.org"]) == .notAPost("OPTIONS"))
        #expect(refusal(method: nil, [:]) == .notAPost(""))
        #expect(XMLRPCWebPageRequest.Refusal.notAPost("GET").status == 405)
    }

    @Test func theHostOfAHostField() {
        #expect(XMLRPCWebPageRequest.hostName(ofHostField: " Example.ORG:8080 ") == "example.org")
        #expect(XMLRPCWebPageRequest.hostName(ofHostField: "[fe80::1]:8080") == "fe80::1")
        #expect(XMLRPCWebPageRequest.hostName(ofHostField: "[::1]") == "::1")
        #expect(XMLRPCWebPageRequest.hostName(ofHostField: "mac.local.") == "mac.local")
        #expect(XMLRPCWebPageRequest.hostName(ofHostField: "") == "")
    }

    /// A body is refused by the length it announces, before it is received,
    /// or by what has arrived when it announces none or a length never reached.
    @Test func aBodyLongerThanACallIsRefused() {
        let limit = XMLRPCRequestLimits.body
        #expect(!XMLRPCRequestLimits.bodyIsTooLong(contentLengthField: "512", received: 0))
        #expect(!XMLRPCRequestLimits.bodyIsTooLong(contentLengthField: String(limit), received: limit))
        #expect(XMLRPCRequestLimits.bodyIsTooLong(contentLengthField: String(limit + 1), received: 0))
        #expect(XMLRPCRequestLimits.bodyIsTooLong(contentLengthField: "2147483647", received: 0))
        #expect(XMLRPCRequestLimits.bodyIsTooLong(contentLengthField: "99999999999999999999999999", received: 0))
        #expect(!XMLRPCRequestLimits.bodyIsTooLong(contentLengthField: "0000000000000000000000000012", received: 12))
        #expect(!XMLRPCRequestLimits.bodyIsTooLong(contentLengthField: nil, received: limit))
        #expect(XMLRPCRequestLimits.bodyIsTooLong(contentLengthField: nil, received: limit + 1))
        // A negative length is never reached: the body is held to the limit as it arrives.
        #expect(!XMLRPCRequestLimits.bodyIsTooLong(contentLengthField: "-1", received: 10))
        #expect(XMLRPCRequestLimits.bodyIsTooLong(contentLengthField: "-1", received: limit + 1))
        #expect(XMLRPCRequestLimits.connections >= 16)
    }

    /// A link runs unasked what a RIS puts in its links: showing, finding,
    /// retrieving, closing. What ends the application, opens another database,
    /// downloads, deletes, or a method a plugin added, asks first.
    @Test func whatALinkRunsUnasked() {
        for name in ["DisplayStudy", "displaystudy", "DisplaySeries", "FindObject", "DBWindowFind", "Retrieve", "CMove",
                     "CloseAllWindows", "Close2DViewerWithStudyUID", "SelectAlbum", "DisplayStudyListByPatientId"] {
            #expect(XMLRPCLinkPolicy.verdict(methodName: name, parameters: ["PatientID": "1"]) == .run, "\(name)")
        }
        for name in ["KillOsiriX", "killosirix", "DownloadURL", "OpenDB", "APluginsMethod", ""] {
            #expect(XMLRPCLinkPolicy.verdict(methodName: name, parameters: [:]) == .confirm, "\(name)")
        }
        #expect(XMLRPCLinkPolicy.verdict(methodName: "FindObject", parameters: ["table": "Study", "request": "TRUEPREDICATE", "execute": "Delete"]) == .confirm)
        #expect(XMLRPCLinkPolicy.verdict(methodName: "dbwindowfind", parameters: ["Execute": " delete "]) == .confirm)
        #expect(XMLRPCLinkPolicy.verdict(methodName: "FindObject", parameters: ["execute": "Open"]) == .run)
        // Every unattended name is a published method.
        #expect(XMLRPCLinkPolicy.unattended.isSubset(of: Set(XMLRPCMethodTable.selectors.keys)))
    }
}
