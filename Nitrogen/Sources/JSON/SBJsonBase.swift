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
/*
 Copyright (C) 2009 Stig Brautaset. All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 
 * Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
 
 * Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
 
 * Neither the name of the author nor the names of its contributors may be used
   to endorse or promote products derived from this software without specific
   prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE
 FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

import Foundation

/// The implementation of SBJsonBase, declared in SBJsonBase.h: the error
/// trace and the nesting limit the JSON parser and writer of the plugin SDK
/// of Horos and OsiriX share.
@objc @implementation extension SBJsonBase {
    /// The errors of the last call that failed, each with the one before it
    /// as its underlying error; nil when there is none.
    private final var trace: NSMutableArray?

    var maxDepth: UInt = 512

    override init() {
        super.init()
    }

    var errorTrace: [Any]! {
        trace.map { $0.copy() as? [Any] ?? [] }
    }

    @objc(addErrorWithCode:description:)
    func addError(withCode code: UInt, description str: String!) {
        let description = str ?? "(null)"
        let userInfo: [String: Any]
        if let last = trace?.lastObject {
            userInfo = [NSLocalizedDescriptionKey: description, NSUnderlyingErrorKey: last]
        } else {
            userInfo = [NSLocalizedDescriptionKey: description]
        }
        let error = NSError(domain: SBJsonCompatibleWriter.errorDomain, code: Int(bitPattern: code), userInfo: userInfo)

        willChangeValue(forKey: "errorTrace")
        if trace == nil {
            trace = NSMutableArray()
        }
        trace?.add(error)
        didChangeValue(forKey: "errorTrace")
    }

    func clearErrorTrace() {
        willChangeValue(forKey: "errorTrace")
        trace = nil
        didChangeValue(forKey: "errorTrace")
    }

    /// Takes the trace another parser or writer left, as the SBJSON facade
    /// took that of the object it had forwarded to.
    final func adoptErrorTrace(of other: SBJsonBase) {
        trace = other.trace.map { NSMutableArray(array: $0) }
    }

    /// Adds, one by one, the errors a shared parser or writer reported:
    /// through -addErrorWithCode:description:, so that a subclass that
    /// overrides it and an observer of errorTrace see each of them.
    final func addErrors(_ errors: [NSError]) {
        for error in errors {
            addError(withCode: UInt(bitPattern: error.code), description: error.localizedDescription)
        }
    }
}
