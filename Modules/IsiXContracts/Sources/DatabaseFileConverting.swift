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

/// What a conversion does to the pixels of a file.
public enum FileConversionMode: Hashable, Sendable {
    case compress
    case decompress
}

/// Files to convert together, as the queue of a database keeps them.
public struct FileConversionBatch: Hashable, Sendable {
    public var files: [String]
    public let mode: FileConversionMode
    /// The folder the converted files go to; nil leaves each one where it is.
    public let destination: String?
    /// Files the scan of the incoming folder moved aside. Nothing else reads the
    /// folder they are in, so what the conversion leaves behind is indexed as it
    /// is, and two such batches waiting may become one.
    public let isFromScan: Bool

    public init(files: [String], mode: FileConversionMode, destination: String?, isFromScan: Bool) {
        self.files = files
        self.mode = mode
        self.destination = destination
        self.isFromScan = isFromScan
    }
}

/// Compressing and decompressing the files of a database.
public protocol DatabaseFileConverting: Sendable {
    /// Converts `paths` on the calling thread, one helper at a time. Whether every helper succeeded.
    func convertNow(_ paths: [String], mode: FileConversionMode, into destination: String?) -> Bool

    /// Converts `paths` on the calling thread, which waits for the chunks it
    /// shares out, under the lock of the database. Throws when a chunk failed.
    func convertInChunks(_ paths: [String], mode: FileConversionMode, into destination: String?) throws

    /// Queues `paths` for the worker of the database and returns at once.
    func convertLater(_ paths: [String], mode: FileConversionMode, into destination: String?)

    /// Whether a batch is waiting or being converted now. Never waits.
    var isConverting: Bool { get }
}

/// The worker of one database, as `ConversionQueue` starts it.
///
/// Sent from the queue's actor: nothing here but `run` may wait, and `run`
/// converts on a thread of its own, never on the actor.
public protocol ConversionRunning: Sendable {
    /// What names the database. A database and its independent databases share it.
    var conversionIdentifier: String { get }

    /// Converts one batch. Returns when it has ended, whatever became of it.
    func run(_ batch: FileConversionBatch) async

    /// More files joined the queue while a batch is being converted: `count` wait now.
    /// Never waits, and may be called from any thread.
    func filesQueued(_ count: Int)
}
