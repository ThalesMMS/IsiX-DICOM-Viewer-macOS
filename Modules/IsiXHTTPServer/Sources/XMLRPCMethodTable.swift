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

/// The methods the app's XML-RPC interface publishes, by the name a caller
/// sends, and the Objective-C selector that answers each.
///
/// The names are a public contract: RIS integrations, scripts, horos:// links
/// and AppleScript call them. They are matched without regard to case, as the
/// first XML-RPC interface of OsiriX matched them, and `DBWindowFind` is the
/// former name of `FindObject`. A name that is not here is not dispatched,
/// whatever the interface happens to respond to.
public enum XMLRPCMethodTable {
    /// Lowercased method name to selector.
    public static let selectors: [String: String] = [
        "killosirix": "KillOsiriX:error:",
        "downloadurl": "DownloadURL:error:",
        "displaystudy": "DisplayStudy:error:",
        "displayseries": "DisplaySeries:error:",
        "dbwindowfind": "FindObject:error:",
        "findobject": "FindObject:error:",
        "switchtodefaultdbifneeded": "SelectDefaultDatabase:error:",
        "opendb": "OpenDatabase:error:",
        "selectalbum": "SelectAlbum:error:",
        "closeallwindows": "CloseAllWindows:error:",
        "getdisplayed2dviewerseries": "GetDisplayed2DViewerSeries:error:",
        "getdisplayed2dviewerstudies": "GetDisplayed2DViewerStudies:error:",
        "close2dviewerwithseriesuid": "Close2DViewerWithSeriesUID:error:",
        "close2dviewerwithstudyuid": "Close2DViewerWithStudyUID:error:",
        "retrieve": "Retrieve:error:",
        "cmove": "CMove:error:",
        "displaystudylistbypatientname": "DisplayStudyListByPatientName:error:",
        "displaystudylistbypatientid": "DisplayStudyListByPatientId:error:",
        "pathtofrontdcm": "PathToFrontDCM:error:",
    ]

    /// The selector that answers `methodName`, or nil for a name the interface
    /// does not publish.
    public static func selector(forMethodName methodName: String) -> String? {
        selectors[methodName.lowercased()]
    }
}

/// How the interface's methods encode their answer.
///
/// A method answers a struct whose `error` member is a code written as text:
/// "0" when the order was taken, a negative code when it could not be carried
/// out. A request the method cannot read at all (a missing parameter) fails
/// the call instead, with an HTTP-level code (400) whose response document is
/// the same struct.
public enum XMLRPCMethodResult {
    /// The `error` member for `code`: the code as a 32-bit integer in decimal,
    /// as `%d` of `(int) code` wrote it.
    public static func errorMember(_ code: Int) -> String {
        String(Int32(truncatingIfNeeded: code))
    }

    /// The response document of a failed call, which the failure carries as
    /// its description.
    public static func errorDocument(code: Int) -> String {
        "<?xml version=\"1.0\"?><methodResponse><params><param><value><struct><member><name>error</name><value>"
            + errorMember(code)
            + "</value></member></struct></value></param></params></methodResponse>"
    }
}
