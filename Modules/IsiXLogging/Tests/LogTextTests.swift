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
@testable import IsiXLogging

/// What the log is told of a text, an error, an exception and a URL that are
/// not the application's own: never what they say.
struct LogTextTests {

    @Test func aTextIsToldByItsLength() {
        #expect(LogText.shape(of: "DOE^JOHN") == "<8 characters>")
        #expect(LogText.shape(of: "x") == "<1 character>")
        #expect(LogText.shape(of: "") == "<0 characters>")
        #expect(LogText.shape(of: nil) == "<none>")
    }

    @Test func aNoticeIsToldByItsTitleAndTheLengthOfItsText() {
        let logged = LogText.notice(title: "DICOMweb Retrieve Failed", text: "The node said: no patient DOE^JOHN born 19700101")
        #expect(logged == "DICOMweb Retrieve Failed (a notice of 48 characters)")
        #expect(!logged.contains("DOE") && !logged.contains("19700101"))
        #expect(LogText.notice(title: "Network Error", text: "x") == "Network Error (a notice of 1 character)")
        #expect(LogText.notice(title: "", text: "") == " (a notice of 0 characters)")
    }

    @Test func anErrorIsToldByItsDomainAndCode() {
        let file = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError, userInfo: [
            NSFilePathErrorKey: "/Volumes/CD/DOE^JOHN/IM1",
            NSLocalizedDescriptionKey: "The file “IM1” couldn’t be opened because there is no such file.",
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 2, userInfo: nil)])
        let logged = LogText.error(file)
        #expect(logged == "NSCocoaErrorDomain 260 (NSPOSIXErrorDomain 2)")
        #expect(!logged.contains("DOE") && !logged.contains("IM1"))
    }

    @Test func aURLErrorDoesNotQuoteItsURL() throws {
        let address = try #require(URL(string: "https://pacs.example/wado?requestType=WADO&PatientID=12345&token=secret"))
        let failed = URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: address])
        let logged = LogText.error(failed)
        #expect(logged == "NSURLErrorDomain -1001")
        // What the description of the same error prints.
        #expect(String(describing: failed as NSError).contains("PatientID=12345"))
    }

    @Test func aServersWordsInAnErrorAreNotWritten() {
        let refused = NSError(domain: "HorosDICOMweb", code: 409, userInfo: [
            NSLocalizedDescriptionKey: "The node refused the request. The node said: no patient DOE^JOHN born 19700101"])
        #expect(LogText.error(refused) == "HorosDICOMweb 409")
    }

    private enum Refusal: Error { case first, named(String) }

    @Test func aSwiftErrorIsToldByItsTypeAndCase() {
        let logged = LogText.error(Refusal.named("DOE^JOHN"))
        #expect(logged.contains("Refusal "))
        #expect(!logged.contains("DOE"))
        #expect(LogText.error(nil) == "<no error>")
    }

    @Test func anExceptionAnErrorCarriesIsToldByItsName() {
        let raised = NSException(name: .invalidArgumentException,
                                 reason: "Unable to parse the format string \"name == DOE^JOHN\"", userInfo: nil)
        let wrapped = NSError(domain: "HorosObjCException", code: 1, userInfo: ["exception": raised])
        #expect(LogText.error(wrapped) == "HorosObjCException 1 NSInvalidArgumentException")
    }

    @Test func anExceptionIsToldByItsNameAndTheLengthOfItsReason() {
        let raised = NSException(name: .invalidArgumentException,
                                 reason: "Unable to parse the format string \"name == DOE^JOHN\"", userInfo: nil)
        #expect(LogText.exception(raised) == "NSInvalidArgumentException <a reason of 52 characters>")
        #expect(LogText.exception(NSException(name: .genericException, reason: nil, userInfo: nil)) == "NSGenericException")
        #expect(LogText.exception(nil) == "<no exception>")
    }

    @Test func anExceptionIsWrittenToTheLogWithoutItsReason() {
        // The line goes to the unified log; that it is written, with and
        // without an exception or a stack, is all that can be seen from here.
        let raised = NSException(name: .rangeException, reason: "index 4 beyond bounds for DOE^JOHN", userInfo: nil)
        LogText.log(raised, stack: true, in: "-[LogTextTests anExceptionIsWrittenToTheLogWithoutItsReason]")
        LogText.log(nil, stack: false, in: "-[LogTextTests anExceptionIsWrittenToTheLogWithoutItsReason]")
        #expect(LogText.exception(raised) == "NSRangeException <a reason of 34 characters>")
    }

    @Test func aURLKeepsItsOriginAndPath() throws {
        let plain = try #require(URL(string: "https://pacs.example:8443/dicom-web/studies/1.2.3/series/4.5"))
        #expect(LogText.url(plain) == "https://pacs.example:8443/dicom-web/studies/1.2.3/series/4.5")
        #expect(LogText.url(URL(string: "http://[fe80::1]:8042/wado")) == "http://[fe80::1]:8042/wado")
        #expect(LogText.url(nil) == "<no URL>")
    }

    @Test func aURLLosesItsQueryItsUserAndItsFragment() throws {
        let address = try #require(URL(string:
            "https://reader:s3cret@pacs.example/wado?requestType=WADO&PatientName=DOE%5EJOHN&access_token=abc#frame"))
        let logged = LogText.url(address)
        #expect(logged == "https://pacs.example/wado <with a user, a query of 56 characters, a fragment>")
        for word in ["reader", "s3cret", "DOE", "JOHN", "access_token", "abc", "frame"] {
            #expect(!logged.contains(word))
        }
    }

    @Test func aFileURLIsToldByTheLengthOfItsPath() {
        let logged = LogText.url(URL(fileURLWithPath: "/Volumes/CD/DOE^JOHN/IM1"))
        #expect(logged == "file:<a path of 24 characters>")
    }

    @Test func anAddressGivenAsTextIsReadTheSameWay() {
        #expect(LogText.url(string: "http://pacs.example/wado?studyUID=1.2&PatientID=7") == "http://pacs.example/wado <with a query of 24 characters>")
        #expect(LogText.url(string: "DOE^JOHN 19700101") == "<not a URL, 17 characters>")
        #expect(LogText.url(string: "not a url") == "<not a URL, 9 characters>")
        #expect(LogText.url(string: nil) == "<no URL>")
    }
}
