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

// Two selectors of DicomFile in the plugin SDK of Horos and OsiriX with
// nothing behind them now: the flag that said the files came from a CD, which
// nothing reads, and the decoder of NRRD files, which the application does not
// have. A plugin built for that SDK may still send them.
extension DicomFile {
    @objc(setFilesAreFromCDMedia:) nonisolated class func legacySetFilesAreFromCDMedia(_ fromCD: Bool) {
        FormerSDKFacade.inert("DicomFile", "+setFilesAreFromCDMedia:", because: "nothing reads this flag: files of a CD are told by their volume")
    }

    /// -1, the answer for a file that could not be decoded.
    @objc(getNRRDFile) nonisolated func legacyGetNRRDFile() -> Int16 {
        FormerSDKFacade.inert("DicomFile", "-getNRRDFile", because: "the application does not decode NRRD files")
        return -1
    }
}
