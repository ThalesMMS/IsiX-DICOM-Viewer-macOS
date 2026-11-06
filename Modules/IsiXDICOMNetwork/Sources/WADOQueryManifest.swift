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

/// A WADO query manifest, the XML a server or an XML-RPC call hands over to
/// retrieve its instances one WADO-URI request each:
///
///     <wado_query wadoURL="http://host/wado">
///       <Patient><Study StudyInstanceUID="..."><Series SeriesInstanceUID="...">
///         <Instance SOPInstanceUID="..."/>
///
/// Studies, series and instances keep the order of the document; one named
/// twice is listed once, with what both name. An element without its UID
/// names nothing: its children go to the study or series named before it.
public struct WADOQueryManifest: Equatable, Sendable {
    public struct Series: Equatable, Sendable {
        public var uid: String
        public var instances: [String]
    }

    public struct Study: Equatable, Sendable {
        public var uid: String
        public var series: [Series]
    }

    /// The `wadoURL` of the last `wado_query`; nil when it has none.
    public var wadoURL: String?
    public var studies: [Study]

    public init(wadoURL: String? = nil, studies: [Study] = []) {
        self.wadoURL = wadoURL
        self.studies = studies
    }

    /// The manifest at `url`; nil when it cannot be read: its document never
    /// started. One that ends in an error keeps what was read before it.
    public static func parse(contentsOf url: URL) -> WADOQueryManifest? {
        guard let parser = XMLParser(contentsOf: url) else { return nil }
        let reader = parse(parser)
        return reader.started ? reader.manifest : nil
    }

    public static func parse(data: Data) -> WADOQueryManifest {
        parse(XMLParser(data: data)).manifest
    }

    private static func parse(_ parser: XMLParser) -> Reader {
        let reader = Reader()
        parser.delegate = reader
        parser.parse()
        return reader
    }

    /// One WADO-URI request per instance, in the manifest's order, each asking
    /// for the original transfer syntax.
    public func urls() -> [URL] {
        let base = (wadoURL ?? "(null)") + "?requestType=WADO"
        var urls: [URL] = []
        for study in studies {
            for series in study.series {
                for instance in series.instances {
                    let text = base + "&studyUID=\(study.uid)&seriesUID=\(series.uid)&objectUID=\(instance)"
                        + "&contentType=application/dicom&useOrig=true"
                    if let url = NSURL(string: text) as URL? { urls.append(url) }
                }
            }
        }
        return urls
    }

    /// The XMLParser delegate, used on the parsing thread only.
    private final class Reader: NSObject, XMLParserDelegate {
        var manifest = WADOQueryManifest()
        private(set) var started = false
        private var study: String?
        private var series: String?
        // Where each study and series is in the manifest, and the instances
        // already listed, by study, series and instance UID.
        private var studies: [String: Int] = [:]
        private var seriesIndex: [[String]: Int] = [:]
        private var listed = Set<[String]>()

        func parserDidStartDocument(_ parser: XMLParser) {
            started = true
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            switch elementName {
            case "wado_query":
                manifest.wadoURL = attributeDict["wadoURL"]
            case "Study":
                let uid = attributeDict["StudyInstanceUID"]
                if let uid, studies[uid] == nil {
                    studies[uid] = manifest.studies.count
                    manifest.studies.append(Study(uid: uid, series: []))
                }
                study = uid
            case "Series":
                let uid = attributeDict["SeriesInstanceUID"]
                if let uid, let study, let s = studies[study], seriesIndex[[study, uid]] == nil {
                    seriesIndex[[study, uid]] = manifest.studies[s].series.count
                    manifest.studies[s].series.append(Series(uid: uid, instances: []))
                }
                series = uid
            case "Instance":
                guard let uid = attributeDict["SOPInstanceUID"], let study, let series, let s = studies[study],
                      let r = seriesIndex[[study, series]], listed.insert([study, series, uid]).inserted else { return }
                manifest.studies[s].series[r].instances.append(uid)
            default:
                break
            }
        }
    }
}
