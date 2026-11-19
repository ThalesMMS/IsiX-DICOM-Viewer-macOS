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

// Selectors of DCMPix in the plugin SDK of Horos and OsiriX that named how the
// image was read then: by the DCM Framework, whose parsed files were cached,
// and through a pipeline of 32 bits a preference turned on. Images are read by
// DCMTK alone, in floating point; a plugin built for that SDK may still send
// these.
extension DCMPix {
    /// Reads the image, as the reader of the DCM Framework did: by the reader there is.
    @objc(loadDICOMDCMFramework) func legacyLoadDICOMDCMFramework() -> Bool { loadDICOM() }

    @objc(clearCachedDCMFrameworkFiles) func legacyClearCachedDCMFrameworkFiles() {
        FormerSDKFacade.inert("DCMPix", "-clearCachedDCMFrameworkFiles", because: "no parsed file of the DCM Framework is cached: DCMTK reads the images")
    }

    @objc(full32bitPipeline) func legacyFull32bitPipeline() -> Bool { false }
    @objc(setFull32bitPipeline:) func legacySetFull32bitPipeline(_ on: Bool) {
        FormerSDKFacade.inert("DCMPix", "-setFull32bitPipeline:", because: "the display pipeline has one precision, which no preference changes")
    }
}
