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

    private func trusted(_ entry: String, http: Bool = false) -> XMLRPCLinkTrustedHost {
        XMLRPCLinkTrustedHost(entry: entry, allowsHTTP: http)!
    }

    private func download(_ url: String?, trusting hosts: [XMLRPCLinkTrustedHost], name: String = "DownloadURL") -> XMLRPCLinkPolicy.Verdict {
        var parameters = ["Display": "YES"]
        parameters["URL"] = url
        return XMLRPCLinkPolicy.verdict(methodName: name, parameters: parameters, trustedHosts: hosts)
    }

    /// A download runs unasked only to a host of the list, named exactly.
    @Test func aDownloadFromATrustedHostRunsUnasked() {
        let hosts = [trusted("pacs.example.com")]
        let wado = "https://pacs.example.com/wado?requestType=WADO&studyUID=1.2.3&token=abc"
        #expect(download(wado, trusting: hosts) == .run)
        #expect(download(wado, trusting: hosts, name: "downloadurl") == .run)
        #expect(download(wado, trusting: []) == .confirm)
        // A WADO XML manifest follows the same rule.
        #expect(download("https://pacs.example.com/studies/manifest.xml", trusting: hosts) == .run)
        #expect(download("https://other.example.com/studies/manifest.xml", trusting: hosts) == .confirm)
        // The case of the host does not count, in the link or in the list.
        #expect(download("HTTPS://PACS.Example.COM/wado", trusting: hosts) == .run)
        #expect(download(wado, trusting: [trusted("PACS.EXAMPLE.COM")]) == .run)
        #expect(download("https://pacs.example.com./wado", trusting: hosts) == .run)
        // No pattern: a subdomain, a parent and a name that only starts or ends alike are other hosts.
        for other in ["https://a.pacs.example.com/wado", "https://example.com/wado", "https://pacs.example.com.evil.test/wado",
                      "https://evilpacs.example.com/wado", "https://pacs.example.co/wado"] {
            #expect(download(other, trusting: hosts) == .confirm, "\(other)")
        }
        // The other methods that ask are not let through by the list.
        #expect(XMLRPCLinkPolicy.verdict(methodName: "KillOsiriX", parameters: ["URL": wado], trustedHosts: hosts) == .confirm)
        #expect(XMLRPCLinkPolicy.verdict(methodName: "OpenDB", parameters: ["URL": wado], trustedHosts: hosts) == .confirm)
        #expect(XMLRPCLinkPolicy.verdict(methodName: "FindObject", parameters: ["execute": "Delete", "URL": wado], trustedHosts: hosts) == .confirm)
    }

    /// The port of the scheme is the entry without a port; another port is another entry.
    @Test func aTrustedHostIsMatchedWithItsPort() {
        let plain = [trusted("pacs.example.com")]
        #expect(download("https://pacs.example.com:443/wado", trusting: plain) == .run)
        #expect(download("https://pacs.example.com:8443/wado", trusting: plain) == .confirm)
        let other = [trusted("pacs.example.com:8443")]
        #expect(download("https://pacs.example.com:8443/wado", trusting: other) == .run)
        #expect(download("https://pacs.example.com/wado", trusting: other) == .confirm)
        #expect(download("https://pacs.example.com:9000/wado", trusting: other) == .confirm)
        #expect(download("https://pacs.example.com:0/wado", trusting: plain) == .confirm)
        #expect(download("https://[2001:db8::1]:8443/wado", trusting: [trusted("[2001:db8::1]:8443")]) == .run)
        #expect(download("https://[2001:db8::2]:8443/wado", trusting: [trusted("[2001:db8::1]:8443")]) == .confirm)
        #expect(download("https://10.0.0.5/wado", trusting: [trusted("10.0.0.5")]) == .run)
    }

    /// A link that is not encrypted runs unasked only to a host marked for it.
    @Test func httpNeedsItsOwnMark() {
        #expect(download("http://pacs.example.com/wado", trusting: [trusted("pacs.example.com")]) == .confirm)
        let marked = [trusted("pacs.example.com", http: true)]
        #expect(download("http://pacs.example.com/wado", trusting: marked) == .run)
        #expect(download("http://pacs.example.com:80/wado", trusting: marked) == .run)
        #expect(download("https://pacs.example.com/wado", trusting: marked) == .run)
        #expect(download("http://pacs.example.com:8080/wado", trusting: marked) == .confirm)
        #expect(download("http://pacs.example.com:8080/wado", trusting: [trusted("pacs.example.com:8080", http: true)]) == .run)
        for other in ["ftp://pacs.example.com/a.dcm", "file:///tmp/a.dcm", "file://pacs.example.com/a.dcm", "//pacs.example.com/wado", "pacs.example.com/wado"] {
            #expect(download(other, trusting: marked) == .confirm, "\(other)")
        }
    }

    /// A URL that could be read in two ways, or that is not there, asks.
    @Test func aURLReadInMoreThanOneWayAsks() {
        let hosts = [trusted("pacs.example.com", http: true), trusted("evil.test")]
        // What comes before an @ is a user, not the host; a link with one asks even when its host is trusted.
        #expect(XMLRPCLinkOrigin(url: "https://pacs.example.com@other.test/wado") == nil)
        #expect(download("https://pacs.example.com@other.test/wado", trusting: [trusted("pacs.example.com")]) == .confirm)
        #expect(download("https://user:secret@pacs.example.com/wado", trusting: hosts) == .confirm)
        #expect(download("https://evil.test\\@pacs.example.com/wado", trusting: hosts) == .confirm)
        #expect(download("https://pacs.example.com\\.evil.test/wado", trusting: hosts) == .confirm)
        #expect(download("https://pacs.example.com /wado", trusting: hosts) == .confirm)
        #expect(download(" https://pacs.example.com/wado", trusting: hosts) == .confirm)
        #expect(download("https://pacs.example.com/wado\n", trusting: hosts) == .confirm)
        #expect(download("https://pacs.example.com\u{0}/wado", trusting: hosts) == .confirm)
        #expect(download(nil, trusting: hosts) == .confirm)
        #expect(download("", trusting: hosts) == .confirm)
        #expect(download("https:///wado", trusting: hosts) == .confirm)
        #expect(download("not a url", trusting: hosts) == .confirm)
        // The method reads a parameter's name whatever its case: two of them are two URLs.
        let twice = ["URL": "https://pacs.example.com/wado", "url": "https://other.test/wado"]
        #expect(XMLRPCLinkPolicy.verdict(methodName: "DownloadURL", parameters: twice, trustedHosts: hosts) == .confirm)
        #expect(XMLRPCLinkPolicy.verdict(methodName: "DownloadURL", parameters: ["url": "https://pacs.example.com/wado"], trustedHosts: hosts) == .run)
    }

    /// An internationalized name is compared in its ASCII form, so a name that looks alike is another host.
    @Test func anInternationalizedHostIsComparedInItsASCIIForm() {
        let typed = trusted("bücher.example")
        #expect(typed.host == "xn--bcher-kva.example")
        #expect(typed.entry == "xn--bcher-kva.example")
        #expect(download("https://xn--bcher-kva.example/wado", trusting: [typed]) == .run)
        #expect(download("https://bücher.example/wado", trusting: [trusted("xn--bcher-kva.example")]) == .run)
        #expect(download("https://bucher.example/wado", trusting: [typed]) == .confirm)
        // A Cyrillic letter in place of the Latin one it looks like.
        #expect(download("https://p\u{0430}cs.example.com/wado", trusting: [trusted("pacs.example.com")]) == .confirm)
    }

    /// What the user types becomes one host, and the list is stored with its marks.
    @Test func theListIsReadFromWhatIsTypedAndStored() {
        #expect(trusted(" pacs.example.com ").entry == "pacs.example.com")
        #expect(trusted("https://PACS.example.com:8443/wado?token=abc").entry == "pacs.example.com:8443")
        #expect(trusted("http://pacs.example.com/").entry == "pacs.example.com")
        #expect(trusted("[2001:DB8::1]").entry == "[2001:db8::1]")
        for text in ["", "  ", "*.example.com", "*", "pacs example.com", "user@pacs.example.com", "ftp://pacs.example.com",
                     "pacs.example.com:0", "pacs.example.com:70000", "https://", "pacs.example.com\\x"] {
            #expect(XMLRPCLinkTrustedHost(entry: text) == nil, "\(text)")
        }

        let secure = XMLRPCLinkOrigin(url: "https://Pacs.Example.com/wado?token=abc")!
        #expect(secure.entry == "pacs.example.com")
        #expect(XMLRPCLinkTrustedHost(trusting: secure) == trusted("pacs.example.com"))
        let plain = XMLRPCLinkOrigin(url: "http://pacs.example.com:8080/wado")!
        #expect(plain.entry == "pacs.example.com:8080")
        #expect(XMLRPCLinkTrustedHost(trusting: plain) == trusted("pacs.example.com:8080", http: true))
        #expect(XMLRPCLinkOrigin(url: "https://[2001:db8::1]:8443/wado")?.entry == "[2001:db8::1]:8443")

        var list = XMLRPCLinkTrustedHost.adding(trusted("pacs.example.com"), to: [])
        list = XMLRPCLinkTrustedHost.adding(trusted("b.example.com:8443"), to: list)
        list = XMLRPCLinkTrustedHost.adding(trusted("PACS.example.com", http: true), to: list)
        #expect(list == [trusted("pacs.example.com", http: true), trusted("b.example.com:8443")])
        list = XMLRPCLinkTrustedHost.adding(trusted("pacs.example.com"), to: list)
        #expect(list.first?.allowsHTTP == true)

        let stored = XMLRPCLinkTrustedHost.stored(list)
        #expect(stored.count == 2)
        #expect(stored[0]["Host"] as? String == "pacs.example.com")
        #expect(stored[0]["AllowsHTTP"] as? Bool == true)
        #expect(XMLRPCLinkTrustedHost.list(stored: stored) == list)
        #expect(XMLRPCLinkTrustedHost.list(stored: nil).isEmpty)
        let damaged: [Any] = ["pacs.example.com", ["Host": "*"], ["Host": 3], ["AllowsHTTP": true], ["Host": "a.example.com"], ["Host": "A.example.com", "AllowsHTTP": true]]
        #expect(XMLRPCLinkTrustedHost.list(stored: damaged) == [trusted("a.example.com", http: true)])
    }
}
