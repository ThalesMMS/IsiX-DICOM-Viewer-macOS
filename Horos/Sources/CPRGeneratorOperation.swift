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

import Cocoa

/// The key paths the CPR operations post and observe, made once as NSStrings.
/// A Swift literal passed as a key path is bridged to a new string
/// object on every call ("isFinished" and "isExecuting" do not fit in a tagged
/// pointer), which Key-Value Observing then copies, hashes and compares the
/// slow way; the Objective-C passed constant strings. A String made from an
/// NSString bridges back to that same object.
enum CPROperationKeyPath {
    static let isFinished = NSString(string: "isFinished") as String
    static let isExecuting = NSString(string: "isExecuting") as String
    static let didFail = NSString(string: "didFail") as String
}

/// The operation a CPRGeneratorRequest names in -operationClass; CPRGenerator
/// runs it and reads generatedVolume when it finishes.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/CPRGeneratorOperation.h> are those of the former class. Open, because
/// CPRStraightenedOperation, CPRStretchedOperation and CPRObliqueSliceOperation
/// subclass it.
///
/// @unchecked Sendable, restated from Operation: the request and the volume are
/// constant, and `generatedVolume` is read and written only under its lock.
/// Each subclass states what it adds.
@objc(CPRGeneratorOperation)
open class CPRGeneratorOperation: Operation, @unchecked Sendable {
    private let _request: CPRGeneratorRequest?
    private let _volumeData: CPRVolumeData?

    /// Atomic in the former header: written on the thread that finishes the
    /// operation and read by CPRGenerator on the main thread, so it is kept
    /// behind a lock.
    private let generatedVolumeLock = NSLock()
    private var _generatedVolume: CPRVolumeData?

    /// -initWithRequest:volumeData: of every subclass; `required`, because
    /// CPRGenerator creates the operation from the request's -operationClass.
    @objc(initWithRequest:volumeData:)
    public required init(request: CPRGeneratorRequest?, volumeData: CPRVolumeData?) {
        _request = request
        _volumeData = volumeData
        super.init()
    }

    /// -init of NSOperation left the request and the volume nil, as this does.
    @objc public override convenience init() {
        self.init(request: nil, volumeData: nil)
    }

    @objc open var request: CPRGeneratorRequest? {
        return _request
    }

    @objc public var volumeData: CPRVolumeData? {
        return _volumeData
    }

    @objc open var didFail: Bool {
        return false
    }

    @objc public dynamic var generatedVolume: CPRVolumeData? {
        get {
            generatedVolumeLock.lock()
            defer { generatedVolumeLock.unlock() }
            return _generatedVolume
        }
        set {
            generatedVolumeLock.lock()
            _generatedVolume = newValue
            generatedVolumeLock.unlock()
        }
    }
}
