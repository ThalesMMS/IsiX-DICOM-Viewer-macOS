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

/// What tests the files of a chunk for the validation before importing: the
/// Decompress service in the application, a stand-in in the tests.
public protocol ImportValidationTester: Sendable {
    /// Tests `files` one after the other, asking `stop` before each: the files
    /// that cannot be read, in the order of `files`, or nil when the tester
    /// ended without saying which of its files did it (the service crashed).
    func refusedFiles(among files: [String], stop: @Sendable () -> Bool) -> [String]?
}

/// The validation before importing: the Decompress service loads the first
/// frame of each file the importer copied, as the viewer would, and says
/// which of them cannot be read. Only those are refused; the others of the
/// batch are imported.
///
/// The batch is cut into chunks, tested at the same time. A chunk whose test
/// ended without naming the file - a file that brings the decoder down ends
/// the service, and every chunk it was testing with it - is tested again one
/// file at a time, so only the file that cannot be read is refused. That costs
/// one call per file of the chunk, and only for a chunk the service did not
/// survive.
@objc(IsiXImportValidation)
public final class ImportValidation: NSObject {

    /// What the helper wrote before the path of a file that cannot be read,
    /// and the harness of the tests still writes.
    public static let refusedMarker = "REFUSED\t"

    /// The number of files per chunk: the batch shared among the processors,
    /// plus 20, and never more than 500.
    public static func chunkSize(fileCount: Int, processorCount: Int) -> Int {
        let share = fileCount / max(processorCount, 1)
        return share > 500 ? 500 : share + 20
    }

    /// The files of `files` that an output in the helper's form names as
    /// refused, in the order of `files`. Lines that are not of that form, or
    /// that name a file it was not given, are ignored.
    public static func refusedFiles(inOutput output: String, of files: [String]) -> [String] {
        var named = Set<String>()
        for line in output.split(separator: "\n", omittingEmptySubsequences: true)
        where line.hasPrefix(refusedMarker) {
            named.insert(String(line.dropFirst(refusedMarker.count)))
        }
        return files.filter { named.contains($0) }
    }

    /// The first `limit` paths, one per line, and an ellipsis when there are
    /// more: what the notice to the user names.
    @objc(listOfRefusedFiles:limit:)
    public static func list(ofRefusedFiles paths: [String], limit: Int) -> String {
        var lines = Array(paths.prefix(max(limit, 0)))
        if paths.count > lines.count { lines.append("…") }
        return lines.joined(separator: "\n")
    }

    /// One chunk tested on a thread of its own.
    private final class Run: @unchecked Sendable {
        let files: [String]
        private let tester: ImportValidationTester
        private let lock = NSLock()
        private var finished = false
        private var stopped = false
        private var named: [String]?

        init(files: [String], tester: ImportValidationTester) {
            self.files = files
            self.tester = tester
        }

        func launch() {
            Thread.detachNewThread { [self] in
                let result = autoreleasepool {
                    tester.refusedFiles(among: files, stop: { [self] in
                        lock.lock()
                        defer { lock.unlock() }
                        return stopped
                    })
                }
                lock.lock()
                named = result
                finished = true
                lock.unlock()
            }
        }

        var isRunning: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !finished
        }

        func interrupt() {
            lock.lock()
            stopped = true
            lock.unlock()
        }

        /// The files the tester named, or nil when it does not say which of
        /// its files failed.
        func refused() -> [String]? {
            lock.lock()
            defer { lock.unlock() }
            return named.map { named in files.filter { named.contains($0) } }
        }
    }

    /// Tests `files` with `tester` and returns the files that cannot be read,
    /// in the order of `files`. `shouldStop` is asked while waiting, and
    /// `whileWaiting` called, every 50 ms; once stopped, the chunks still
    /// running are interrupted and the files they had not finished are not
    /// refused.
    public static func refusedFiles(_ files: [String], tester: ImportValidationTester,
                                    shouldStop: (() -> Bool)?, whileWaiting: (() -> Void)?) -> [String] {
        if files.isEmpty { return [] }
        let size = chunkSize(fileCount: files.count, processorCount: ProcessInfo.processInfo.processorCount)
        let runs = stride(from: 0, to: files.count, by: size).map {
            Run(files: Array(files[$0..<min($0 + size, files.count)]), tester: tester)
        }
        runs.forEach { $0.launch() }

        var refused = Set<String>()
        var stopped = false
        for run in runs {
            stopped = wait(for: run, shouldStop: shouldStop, whileWaiting: whileWaiting)
            if stopped { break }
            if let named = run.refused() {
                refused.formUnion(named)
                continue
            }
            NSLog("Validation before importing: the test of %d files ended without naming the file; testing them one by one",
                  run.files.count)
            for file in run.files {
                let single = Run(files: [file], tester: tester)
                single.launch()
                stopped = wait(for: single, shouldStop: shouldStop, whileWaiting: whileWaiting)
                if stopped { break }
                // Alone in its test, a file that fails is that file.
                if single.refused() != [] { refused.insert(file) }
            }
            if stopped { break }
        }
        if stopped {
            for run in runs where run.isRunning { run.interrupt() }
        }
        return files.filter { refused.contains($0) }
    }

    /// Waits for `run` to end; true when `shouldStop` said to stop first.
    private static func wait(for run: Run, shouldStop: (() -> Bool)?, whileWaiting: (() -> Void)?) -> Bool {
        while run.isRunning {
            if shouldStop?() == true { run.interrupt(); return true }
            Thread.sleep(forTimeInterval: 0.05)
            whileWaiting?()
        }
        return shouldStop?() == true
    }
}

extension DecompressService: ImportValidationTester {
    /// Loads the first frame of each file in the service. A file that is not
    /// there is not tested, and a service that cannot be started leaves the
    /// files it did not test untested.
    public func refusedFiles(among files: [String], stop: @Sendable () -> Bool) -> [String]? {
        var refused: [String] = []
        for file in files {
            if stop() { break }
            guard FileManager.default.fileExists(atPath: file) else {
                NSLog("-- testFiles: %@ does not exist", file)
                continue
            }
            switch testFile(atPath: file) {
            case .success(true):
                continue
            case .success(false):
                NSLog("-- testFiles: %@ could not be loaded", file)
                refused.append(file)
            case .failure(.crashed), .failure(.timedOut):
                return nil
            case .failure:
                NSLog("Validation before importing: the Decompress service did not start; %d files not tested",
                      files.count - refused.count)
                return refused
            }
        }
        return refused
    }
}
