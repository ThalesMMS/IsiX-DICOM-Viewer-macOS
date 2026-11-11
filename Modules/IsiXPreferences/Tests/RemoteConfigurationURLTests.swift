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
@testable import IsiXPreferences

@Suite struct RemoteConfigurationURLTests {
    @Test func onlyAnEncryptedAddressOrALocalFileIsRead() {
        #expect(RemoteConfigurationURL.isAcceptable(URL(string: "https://example.org/preferences.plist")))
        #expect(RemoteConfigurationURL.isAcceptable(URL(string: "HTTPS://example.org/preferences.plist")))
        #expect(RemoteConfigurationURL.isAcceptable(URL(fileURLWithPath: "/tmp/preferences.plist")))
        #expect(!RemoteConfigurationURL.isAcceptable(URL(string: "http://example.org/preferences.plist")))
        #expect(!RemoteConfigurationURL.isAcceptable(URL(string: "ftp://example.org/preferences.plist")))
        #expect(!RemoteConfigurationURL.isAcceptable(URL(string: "example.org/preferences.plist")))
        #expect(!RemoteConfigurationURL.isAcceptable(nil))
    }
}
