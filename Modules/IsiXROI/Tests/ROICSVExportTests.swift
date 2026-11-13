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
@testable import IsiXROI

@Suite struct ROICSVExportTests {

    typealias Export = ROICSVExport

    /// An oval with statistics on image 3, a Length on image 1 of a series
    /// without pixel spacing, and a text whose name needs quoting.
    static let entries: [Export.Entry] = [
        Export.Entry(seriesDescription: "Abdomen, portal", seriesInstanceUID: "1.2.3.4", image: 3, instanceNumber: 12,
                     typeCode: Export.TypeCode.oval, name: "liver \"left\"", area: 12.345678, length: nil, unit: .centimetre,
                     statistics: .init(mean: 52.25, deviation: 3.5, minimum: -10, maximum: 120),
                     points: [.init(x: 10.5, y: 20.25, patient: [-100.125, 50, 3.0004])]),
        Export.Entry(seriesDescription: "Abdomen, portal", seriesInstanceUID: "1.2.3.4", image: 1, instanceNumber: nil,
                     typeCode: Export.TypeCode.length, name: "span", area: nil, length: 42, unit: .pixel,
                     statistics: nil,
                     points: [.init(x: 0, y: 0, patient: nil), .init(x: 42, y: 0, patient: [1, 2])]),
        Export.Entry(seriesDescription: "Abdomen, portal", seriesInstanceUID: "1.2.3.4", image: 2, instanceNumber: 5,
                     typeCode: Export.TypeCode.text, name: "line one\nline two, more", area: nil, length: nil, unit: .centimetre,
                     statistics: nil, points: []),
    ]

    @Test func roiFile() {
        let text = Export.csv(Export.roiRows(Self.entries))
        let expected = "ROI,Series,Series Instance UID,Image,Instance Number,Type,Name,Area,Length,Unit,Mean,SD,Min,Max,Ratio,Numerator ROI,Denominator ROI\r\n"
            + "1,\"Abdomen, portal\",1.2.3.4,3,12,Oval,\"liver \"\"left\"\"\",12.3457,,cm,52.250,3.500,-10.000,120.000,,,\r\n"
            + "2,\"Abdomen, portal\",1.2.3.4,1,,Length,span,,42.0000,px,,,,,,,\r\n"
            + "3,\"Abdomen, portal\",1.2.3.4,2,5,Text,\"line one\nline two, more\",,,cm,,,,,,,\r\n"
        #expect(text == expected)
    }

    @Test func pointFile() {
        let text = Export.csv(Export.pointRows(Self.entries))
        let expected = "ROI,Image,Name,Point,X (px),Y (px),Patient X (mm),Patient Y (mm),Patient Z (mm)\r\n"
            + "1,3,\"liver \"\"left\"\"\",1,10.500,20.250,-100.125,50.000,3.000\r\n"
            + "2,1,span,1,0.000,0.000,,,\r\n"
            // A patient point without three coordinates is not written.
            + "2,1,span,2,42.000,0.000,,,\r\n"
        #expect(text == expected)
    }

    @Test func headersAreFixed() {
        #expect(Export.csv([Export.roiHeader]) == "ROI,Series,Series Instance UID,Image,Instance Number,Type,Name,Area,Length,Unit,Mean,SD,Min,Max,Ratio,Numerator ROI,Denominator ROI\r\n")
        #expect(Export.roiRows([]) == [Export.roiHeader])
        #expect(Export.pointRows([]) == [Export.pointHeader])
    }

    @Test func numbersUseADotWhateverTheLocale() {
        #expect(Export.number(1234567.5, decimals: 4) == "1234567.5000")
        #expect(Export.number(-0.00001, decimals: 3) == "0.000")
        #expect(Export.number(-0.4, decimals: 0) == "0")
        #expect(Export.number(-2.5, decimals: 1) == "-2.5")
        #expect(Export.number(0.12345, decimals: 3) == "0.123")
        #expect(Export.number(.nan, decimals: 3) == "")
        #expect(Export.number(.infinity, decimals: 3) == "")
        #expect(Export.number(nil, decimals: 3) == "")
    }

    @Test func quoting() {
        #expect(Export.field("plain") == "plain")
        #expect(Export.field("a,b") == "\"a,b\"")
        #expect(Export.field("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(Export.field("a\rb") == "\"a\rb\"")
        #expect(Export.field("a\r\nb") == "\"a\r\nb\"")
        #expect(Export.field("") == "")
    }

    @Test func fileBytes() {
        let data = Export.roiFile([])
        #expect(data.prefix(3) == Data([0xEF, 0xBB, 0xBF]))
        #expect(String(decoding: data.dropFirst(3), as: UTF8.self) == Export.csv([Export.roiHeader]))
        let accented = Export.data("Fígado")
        #expect(String(decoding: accented.dropFirst(3), as: UTF8.self) == "Fígado")
    }

    @Test func kinds() {
        for code in [Export.TypeCode.rectangle, Export.TypeCode.oval, Export.TypeCode.closedPolygon,
                     Export.TypeCode.openPolygon, Export.TypeCode.pencil, Export.TypeCode.brush] {
            #expect(Export.hasArea(typeCode: code) && Export.hasStatistics(typeCode: code) && !Export.hasLength(typeCode: code))
        }
        #expect(Export.hasLength(typeCode: Export.TypeCode.length) && !Export.hasArea(typeCode: Export.TypeCode.length))
        #expect(!Export.hasStatistics(typeCode: Export.TypeCode.length))
        #expect(Export.hasStatistics(typeCode: Export.TypeCode.tagt) && !Export.hasArea(typeCode: Export.TypeCode.tagt))
        for code in [Export.TypeCode.text, Export.TypeCode.arrow, Export.TypeCode.angle, Export.TypeCode.point] {
            #expect(!Export.hasArea(typeCode: code) && !Export.hasLength(typeCode: code) && !Export.hasStatistics(typeCode: code))
        }
        #expect(Export.typeName(Export.TypeCode.closedPolygon) == "Closed Polygon")
        #expect(Export.typeName(Export.TypeCode.brush) == "Brush")
        #expect(Export.typeName(99) == "Type 99")
    }

    @Test func pointsFileBesideTheROIFile() {
        let url = URL(fileURLWithPath: "/tmp/exports/Liver ROIs.csv")
        #expect(Export.pointsFileURL(for: url).path == "/tmp/exports/Liver ROIs points.csv")
        #expect(Export.pointsFileURL(for: URL(fileURLWithPath: "/tmp/a")).path == "/tmp/a points.csv")
    }
}
