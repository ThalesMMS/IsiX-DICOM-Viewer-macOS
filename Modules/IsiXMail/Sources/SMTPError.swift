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

/// Why an SMTP delivery stopped. `reason` is the text the client logs, the
/// same the Objective-C client put in its NSException; `isInvalidArgument`
/// tells the errors it raised as NSInvalidArgumentException from the others,
/// raised as NSGenericException.
public enum SMTPError: Error, Equatable, Sendable {
    case invalidServerAddress
    case emptySender
    case emptyDestination
    /// An address with an unbalanced "<" or ">", sender or recipient alike.
    case invalidAddress
    /// A reply of code 500 or above.
    case serverError(code: Int, message: String?)
    /// TLS is required and the server does not offer STARTTLS.
    case startTLSUnsupported
    /// Credentials are set and the server offers none of CRAM-MD5, PLAIN or LOGIN.
    case noSupportedAuthentication
    /// A reply the session has no step for in its current state.
    case unexpectedReply(status: SMTPSession.Status, code: Int)
    /// A reply line without a code.
    case unparsableLine
    /// The server said nothing after the connection opened, and TLS is off.
    case stalledWithoutTLS
    /// A value of the wrong class where a string or number was expected: the
    /// message Objective-C gave when it sent the selector to it.
    case unrecognizedSelector(receiverClass: String, selector: String)

    public var isInvalidArgument: Bool {
        switch self {
        case .invalidServerAddress, .emptySender, .emptyDestination, .invalidAddress, .unrecognizedSelector:
            return true
        default:
            return false
        }
    }

    public var reason: String {
        switch self {
        case .invalidServerAddress: return "Invalid server address"
        case .emptySender: return "Empty sender email address"
        case .emptyDestination: return "Empty destination email address"
        case .invalidAddress: return "Invalid sender email address"
        case let .serverError(code, message): return "Error \(Int32(truncatingIfNeeded: code)): \(message ?? "(null)")"
        case .startTLSUnsupported: return "Server doesn't support STARTTLS"
        case .noSupportedAuthentication: return "The server doesn't allow any authentication techniques supported by this client."
        case let .unexpectedReply(status, code):
            return "Don't know how to act with status \(Int32(truncatingIfNeeded: status.rawValue)), code \(Int32(truncatingIfNeeded: code))"
        case .unparsableLine: return "Couldn't parse line"
        case .stalledWithoutTLS: return "Connection stalled, probably wants TLS handshake, user said no TLS"
        case let .unrecognizedSelector(receiverClass, selector): return "-[\(receiverClass) \(selector)]: unrecognized selector"
        }
    }
}
