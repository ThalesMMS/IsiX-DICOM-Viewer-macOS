//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("HorosStoredPrint: \(message)\n").utf8))
    exit(status)
}

// Only the native app's file-print contract is supported. There is no spooler
// or retry path: repeating an accepted N-ACTION could duplicate printed pages.
var options: [String: String] = [:]
var jobs: [String] = []
let allowed = ["-c", "-lc", "--printer", "--copies", "--priority", "--destination", "--medium-type"]
let arguments = Array(CommandLine.arguments.dropFirst())
var index = 0
while index < arguments.count {
    let argument = arguments[index]
    if allowed.contains(argument) {
        index += 1
        guard index < arguments.count, options[argument] == nil else { fail("invalid option \(argument)", status: 2) }
        options[argument] = arguments[index]
    } else {
        guard !argument.hasPrefix("-"), !argument.isEmpty else { fail("unsupported argument \(argument)", status: 2) }
        jobs.append(argument)
    }
    index += 1
}
guard !jobs.isEmpty else { fail("no Stored Prints", status: 2) }
guard let config = options["-c"], FileManager.default.isReadableFile(atPath: config),
      let printer = options["--printer"], !printer.isEmpty,
      let copies = UInt32(options["--copies"] ?? "1"), (1...100).contains(copies) else {
    fail("invalid configuration, printer or copies", status: 2)
}
let logger = options["-lc"] ?? ""
if !logger.isEmpty && !FileManager.default.isReadableFile(atPath: logger) { fail("unreadable logger configuration", status: 2) }
let priority = options["--priority"] ?? "MED"
let destination = options["--destination"] ?? "PROCESSOR"
let medium = options["--medium-type"] ?? "PAPER"
guard let context = HorosStoredPrintOpen(config, logger, printer, copies, priority, destination, medium) else {
    fail("cannot initialize printer")
}
var status: Int32 = 0
for filename in jobs {
    let result = HorosStoredPrintSend(context, filename)
    if result.operationStatus != 0 || result.cleanupStatus != 0 || result.releaseStatus != 0 {
        FileHandle.standardError.write(Data(("HorosStoredPrint: operation=\(result.operationStatus) cleanup=\(result.cleanupStatus) release=\(result.releaseStatus) accepted=\(result.printAccepted); batch stopped, no retry\n").utf8))
        status = 1
        break
    }
}
HorosStoredPrintClose(context)
exit(status)
