/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

@objc(WADOXML)
public final class WADOXML: NSObject, XMLParserDelegate {
    @objc public private(set) var studies: NSMutableDictionary?

    @objc public var studyInstanceUID: String?
    @objc public var seriesInstanceUID: String?
    @objc public var SOPInstanceUID: String?
    @objc public var wadoURL: String?

    public func parserDidStartDocument(_ parser: XMLParser) {
        studies = NSMutableDictionary()
    }

    /// -[NSMutableDictionary setObject:forKey:], which raised on a nil key; a
    /// message to a nil dictionary did nothing.
    private static func set(_ object: Any, in dictionary: Any?, forKey key: String?) {
        guard let dictionary = dictionary as? NSMutableDictionary else { return }
        guard let key else {
            NSException(name: .invalidArgumentException,
                        reason: "*** -[__NSDictionaryM setObject:forKey:]: key cannot be nil", userInfo: nil).raise()
            return
        }
        dictionary.setObject(object, forKey: key as NSString)
    }

    /// -[NSDictionary objectForKey:], nil for a nil dictionary or key.
    private static func object(in dictionary: Any?, forKey key: String?) -> Any? {
        guard let dictionary = dictionary as? NSDictionary, let key else { return nil }
        return dictionary.object(forKey: key)
    }

    public func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let element = elementName as NSString

        if element.isEqual(to: "wado_query") {
            self.wadoURL = attributeDict["wadoURL"]
        }

        if element.isEqual(to: "Study") {
            if Self.object(in: studies, forKey: attributeDict["StudyInstanceUID"]) == nil {
                Self.set(NSMutableDictionary(), in: studies, forKey: attributeDict["StudyInstanceUID"])
            }

            self.studyInstanceUID = attributeDict["StudyInstanceUID"]
        }

        if element.isEqual(to: "Series") {
            if Self.object(in: studies, forKey: self.studyInstanceUID) == nil {
                NSLog("****** [studies objectForKey: self.studyInstanceUID] == nil")
            }

            let study = Self.object(in: studies, forKey: self.studyInstanceUID)
            if Self.object(in: study, forKey: attributeDict["SeriesInstanceUID"]) == nil {
                Self.set(NSMutableDictionary(), in: study, forKey: attributeDict["SeriesInstanceUID"])
            }

            self.seriesInstanceUID = attributeDict["SeriesInstanceUID"]
        }

        if element.isEqual(to: "Instance") {
            if Self.object(in: studies, forKey: self.studyInstanceUID) == nil {
                NSLog("****** [studies objectForKey: self.studyInstanceUID] == nil")
            }

            let study = Self.object(in: studies, forKey: self.studyInstanceUID)
            if Self.object(in: study, forKey: self.seriesInstanceUID) == nil {
                NSLog("****** [[studies objectForKey: self.studyInstanceUID] objectForKey: self.seriesInstanceUID] == nil")
            }

            let series = Self.object(in: study, forKey: self.seriesInstanceUID)
            if Self.object(in: series, forKey: attributeDict["SOPInstanceUID"]) == nil {
                Self.set(NSMutableDictionary(), in: series, forKey: attributeDict["SOPInstanceUID"])
            } else {
                NSLog("****** [[[studies objectForKey: self.studyInstanceUID] objectForKey: self.seriesInstanceUID] objectForKey: [attributeDict objectForKey: @\"SOPInstanceUID\"]] != nil")
            }
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
    }

    public func parserDidEndDocument(_ parser: XMLParser) {
    }

    @objc(parseURL:)
    public func parseURL(_ url: URL?) {
        guard let url, let parser = XMLParser(contentsOf: url) else { return }

        parser.delegate = self

        parser.parse()
    }

    /// Keys of a dictionary in the order fast enumeration gives them.
    private static func keys(of dictionary: Any?) -> [Any] {
        guard let dictionary = dictionary as? NSDictionary else { return [] }
        var keys: [Any] = []
        var iterator = NSFastEnumerationIterator(dictionary)
        while let key = iterator.next() {
            keys.append(key)
        }
        return keys
    }

    @objc public func getWADOUrls() -> [Any] {
        let urls = NSMutableArray()

        let baseURL = String(format: "%@?requestType=WADO", (self.wadoURL ?? "(null)") as NSString)

        for StudyUID in Self.keys(of: studies) {
            let study = studies?.object(forKey: StudyUID)
            for SeriesUID in Self.keys(of: study) {
                let series = (study as? NSDictionary)?.object(forKey: SeriesUID)
                for SOPUID in Self.keys(of: series) {
                    let url = baseURL.appendingFormat("&studyUID=%@&seriesUID=%@&objectUID=%@&contentType=application/dicom%@",
                                                      StudyUID as! NSString, SeriesUID as! NSString, SOPUID as! NSString, "&useOrig=true")

                    guard let wado = NSURL(string: url) else {
                        NSException(name: .invalidArgumentException,
                                    reason: "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil", userInfo: nil).raise()
                        continue
                    }
                    urls.add(wado)
                }
            }
        }

        return urls as! [Any]
    }
}
