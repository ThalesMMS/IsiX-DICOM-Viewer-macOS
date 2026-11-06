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
import IsiXDICOMNetwork

/// A WADO query manifest, read by `WADOQueryManifest`: the studies, series
/// and instances it lists, and one WADO-URI request for each instance.
@objc(WADOXML)
public final class WADOXML: NSObject {
    /// Study UID to series UID to SOP Instance UID, each mapped to an empty
    /// dictionary, as the manifest lists them; nil before a manifest is read.
    @objc public private(set) var studies: NSMutableDictionary?

    @objc public var studyInstanceUID: String?
    @objc public var seriesInstanceUID: String?
    @objc public var SOPInstanceUID: String?
    @objc public var wadoURL: String?

    private var manifest = WADOQueryManifest()

    @objc(parseURL:)
    public func parseURL(_ url: URL?) {
        guard let url, let manifest = WADOQueryManifest.parse(contentsOf: url) else { return }
        self.manifest = manifest
        wadoURL = manifest.wadoURL
        studyInstanceUID = manifest.studies.last?.uid
        seriesInstanceUID = manifest.studies.last?.series.last?.uid
        let studies = NSMutableDictionary()
        for study in manifest.studies {
            let series = NSMutableDictionary()
            for one in study.series {
                let instances = NSMutableDictionary()
                for instance in one.instances { instances[instance] = NSMutableDictionary() }
                series[one.uid] = instances
            }
            studies[study.uid] = series
        }
        self.studies = studies
    }

    /// One URL per instance, each asking for the original transfer syntax,
    /// from the `wadoURL` set last.
    @objc public func getWADOUrls() -> [Any] {
        var manifest = self.manifest
        manifest.wadoURL = wadoURL
        return manifest.urls()
    }
}
