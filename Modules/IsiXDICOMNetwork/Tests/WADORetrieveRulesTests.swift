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
import IsiXPreferences
@testable import IsiXDICOMNetwork

@Suite(.serialized) struct WADORetrieveRulesTests {
    @Test func settingsClampWhatThePreferencesSay() {
        let none = WADORetrieveSettings(nodeLimit: 0, preferences: MemoryPreferences())
        #expect(none.maximumConcurrentDownloads == 1 && none.timeout == 240)
        let stored = MemoryPreferences([WADORetrieveSettings.concurrentDownloadsKey: 6, WADORetrieveSettings.timeoutKey: 600])
        let global = WADORetrieveSettings(nodeLimit: 0, preferences: stored)
        #expect(global.maximumConcurrentDownloads == 6 && global.timeout == 600)
        #expect(WADORetrieveSettings(nodeLimit: 3, preferences: stored).maximumConcurrentDownloads == 3)
        #expect(WADORetrieveSettings.concurrentDownloads(nodeLimit: -2, stored: -5) == 1)
        #expect(WADORetrieveSettings.timeout(stored: 30) == 240)
        #expect(WADORetrieveSettings.retryAttempts(stored: -1, adaptive: false) == 0)
        #expect(WADORetrieveSettings.retryAttempts(stored: 9, adaptive: false) == 5)
        #expect(WADORetrieveSettings.retryAttempts(stored: 2, adaptive: true) == 4)
        #expect(WADORetrieveSettings.retryAttempts(stored: 5, adaptive: true) == 5)
        #expect(WADORetrieveSettings.retryAttempts(preferences: MemoryPreferences([WADORetrieveSettings.retryAttemptsKey: 3]),
                                                   adaptive: false) == 3)
    }

    @Test func requestsCarryTheCredentialInTheirHeaderOnly() throws {
        let url = try #require(URL(string: "https://pacs.example/wado?requestType=WADO&objectUID=1"))
        let request = WADORequestRules.request(for: url, authorization: "Basic dTpw", timeout: 240)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic dTpw")
        #expect(request.url == url && request.timeoutInterval == 240)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(WADORequestRules.request(for: url, authorization: "", timeout: 1).allHTTPHeaderFields?.isEmpty ?? true)
        let configuration = WADORequestRules.sessionConfiguration(timeout: 300)
        #expect(configuration.urlCache == nil && configuration.timeoutIntervalForRequest == 300)
    }

    @Test func answersAreReadAsTheDownloaderReadThem() {
        #expect(!WADORequestRules.refuses(status: 299) && WADORequestRules.refuses(status: 300))
        #expect(WADORequestRules.refusesCredential(status: 401) && !WADORequestRules.refusesCredential(status: 404))
        #expect(WADORequestRules.expectedLength(contentLength: " 1234xyz", isHTTP: true, expectedContentLength: 9) == 1234)
        #expect(WADORequestRules.expectedLength(contentLength: nil, isHTTP: true, expectedContentLength: 9) == 0)
        #expect(WADORequestRules.expectedLength(contentLength: nil, isHTTP: false, expectedContentLength: 9) == 9)
        var dicom = Data(count: 128) + Data("DICM".utf8) + Data([0, 1])
        #expect(WADORequestRules.looksLikeDICOM(dicom) && WADORequestRules.fileExtension(ofBody: dicom) == "dcm")
        dicom = Data(count: 128) + Data("DICM".utf8)
        #expect(!WADORequestRules.looksLikeDICOM(dicom))
        #expect(WADORequestRules.fileExtension(ofBody: Data("PK\u{3}\u{4}".utf8)) == "osirixzip")
        #expect(!WADORequestRules.carriesObject(Data("ab".utf8)) && WADORequestRules.carriesObject(Data("abc".utf8)))
    }

    @Test func trustFailuresAreToldApart() {
        #expect(WADORequestRules.isTrustFailure(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted))
        #expect(!WADORequestRules.isTrustFailure(domain: "other", code: NSURLErrorServerCertificateUntrusted))
        #expect(WADORequestRules.strainsNode(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        #expect(!WADORequestRules.strainsNode(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        #expect(!WADORequestRules.strainsNode(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed))
        #expect(WADORequestRules.failureReason(domain: NSURLErrorDomain, code: -1202) == "TLS NSURLErrorDomain -1202")
        #expect(WADORequestRules.failureReason(domain: "x", code: 3) == "Transport error 3")
        #expect(WADORequestRules.untrustedServerReason(domain: NSURLErrorDomain, code: -1202, description: "bad", host: nil)
                == "the certificate of the server is not trusted (bad); trust its CA in Keychain Access to retrieve from it")
    }

    @Test func theNetworkLogNamesPoliciesNeverURLs() throws {
        let urls = try ["https://h/w?transferSyntax=*&useOrig=true", "http://h/w?useOrig=true", "http://h/w?transferSyntax=1.2.840",
                        "ftp://h/w?transferSyntax=bad%20one", "file:///tmp/x"].map { try #require(URL(string: $0)) }
        #expect(WADONetworkTally.policy(for: urls) == "file; transferSyntax=default; http; transferSyntax=1.2.840; "
                + "http; transferSyntax=useOrig; https; transferSyntax=*; other; transferSyntax=other")
        var tally = WADONetworkTally()
        for index in 0..<25 { tally.record("reason \(index % 22)") }
        #expect(tally.issues.count == 21 && tally.issues["other errors"] == 2)
        tally.requests = 4
        tally.retries = 1
        #expect(tally.message(finished: false, complete: true) == "In Progress")
        #expect(tally.message(finished: true, complete: false) == "Incomplete")
        tally.cancelled = true
        #expect(tally.message(finished: true, complete: true) == "Cancelled")
        var small = WADONetworkTally()
        small.record("HTTP 404")
        small.record("HTTP 404")
        #expect(small.details(received: 1, requested: 2, missing: 1, policy: "p") == "WADO; received=1/2; missing=1; requests=0; retries=0; p; HTTP 404 x2")
    }

    @Test func originalSyntaxDropsTheWildcardForAnEndpointThatRefusedIt() throws {
        WADOOriginalSyntax.reset()
        defer { WADOOriginalSyntax.reset() }
        let url = try #require(URL(string: "http://Pacs:8080/wado?requestType=WADO&objectUID=1&transferSyntax=*&useOrig=true"))
        #expect(WADOOriginalSyntax.carriesWildcard(url) && WADOOriginalSyntax.request(for: url) == url)
        #expect(WADOOriginalSyntax.request(for: url, withoutWildcard: true).absoluteString
                == "http://Pacs:8080/wado?requestType=WADO&objectUID=1&useOrig=true")
        WADOOriginalSyntax.noteRefusal(of: url)
        #expect(WADOOriginalSyntax.refuses(try #require(URL(string: "http://pacs:8080/wado?objectUID=2"))))
        #expect(!WADOOriginalSyntax.carriesWildcard(WADOOriginalSyntax.request(for: url)))
        WADOOriginalSyntax.noteRefusalWithoutWildcard(of: url)
        #expect(WADOOriginalSyntax.request(for: url) == url)
        #expect(WADOOriginalSyntax.refusesWildcard(status: 406) && !WADOOriginalSyntax.refusesWildcard(status: 403))
    }

    @Test func credentialsAreCarriedOnTheSameOriginOnly() throws {
        #expect(WADOCredentialRules.basicAuthorization(username: "u", password: "p:@/") == "Basic dTpwOkAv")
        #expect(WADOCredentialRules.basicAuthorization(username: "", password: "p") == nil)
        #expect(WADOCredentialRules.password(ofBasicAuthorization: "basic dTpwOkAv") == "p:@/")
        #expect(WADOCredentialRules.password(ofBasicAuthorization: "Bearer x") == nil)
        #expect(WADOCredentialRules.password(ofBasicAuthorization: "Basic !!") == nil)
        let a = try #require(URL(string: "https://Pacs/wado")), b = try #require(URL(string: "https://pacs:443/other"))
        let c = try #require(URL(string: "http://pacs/wado")), d = try #require(URL(string: "https://evil/wado"))
        #expect(WADOCredentialRules.sameOrigin(a, b) && !WADOCredentialRules.sameOrigin(a, c) && !WADOCredentialRules.sameOrigin(a, nil))
        #expect(WADOCredentialRules.redirectAuthorization(to: b, from: a, carrying: "Basic x") == "Basic x")
        #expect(WADOCredentialRules.redirectAuthorization(to: d, from: a, carrying: "Basic x") == nil)
        #expect(WADOCredentialRules.migration(username: "u", password: nil) == WADOCredentialRules.Migration.none)
        #expect(WADOCredentialRules.migration(username: "u", password: "p") == .store(username: "u", password: "p"))
        #expect(WADOCredentialRules.migration(username: nil, password: "p") == .remove)
        #expect(WADOCredentialRules.migration(username: "u", password: "") == .remove)
    }

    @Test func aManifestListsItsInstancesInOrderOnce() {
        let xml = """
        <wado_query wadoURL="http://h:8080/wado"><Patient>
          <Study StudyInstanceUID="1"><Series SeriesInstanceUID="1.1">
            <Instance SOPInstanceUID="1.1.1"/><Instance SOPInstanceUID="1.1.2"/><Instance SOPInstanceUID="1.1.1"/>
          </Series></Study>
          <Study StudyInstanceUID="2"><Series SeriesInstanceUID="2.1"><Instance SOPInstanceUID="2.1.1"/></Series>
            <Series><Instance SOPInstanceUID="lost"/></Series></Study>
          <Study StudyInstanceUID="1"><Series SeriesInstanceUID="1.2"><Instance SOPInstanceUID="1.2.1"/></Series></Study>
        </Patient></wado_query>
        """
        let manifest = WADOQueryManifest.parse(data: Data(xml.utf8))
        #expect(manifest.wadoURL == "http://h:8080/wado")
        #expect(manifest.studies.map(\.uid) == ["1", "2"])
        #expect(manifest.studies[0].series.map(\.uid) == ["1.1", "1.2"])
        #expect(manifest.studies[0].series[0].instances == ["1.1.1", "1.1.2"])
        let urls = manifest.urls().map(\.absoluteString)
        #expect(urls.count == 4)
        #expect(urls.first == "http://h:8080/wado?requestType=WADO&studyUID=1&seriesUID=1.1&objectUID=1.1.1&contentType=application/dicom&useOrig=true")
        #expect(WADOQueryManifest.parse(data: Data("not xml".utf8)).studies.isEmpty)
        #expect(WADOQueryManifest.parse(contentsOf: URL(fileURLWithPath: "/nonexistent/manifest.xml")) == nil)
    }
}
