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
 Copyright (C) 2007-2009 Stig Brautaset. All rights reserved.
 
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

/// The implementation of SBJSON, declared in SBJSON.h: the facade of the
/// plugin SDK of Horos and OsiriX over one SBJsonParser and one SBJsonWriter,
/// whose options it forwards and whose error trace it takes when a call fails.
@objc @implementation extension SBJSON {
    // jsonWriter and jsonParser of the header of an older SDK, which a plugin
    // built with it binds by name when it loads: stored fields with the type
    // the C declaration has in memory, never private or constant.
    final var jsonWriter: SBJsonWriter? = SBJsonWriter()
    final var jsonParser: SBJsonParser? = SBJsonParser()

    /// The writer, and the parser below: another one, with the defaults, when
    /// a plugin left the field nil.
    private final var writer: SBJsonWriter {
        if let jsonWriter { return jsonWriter }
        let made = SBJsonWriter()
        jsonWriter = made
        return made
    }

    private final var parser: SBJsonParser {
        if let jsonParser { return jsonParser }
        let made = SBJsonParser()
        jsonParser = made
        return made
    }

    override init() {
        super.init()
    }

    // MARK: Writer

    @objc(stringWithObject:)
    func string(with value: Any!) -> String! {
        if let repr = writer.string(with: value) {
            return repr
        }
        adoptErrorTrace(of: writer)
        return nil
    }

    /// The JSON of `value`, a string or a number alone included when
    /// `allowScalar`; nil on error, with the last error of the trace in
    /// `error` when it is not NULL.
    @objc(stringWithObject:allowScalar:error:)
    func string(with value: Any!, allowScalar: Bool, error: NSErrorPointer) -> String! {
        let json = allowScalar ? writer.string(withFragment: value) : writer.string(with: value)
        if let json {
            return json
        }
        adoptErrorTrace(of: writer)
        error?.pointee = errorTrace?.last as? NSError
        return nil
    }

    @objc(stringWithFragment:error:)
    func string(withFragment value: Any!, error: NSErrorPointer) -> String! {
        string(with: value, allowScalar: true, error: error)
    }

    @objc(stringWithObject:error:)
    func string(with value: Any!, error: NSErrorPointer) -> String! {
        string(with: value, allowScalar: false, error: error)
    }

    // MARK: Parsing

    @objc(objectWithString:)
    func object(with repr: String!) -> Any! {
        if let object = parser.object(with: repr) {
            return object
        }
        adoptErrorTrace(of: parser)
        return nil
    }

    /// The object `value`, a JSON text, stands for, a string or a number alone
    /// included when `allowScalar`; nil on error, with the last error of the
    /// trace in `error` when it is not NULL.
    @objc(objectWithString:allowScalar:error:)
    func object(withString value: Any!, allowScalar: Bool, error: NSErrorPointer) -> Any! {
        let object = allowScalar ? parser.fragment(withString: value) : parser.object(with: value as? String)
        if let object {
            return object
        }
        adoptErrorTrace(of: parser)
        error?.pointee = errorTrace?.last as? NSError
        return nil
    }

    @objc(fragmentWithString:error:)
    func fragment(with repr: String!, error: NSErrorPointer) -> Any! {
        object(withString: repr, allowScalar: true, error: error)
    }

    @objc(objectWithString:error:)
    func object(with repr: String!, error: NSErrorPointer) -> Any! {
        object(withString: repr, allowScalar: false, error: error)
    }

    // MARK: Properties - parsing

    public override var maxDepth: UInt {
        get { parser.maxDepth }
        set {
            writer.maxDepth = newValue
            parser.maxDepth = newValue
        }
    }

    // MARK: Properties - writing

    var humanReadable: Bool {
        get { writer.humanReadable }
        set { writer.humanReadable = newValue }
    }

    var sortKeys: Bool {
        get { writer.sortKeys }
        set { writer.sortKeys = newValue }
    }
}
