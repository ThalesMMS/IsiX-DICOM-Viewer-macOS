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
import IsiXROI

/// The ROI interchange document as it is written and read.
struct ROIInterchangeDocumentTests {

    func reference(_ uid: String) -> [String: Any] {
        ["sopInstanceUID": uid, "frame": 0, "generated": NSNumber(value: 1),
         "imagePositionPatient": [0.0, 0.0, 0.0], "imageOrientationPatient": [1.0, 0.0, 0.0, 0.0, 1.0, 0.0],
         "pixelSpacing": [0.5, 0.5]]
    }

    func lengthPayload() -> [String: Any] {
        ["version": 1, "id": "L1", "a": [1.0, 2.0, 3.0], "b": [4.0, 5.0, 6.0], "series": "1.2.3",
         "frameOfReference": "1.2.3.4", "temporalIndex": 0, "referenceA": reference("1.2.3.5"), "referenceB": reference("1.2.3.6")]
    }

    func document(rois: [ROIInterchangeDocument.Region]) -> ROIInterchangeDocument {
        let image = ROIInterchangeDocument.Image(index: 2, temporalIndex: nil, sopInstanceUID: "1.2.3.5", frame: nil, instanceNumber: 3,
                                                 rows: 4, columns: 5, pixelSpacing: [0.5, 0.5], sliceThickness: nil, sliceLocation: 1.5,
                                                 imagePositionPatient: [0, 0, 1.5], imageOrientationPatient: nil, rois: rois)
        return ROIInterchangeDocument(version: ROIInterchangeDocument.version(for: [image]), generator: "IsiX DICOM Viewer 6.0",
                                      created: "2026-11-05T00:00:00Z", series: .init(seriesInstanceUID: "1.2.3", modality: "CT"),
                                      images: [image])
    }

    let polygon = ROIInterchangeDocument.Region(name: "A", type: "closedPolygon", typeCode: 11, comments: nil,
                                                points: [[1, 2], [3, 4.5]], pointsPatient: nil, volumeLength: nil, rect: nil,
                                                thickness: 2, opacity: 1, color: [1, 0, 0], isSpline: nil, groupID: nil, brush: nil)

    @Test func theDocumentIsWrittenPrettyPrintedWithItsKeysSortedAndItsAbsentValuesLeftOut() throws {
        let text = String(decoding: try document(rois: [polygon]).encoded(), as: UTF8.self)
        let expected = """
        {
          "coordinateSystems" : {
            "patient" : "DICOM patient coordinates (LPS), millimetres",
            "pixel" : "image pixels: x right, y down, origin at the top-left corner of pixel (0,0), one unit per pixel"
          },
          "created" : "2026-11-05T00:00:00Z",
          "format" : "org.horosproject.roi-interchange",
          "generator" : "IsiX DICOM Viewer 6.0",
          "images" : [
            {
              "columns" : 5,
              "imagePositionPatient" : [
                0,
                0,
                1.5
              ],
              "index" : 2,
              "instanceNumber" : 3,
              "pixelSpacing" : [
                0.5,
                0.5
              ],
              "rois" : [
                {
                  "color" : [
                    1,
                    0,
                    0
                  ],
                  "name" : "A",
                  "opacity" : 1,
                  "points" : [
                    [
                      1,
                      2
                    ],
                    [
                      3,
                      4.5
                    ]
                  ],
                  "thickness" : 2,
                  "type" : "closedPolygon",
                  "typeCode" : 11
                }
              ],
              "rows" : 4,
              "sliceLocation" : 1.5,
              "sopInstanceUID" : "1.2.3.5"
            }
          ],
          "series" : {
            "modality" : "CT",
            "seriesInstanceUID" : "1.2.3"
          },
          "version" : 1
        }
        """
        #expect(text == expected)
    }

    @Test func aDocumentReadsBackAsItWasWritten() throws {
        let written = document(rois: [polygon])
        #expect(try ROIInterchangeDocument.decoded(from: written.encoded()) == written)
    }

    @Test func aPhysicalLengthMakesTheDocumentVersionTwoAndKeepsItsPayload() throws {
        let length = try ROIInterchangeDocument.VolumeLength.from(payload: lengthPayload())
        #expect(length.defect == nil)
        #expect(length.referenceA.generated)
        var region = polygon
        region.volumeLength = length
        #expect(document(rois: [region]).version == 2)
        let payload = try length.validatedPayload()
        #expect(payload["id"] as? String == "L1")
        #expect((payload["referenceB"] as? [String: Any])?["generated"] as? Bool == true)
    }

    @Test func aLengthWithTheSameEndpointsOrABadReferenceIsRefused() throws {
        var length = try ROIInterchangeDocument.VolumeLength.from(payload: lengthPayload())
        length.b = length.a
        #expect(length.defect == .endpoints)
        #expect(throws: ROIInterchangeDocument.VolumeLength.Defect.endpoints) { try length.validatedPayload() }
        length = try ROIInterchangeDocument.VolumeLength.from(payload: lengthPayload())
        length.referenceB.pixelSpacing = [0.5, 0]
        #expect(length.defect == .referenceGeometry)
        #expect(length.defect?.reason == "Invalid Length endpoint reference geometry.")
    }

    @Test func aDocumentThatIsNotOneSaysWhere() {
        do {
            _ = try ROIInterchangeDocument.decoded(from: Data(#"{"format": "x", "version": 1}"#.utf8))
            Issue.record("decoded")
        } catch let error as DecodingError {
            #expect(ROIInterchangeDocument.describe(error) == "missing key \"coordinateSystems\" in document.")
        } catch {
            Issue.record("\(error)")
        }
    }
}
