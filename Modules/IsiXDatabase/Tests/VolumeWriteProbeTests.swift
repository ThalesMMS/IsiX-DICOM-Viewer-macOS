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
import Testing
@testable import IsiXDatabase

/// A folder standing for a volume, with an exam already on it; removed at the end.
private final class Volume {
    let root: String

    init() throws {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("volume-probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: (root as NSString).appendingPathComponent("DICOM"),
                                                withIntermediateDirectories: true)
        try Data("exam".utf8).write(to: URL(fileURLWithPath: (root as NSString).appendingPathComponent("DICOM/IM0001")))
        try Data("index".utf8).write(to: URL(fileURLWithPath: (root as NSString).appendingPathComponent("DICOMDIR")))
    }

    deinit {
        setFlags(0)
        setMode(0o755)
        try? FileManager.default.removeItem(atPath: root)
    }

    func setMode(_ mode: mode_t) {
        chmod(root, mode)
    }

    func setFlags(_ flags: UInt32) {
        chflags(root, flags)
    }

    var contents: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted()
    }
}

@Suite struct VolumeWriteProbeTests {
    @Test func errorNumbersNameTheRefusal() {
        #expect(VolumeWriteProbe.refusal(errorNumber: EPERM) == .notPermitted)
        #expect(VolumeWriteProbe.refusal(errorNumber: EACCES) == .accessDenied)
        #expect(VolumeWriteProbe.refusal(errorNumber: EROFS) == .readOnly)
        #expect(VolumeWriteProbe.refusal(errorNumber: ENOSPC) == .other(ENOSPC))
    }

    @Test func aVolumeThatTakesAFileIsLeftAsItWasByTheProbe() throws {
        let volume = try Volume()
        #expect(VolumeWriteProbe.refusal(writingTo: volume.root) == nil)
        #expect(volume.contents == ["DICOM", "DICOMDIR"])
    }

    @Test func aVolumeThatTakesAFileIsEmptied() throws {
        let volume = try Volume()
        #expect(VolumeWriteProbe.empty(volume.root) == nil)
        #expect(volume.contents.isEmpty)
    }

    /// The permissions of the folder refuse the write, as those of a volume owned
    /// by another account do.
    @Test func aVolumeWithoutWritePermissionKeepsWhatIsOnIt() throws {
        let volume = try Volume()
        volume.setMode(0o555)
        #expect(VolumeWriteProbe.empty(volume.root) == .accessDenied)
        volume.setMode(0o755)
        #expect(volume.contents == ["DICOM", "DICOMDIR"])
        #expect(FileManager.default.fileExists(atPath: (volume.root as NSString).appendingPathComponent("DICOM/IM0001")))
    }

    /// A folder that may not be changed answers the error number the system
    /// answers for a volume the privacy settings keep from the application.
    @Test func aVolumeTheSystemKeepsFromTheApplicationKeepsWhatIsOnIt() throws {
        let volume = try Volume()
        volume.setFlags(UInt32(UF_IMMUTABLE))
        #expect(VolumeWriteProbe.empty(volume.root) == .notPermitted)
        volume.setFlags(0)
        #expect(volume.contents == ["DICOM", "DICOMDIR"])
    }

    @Test func aPathThatNamesNoVolumeIsRefused() {
        #expect(VolumeWriteProbe.refusal(writingTo: "") == .other(ENOENT))
        #expect(VolumeWriteProbe.empty("") == .other(ENOENT))
        let missing = (NSTemporaryDirectory() as NSString).appendingPathComponent("volume-probe-missing-" + UUID().uuidString)
        #expect(VolumeWriteProbe.empty(missing) == .other(ENOENT))
    }
}
