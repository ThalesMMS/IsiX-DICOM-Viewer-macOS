//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The tests' client of the Decompress XPC service (decompress_service.py builds
// it into an application bundle beside a copy of the service). It takes the
// command line the Decompress helper took and answers as it did, through the
// code the application calls (IsiXDatabase: DecompressService,
// DecompressConversion, ImportValidation):
//
//   client DEST|sameAsDestination compress|decompressList FILE...
//   client DEST|sameAsDestination SettingsPlist PLIST compress|decompressList FILE...
//   client unused testFiles FILE...      REFUSED<tab>FILE on the output for each refused
//   client DICOMDIR testDICOMDIR
//   client REPORT pdfFromURL             REPORT.pdf
//   client DEST isolation GOOD CRASHING GOOD2
//
// The conversions start from the factory preferences of the helper
// (IsiXPreferences, not the viewer's), with the plist laid over them; the
// application sends its own. A conversion the service did not survive exits
// 1 and says "service ended" on the standard error. `isolation` checks that a
// file that ends the service fails alone, in the same process, and prints one
// line per step.

import Foundation
import IsiXDatabase
import IsiXPreferences

setvbuf(stdout, nil, _IOLBF, 0)
var arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: client PATH MODE [FILE...]\n".utf8))
    exit(2)
}
guard let service = DecompressService.shared else {
    FileHandle.standardError.write(Data("no Decompress.xpc in this bundle's Contents/XPCServices\n".utf8))
    exit(2)
}

let path = arguments[0]
var mode = arguments[1]
var files = Array(arguments.dropFirst(2))
var laid: [AnyHashable: Any] = [:]
if mode == "SettingsPlist", files.count >= 2 {
    laid = NSDictionary(contentsOfFile: files[0]) as? [AnyHashable: Any] ?? [:]
    mode = files[1]
    files = Array(files.dropFirst(2))
}
// The factory values only for what the plist leaves out: making them takes
// some 30 ms, which the application, whose preferences are there already,
// does not spend on a call.
let preferences = (DecompressService.settingsKeys + ["DecompressMoveIfFail"]).contains(where: { laid[$0] == nil })
    ? DefaultPreferences.defaults(forViewer: false, appStore: false) : NSMutableDictionary()
preferences.addEntries(from: laid)
let settings = NSMutableDictionary()
for key in DecompressService.settingsKeys {
    if let value = preferences[key] { settings[key] = value }
}
let moveIfUnreadable = (preferences["DecompressMoveIfFail"] as AnyObject?)?.boolValue ?? false
let destination: String? = path == "sameAsDestination" ? nil : path

@MainActor func convert(_ files: [String], _ mode: DecompressConversion.Mode) -> DecompressConversion.Summary {
    let summary = DecompressConversion.run(files, mode: mode, destination: destination, settings: settings,
                                           moveIfUnreadable: moveIfUnreadable, converter: service)
    if summary.crashed { FileHandle.standardError.write(Data("service ended\n".utf8)) }
    return summary
}

switch mode {
case "compress", "decompressList":
    exit(convert(files, DecompressConversion.Mode(rawValue: mode)!).succeeded ? 0 : 1)

case "testFiles":
    // Written as soon as found, one line each, as the helper did.
    var refused = 0
    for file in files {
        guard let named = service.refusedFiles(among: [file], stop: { false }) else {
            FileHandle.standardError.write(Data("service ended\n".utf8))
            print(ImportValidation.refusedMarker + file)
            refused += 1
            continue
        }
        for each in named {
            print(ImportValidation.refusedMarker + each)
            refused += 1
        }
    }
    exit(refused == 0 ? 0 : 1)

case "testDICOMDIR":
    switch service.testDicomDir(atPath: path, timeout: 60) {
    case .success(true): exit(0)
    case .success(false): exit(1)
    case .failure(let error):
        FileHandle.standardError.write(Data("service: \(error)\n".utf8))
        exit(1)
    }

case "pdfFromURL":
    switch service.updateReportPDF(atPath: path, timeout: DecompressService.reportTimeout) {
    case .success(let replaced): exit(replaced ? 0 : 1)
    case .failure(let error):
        FileHandle.standardError.write(Data("service: \(error)\n".utf8))
        exit(1)
    }

case "isolation":
    guard files.count == 3 else { exit(2) }
    let (good, crashing, other) = (files[0], files[1], files[2])
    // 1. A list with the file that ends the service: the file before it is
    //    converted, the list stops there and reports it.
    let first = convert([good, crashing, other], .compress)
    print("list succeeded=\(first.succeeded) crashed=\(first.crashed)")
    // 2. The validation before importing refuses that file alone.
    let refused = ImportValidation.refusedFiles([other, crashing], tester: service, shouldStop: nil, whileWaiting: nil)
    print("refused=\(refused.map { ($0 as NSString).lastPathComponent }.joined(separator: ","))")
    // 3. The next call starts the service again and converts.
    let second = convert([other], .compress)
    print("after succeeded=\(second.succeeded) crashed=\(second.crashed)")
    exit(0)

default:
    FileHandle.standardError.write(Data("unknown mode \(mode)\n".utf8))
    exit(2)
}
