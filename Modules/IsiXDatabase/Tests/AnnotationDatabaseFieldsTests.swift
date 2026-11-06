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
@testable import IsiXDatabase

/// Where the annotations read the database fields of an image. The comparison
/// with the Objective-C it replaced is tests/test-dcmpix-annotations-documents-rtstruct.py.
struct AnnotationDatabaseFieldsTests {
    @Test func eachLevelIsReadFromTheImageRow() {
        #expect(AnnotationDatabaseFields.lookup(field: "instanceNumber", level: "image") == .key("instanceNumber"))
        #expect(AnnotationDatabaseFields.lookup(field: "seriesDescription", level: "series") == .keyPath("series.seriesDescription"))
        #expect(AnnotationDatabaseFields.lookup(field: "name", level: "study") == .keyPath("series.study.name"))
        #expect(AnnotationDatabaseFields.lookup(field: "name", level: "patient") == .none)
        #expect(AnnotationDatabaseFields.lookup(field: "name", level: nil) == .none)
    }

    @Test func aValueIsKeptUnderItsNameAndLevel() {
        #expect(AnnotationDatabaseFields.key(field: "name", level: "study") == "name study")
        #expect(AnnotationDatabaseFields.key(field: nil, level: "series") == "(null) series")
        #expect(AnnotationDatabaseFields.key(field: "name", level: nil) == "name (null)")
    }
}
