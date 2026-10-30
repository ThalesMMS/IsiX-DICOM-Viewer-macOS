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

/// XML-RPC values and documents. The comparison with the former coder of the
/// app is tests/test-xmlrpc-connection-equivalence.py.
struct XMLRPCValueCoderTests {

    private func value(_ xml: String) throws -> XMLNode {
        let document = try XMLDocument(xmlString: "<value>\(xml)</value>", options: [])
        return document.rootElement()!
    }

    @Test func scalarsAreRead() throws {
        #expect(try XMLRPCValueCoder.parse(value("<string>a &amp;amp; b</string>")) as? String == "a &amp; b")
        #expect(try XMLRPCValueCoder.parse(value("bare")) as? String == "bare")
        #expect(try XMLRPCValueCoder.parse(value("")) as? String == "")
        #expect(try XMLRPCValueCoder.parse(value("<int>42</int>")) as? NSNumber == 42)
        #expect(try XMLRPCValueCoder.parse(value("<i4>-7x</i4>")) as? NSNumber == -7)
        #expect(try XMLRPCValueCoder.parse(value("<boolean>1</boolean>")) as? NSNumber == true)
        #expect(try XMLRPCValueCoder.parse(value("<double>2.5</double>")) as? NSNumber == 2.5)
        #expect(try XMLRPCValueCoder.parse(value("<nil/>")) == nil)
        #expect(try XMLRPCValueCoder.parse(value("<base64>AQID</base64>")) as? Data == Data([1, 2, 3]))
    }

    @Test func structsAndArraysAreRead() throws {
        let parsed = try XMLRPCValueCoder.parse(value(
            "<struct><member><name>a</name><value><array><data><value><int>1</int></value>"
            + "<value>two</value></data></array></value></member></struct>")) as? NSDictionary
        #expect(parsed == ["a": [1, "two"]] as NSDictionary)
    }

    @Test func unreadableValuesFailAsTheFormerCoderRaised() throws {
        #expect(throws: XMLRPCCodingError(name: "NSGenericException", reason: "unhandled XMLRPC data type: float")) {
            try XMLRPCValueCoder.parse(self.value("<float>1</float>"))
        }
        #expect(throws: XMLRPCCodingError(name: "NSInvalidArgumentException",
                                          reason: "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil")) {
            try XMLRPCValueCoder.parse(self.value("<array><data><value><nil/></value></data></array>"))
        }
        #expect(throws: XMLRPCCodingError(name: "NSRangeException",
                                          reason: "*** -[__NSArray0 objectAtIndex:]: index 0 beyond bounds for empty array")) {
            try XMLRPCValueCoder.parse(self.value("<struct><member><name>a</name></member></struct>"))
        }
        #expect(throws: XMLRPCCodingError(name: "NSInvalidArgumentException",
                                          reason: "*** -[__NSDictionaryM setObject:forKey:]: object cannot be nil (key: a)")) {
            try XMLRPCValueCoder.parse(self.value("<struct><member><name>a</name><value><nil/></value></member></struct>"))
        }
    }

    @Test func valuesAreWritten() throws {
        #expect(try XMLRPCValueCoder.format(nil) == "<nil/>")
        #expect(try XMLRPCValueCoder.format("a<&>'\"") == "<string>a&lt;&amp;&gt;&#39;&quot;</string>")
        #expect(try XMLRPCValueCoder.format("a&b", options: .dontSpecifyStringType) == "a&amp;b")
        #expect(try XMLRPCValueCoder.format(NSNumber(value: true)) == "<boolean>1</boolean>")
        #expect(try XMLRPCValueCoder.format(NSNumber(value: Int64(1) << 33 | 5)) == "<int>5</int>")
        #expect(try XMLRPCValueCoder.format(NSNumber(value: 1.5)) == "<double>1.500000</double>")
        #expect(try XMLRPCValueCoder.format(Data([0xFF, 0x00])) == "<base64>/wA=</base64>")
        #expect(try XMLRPCValueCoder.format(["x", 1] as NSArray) as String
                == "<array><data><value><string>x</string></value><value><int>1</int></value></data></array>")
        #expect(try XMLRPCValueCoder.format(["k&": "v"] as NSDictionary) as String
                == "<struct><member><name>k&amp;</name><value><string>v</string></value></member></struct>")
    }

    @Test func unsupportedValuesFail() {
        #expect(throws: XMLRPCCodingError(name: "NSGenericException",
                                          reason: "execution succeeded but return class NSURL unsupported")) {
            try XMLRPCValueCoder.format(NSURL(string: "http://127.0.0.1/")!)
        }
        #expect(throws: XMLRPCCodingError.self) {
            try XMLRPCValueCoder.format([NSNumber(value: 1): "v"] as NSDictionary)
        }
    }

    @Test func documentsAreWritten() throws {
        #expect(try XMLRPCValueCoder.request(methodName: "Do<it>", arguments: [["a": "b"]]) as String
                == "<?xml version=\"1.0\" encoding=\"UTF-8\"?><methodCall><methodName>Do&lt;it&gt;</methodName><params>"
                + "<param><value><struct><member><name>a</name><value><string>b</string></value></member></struct></value></param>"
                + "</params></methodCall>")
        #expect(try XMLRPCValueCoder.request(methodName: nil, arguments: nil) as String
                == "<?xml version=\"1.0\" encoding=\"UTF-8\"?><methodCall><methodName>(null)</methodName><params></params></methodCall>")
        #expect(try XMLRPCValueCoder.response(value: "x", options: .dontSpecifyStringType) as String
                == "<?xml version=\"1.0\" encoding=\"UTF-8\"?><methodResponse><params><param><value>x</value></param></params></methodResponse>")
    }

    @Test func escapingKeepsWhatIsNotEscaped() {
        let lone = NSString(characters: [0x61, 0xD800, 0x26], length: 3)
        let escaped = XMLRPCEscaping.escaped(lone)
        #expect(escaped.length == 7)
        #expect(escaped.character(at: 1) == 0xD800)
        #expect(XMLRPCEscaping.escaped("é João 🩻 &amp;") == "é João 🩻 &amp;amp;")
    }

    @Test func base64IsReadLeniently() {
        #expect(XMLRPCBase64.decode(nil) == nil)
        #expect(XMLRPCBase64.decode("") == NSData())
        #expect(XMLRPCBase64.decode(" AQ\nID ") as Data? == Data([1, 2, 3]))
        #expect(XMLRPCBase64.decode("A=Q=I=D") as Data? == Data([1, 2, 3]))
        #expect(XMLRPCBase64.decode("AQI") as Data? == Data([1, 2]))
        #expect(XMLRPCBase64.decode("AQIDB") == nil)
        #expect(XMLRPCBase64.decode("AQ!D") == nil)
        #expect(XMLRPCBase64.decode("AQé") == nil)
        for length in 0..<10 {
            let data = Data((0..<length).map { UInt8(truncatingIfNeeded: $0 * 37 + 11) })
            let encoded = XMLRPCBase64.encode(data as NSData)
            #expect(encoded as String == data.base64EncodedString())
            #expect(XMLRPCBase64.decode(encoded) as Data? == data)
        }
    }

    @Test func datesAreTheCalendarDay() {
        let previous = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/Sao_Paulo")!
        defer { NSTimeZone.default = previous }
        let date = XMLRPCDate.date(from: "  20260926T12:34:56")
        #expect(XMLRPCDate.string(from: date) == "2026-09-26")
        #expect(XMLRPCDate.date(from: "2026-09-26T12:34:56.789Z").timeIntervalSince1970 == 1_790_426_096)
        #expect(XMLRPCDate.date(from: "never") == XMLRPCDate.date(from: ""))
    }
}
