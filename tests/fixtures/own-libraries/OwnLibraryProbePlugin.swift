//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// A version 1 plugin that carries its own ITK (ITKStateProbe.cpp, compiled into
// the bundle), for tests/test-plugin-own-libraries.py and the in-app check.
// When it activates it reports what its copy of ITK holds before it touches
// anything, then sets its copy's settings (8 threads, its own output window)
// and reports again; the "report" command reports once more. `description`
// returns the reports as a JSON array; with ISIX_OWN_LIBRARY_PROBE_REPORT set
// in the environment, each report is also appended to that file, one per line.

import Foundation
import IsiXPluginKit
import Synchronization

public final class OwnLibraryProbePlugin: IsiXPlugin, CustomStringConvertible {
    private let reports = Mutex<[String]>([])

    public init() {}

    public nonisolated var description: String { reports.withLock { "[" + $0.joined(separator: ",") + "]" } }

    private func record(_ report: UnsafePointer<CChar>) {
        let line = String(cString: report)
        reports.withLock { $0.append(line) }
        if let path = ProcessInfo.processInfo.environment["ISIX_OWN_LIBRARY_PROBE_REPORT"],
           let file = FileHandle(forWritingAtPath: path) ?? (FileManager.default.createFile(atPath: path, contents: nil) ? FileHandle(forWritingAtPath: path) : nil) {
            file.seekToEndOfFile()
            file.write(Data((line + "\n").utf8))
            file.closeFile()
        }
    }

    public func activate(with context: IsiXPluginContext) throws {
        record(isix_plugin_probe_report())
        record(isix_plugin_probe_configure(8))
        try context.register(IsiXCommand(id: "report", title: "Own Library Probe: Report")) { [weak self] _ in
            self?.record(isix_plugin_probe_report())
        }
    }
}
