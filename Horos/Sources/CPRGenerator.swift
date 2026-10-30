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

/// The run loop mode -runUntilAllRequestsAreFinished runs in.
private let CPRGeneratorRunLoopMode = "_CPRGeneratorRunLoopMode"
private let generatorQueueContext = IdentityToken()

/// assert() of the Objective-C: checked in Debug only.
@inline(__always)
private func debugAssert(_ condition: @autoclosure () -> Bool) {
    #if DEBUG
    precondition(condition())
    #endif
}

@objc(CPRGeneratorDelegate)
public protocol CPRGeneratorDelegate: NSObjectProtocol {
    @objc(generator:didGenerateVolume:request:)
    func generator(_ generator: CPRGenerator, didGenerateVolume volume: CPRVolumeData, request: CPRGeneratorRequest)

    @objc(generator:didAbandonRequest:)
    optional func generator(_ generator: CPRGenerator, didAbandonRequest request: CPRGeneratorRequest)
}

/// Runs CPRGeneratorRequests on a volume, on an operation queue, and gives the
/// generated volumes to its delegate on the main thread.
///
/// Implemented in Swift: the Objective-C name, the selectors, the
/// CPRGeneratorDelegate protocol and <Horos/CPRGenerator.h> are those of the
/// former class.
@objc(CPRGenerator)
public final class CPRGenerator: NSObject {
    private let generatorQueue: OperationQueue
    private let observedOperations = NSMutableSet()
    private let finishedOperations = NSMutableArray()

    private let generatedFrameTimes = NSMutableArray()
    // These request generations belong to the main thread, as do submissions
    // and delegate delivery. Worker KVO only appends to finishedOperations.
    private var nextInteractiveGeneration: UInt64 = 0
    private var presentedInteractiveGeneration: UInt64 = 0
    private var interactiveGenerations: [ObjectIdentifier: UInt64] = [:]
    private var previewOperation: ObjectIdentifier?

    /// `assign` in the former header; weak here, so that a delegate that goes
    /// away without clearing it is not messaged.
    @objc public weak var delegate: CPRGeneratorDelegate?
    @objc public let volumeData: CPRVolumeData?

    private static let synchronousRequestQueue: OperationQueue = {
        let queue = OperationQueue()
        var threads = ProcessInfo.processInfo.processorCount
        if threads > 2 {
            threads = 2
        }
        queue.maxConcurrentOperationCount = threads
        return queue
    }()

    /// The operation the request names, or nil for a request without one.
    private static func operation(for request: CPRGeneratorRequest?, volumeData: CPRVolumeData?) -> CPRGeneratorOperation? {
        guard let operationClass = request?.operationClass() as? CPRGeneratorOperation.Type else {
            return nil
        }
        return operationClass.init(request: request, volumeData: volumeData)
    }

    @objc(synchronousRequestVolume:volumeData:)
    public static func synchronousRequestVolume(_ request: CPRGeneratorRequest?, volumeData: CPRVolumeData?) -> CPRVolumeData? {
        let operation = CPRGenerator.operation(for: request, volumeData: volumeData)
        operation?.queuePriority = .veryHigh
        let operationQueue = synchronousRequestQueue
        guard let operation else {
            // -[NSOperationQueue addOperation:nil] of the former code.
            NSException(name: .invalidArgumentException, reason: "*** -[NSOperationQueue addOperation:]: operation is nil", userInfo: nil).raise()
            return nil
        }
        operationQueue.addOperation(operation)
        // Other callers share the queue's concurrency limit, not this result.
        operation.waitUntilFinished()
        return operation.generatedVolume
    }

    @objc(initWithVolumeData:)
    public init(volumeData: CPRVolumeData?) {
        debugAssert(Thread.isMainThread)

        self.volumeData = volumeData
        generatorQueue = OperationQueue()

        var threads = ProcessInfo.processInfo.processorCount
        if threads > 2 {
            threads = 2
        }

        generatorQueue.maxConcurrentOperationCount = threads
        super.init()
    }

    @objc public override convenience init() {
        self.init(volumeData: nil)
    }

    /// Must be called on the main thread. Delegate callbacks will happen, but this
    /// method will not return until all outstanding requests have been processed.
    @objc public func runUntilAllRequestsAreFinished() {
        debugAssert(Thread.isMainThread)

        while observedOperations.count > 0 {
            RunLoop.main.run(mode: RunLoop.Mode(CPRGeneratorRunLoopMode), before: .distantFuture)
        }
    }

    @objc(requestVolume:)
    public func requestVolume(_ request: CPRGeneratorRequest?) {
        enqueue(request, interactive: false)
    }

    /// Keeps one running preview so continuous dragging still makes progress.
    /// A second obsolete operation cooperatively yields its slot to the latest
    /// request. Only monotonically newer previews can be delivered.
    @objc(requestInteractiveVolume:)
    public func requestInteractiveVolume(_ request: CPRGeneratorRequest?) {
        enqueue(request, interactive: true)
    }

    private func enqueue(_ request: CPRGeneratorRequest?, interactive: Bool) {
        debugAssert(Thread.isMainThread)
        guard let operation = CPRGenerator.operation(for: request?.copy() as? CPRGeneratorRequest, volumeData: volumeData) else {
            NSException(name: .invalidArgumentException, reason: "*** -[__NSSetM addObject:]: object cannot be nil", userInfo: nil).raise()
            return
        }
        if interactive {
            nextInteractiveGeneration += 1
            if previewOperation == nil {
                // Protect the newest running request, not an arbitrary set entry.
                previewOperation = observedOperations.compactMap { $0 as? CPRGeneratorOperation }
                    .filter { $0.isExecuting && !$0.isCancelled && !$0.isFinished && interactiveGenerations[ObjectIdentifier($0)] != nil }
                    .max { interactiveGenerations[ObjectIdentifier($0)]! < interactiveGenerations[ObjectIdentifier($1)]! }
                    .map { ObjectIdentifier($0) }
            }
        }
        for case let old as Operation in observedOperations where !old.isFinished {
            let key = ObjectIdentifier(old)
            if !old.isExecuting || (interactive && interactiveGenerations[key] != nil && key != previewOperation) {
                old.cancel()
            }
        }
        operation.queuePriority = .normal
        if interactive { interactiveGenerations[ObjectIdentifier(operation)] = nextInteractiveGeneration }
        _ = Unmanaged.passUnretained(self).retain()
        operation.addObserver(self, forKeyPath: CPROperationKeyPath.isFinished, options: [], context: generatorQueueContext.pointer)
        observedOperations.add(operation)
        generatorQueue.addOperation(operation)
    }

    /// Must be called on the main thread. Cancels in-flight and queued requests;
    /// the original volume and caller markings are untouched.
    @objc public func cancelOutstandingRequests() {
        debugAssert(Thread.isMainThread)

        for case let operation as Operation in observedOperations {
            operation.cancel()
        }
    }

    @objc public func frameRate() -> CGFloat {
        debugAssert(Thread.isMainThread)

        _cullGeneratedFrameTimes()
        return CGFloat(generatedFrameTimes.count) / 4.0
    }

    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard context == generatorQueueContext.pointer else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        debugAssert(object is CPRGeneratorOperation)
        let generatorOperation = object as! CPRGeneratorOperation

        if keyPath == CPROperationKeyPath.isFinished {
            if generatorOperation.isFinished {
                objc_sync_enter(finishedOperations)
                finishedOperations.add(generatorOperation)
                objc_sync_exit(finishedOperations)
                performSelector(onMainThread: #selector(_didFinishOperation), with: nil, waitUntilDone: false,
                                modes: [RunLoop.Mode.common.rawValue, CPRGeneratorRunLoopMode])
            }
        }
    }

    @objc private func _didFinishOperation() {
        debugAssert(Thread.isMainThread)

        var sentGeneratedVolume = false

        objc_sync_enter(finishedOperations)
        let completed = self.finishedOperations.copy() as! [CPRGeneratorOperation]
        self.finishedOperations.removeAllObjects()
        objc_sync_exit(self.finishedOperations)
        // Several workers may finish before the main run loop drains callbacks.
        // Prefer the newest interactive generation, not the last worker to end.
        // Requests using the original API retain their completion ordering.
        let finishedOperations = completed.enumerated().sorted { lhs, rhs in
            let a = interactiveGenerations[ObjectIdentifier(lhs.element)] ?? 0
            let b = interactiveGenerations[ObjectIdentifier(rhs.element)] ?? 0
            return a == b ? lhs.offset < rhs.offset : a < b
        }.map { $0.element }

        var i = finishedOperations.count - 1
        while i >= 0 {
            let operation = finishedOperations[i]
            operation.removeObserver(self, forKeyPath: CPROperationKeyPath.isFinished)
            _ = Unmanaged.passUnretained(self).autorelease() // to match the retain in -[CPRGenerator requestVolume:]

            let key = ObjectIdentifier(operation)
            let generation = interactiveGenerations.removeValue(forKey: key)
            let eligible = generation.map { $0 > presentedInteractiveGeneration && ($0 == nextInteractiveGeneration || key == previewOperation) } ?? true
            if key == previewOperation { previewOperation = nil }
            let volumeData = operation.generatedVolume
            if let volumeData, operation.isCancelled == false, sentGeneratedVolume == false, eligible {
                if let generation { presentedInteractiveGeneration = generation }
                generatedFrameTimes.add(Date())
                _cullGeneratedFrameTimes()
                if let delegate, delegate.responds(to: #selector(CPRGeneratorDelegate.generator(_:didGenerateVolume:request:))) {
                    delegate.generator(self, didGenerateVolume: volumeData, request: operation.request!)
                }
                sentGeneratedVolume = true
            } else {
                if let delegate, delegate.responds(to: #selector(CPRGeneratorDelegate.generator(_:didAbandonRequest:))) {
                    delegate.generator?(self, didAbandonRequest: operation.request!)
                }
            }
            observedOperations.remove(operation)
            i -= 1
        }
    }

    private func _cullGeneratedFrameTimes() {
        debugAssert(Thread.isMainThread)

        // remove times that are older than 4 seconds
        var done = false
        while !done {
            if generatedFrameTimes.count > 0 && (generatedFrameTimes.object(at: 0) as! Date).timeIntervalSinceNow < -4.0 {
                generatedFrameTimes.removeObject(at: 0)
            } else {
                done = true
            }
        }
    }

    @objc(_logFrameRate:)
    private func _logFrameRate(_ timer: Timer?) {
        NSLog("CPRGenerator frame rate: %f", frameRate())
    }
}
