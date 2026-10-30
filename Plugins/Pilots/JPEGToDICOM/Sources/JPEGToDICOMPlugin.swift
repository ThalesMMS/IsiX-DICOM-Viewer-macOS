//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import IsiXPluginKit
import os
import Synchronization

/// JPEG to DICOM on the plugin API version 1: converts images, or folders of
/// images, into DICOM series of the study selected in the database window,
/// and imports them.
///
/// The study comes from the database selection; the application writes the
/// DICOM files, copying the patient and study from that study; the plugin
/// imports them and removes its temporary copies. Each folder becomes a
/// series named after it; files chosen directly become one series.
public final class JPEGToDICOMPlugin: NSObject, IsiXPlugin {
    private let log = Logger(subsystem: "org.isix.pilot.jpeg-to-dicom", category: "pilot")
    private let journal = Mutex<[String]>([])
    private var context: IsiXPluginContext?
    private var conversion: IsiXTask?

    public override nonisolated var description: String { journal.withLock { $0.joined(separator: "\n") } }

    public override init() {
        super.init()
    }

    struct Failure: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    public func activate(with context: IsiXPluginContext) throws {
        self.context = context
        try context.register(IsiXCommand(id: "jpeg-to-dicom", title: "JPEG to DICOM", placement: .database)) { [weak self] invocation in
            try self?.chooseFiles(parent: invocation.parentWindow)
        }
        note("activated \(context.info.identifier) \(context.info.version)")
    }

    public func deactivate() {
        conversion = nil
        context = nil
    }

    private func note(_ line: String) {
        journal.withLock { $0.append(line) }
        log.notice("JPEGToDICOM: \(line, privacy: .public)")
    }

    private func chooseFiles(parent: NSWindow?) throws {
        guard conversion == nil else { throw Failure(reason: "JPEG to DICOM is already converting.") }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.title = "JPEG to DICOM"
        panel.message = "Select images or folders of images to convert to DICOM in the selected study."
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard response == .OK, let urls = panel?.urls else { return }
            self?.convert(urls)
        }
        if let parent {
            panel.beginSheetModal(for: parent, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// Converts the images at these paths, as if they had been chosen in the
    /// open panel: for scripts and checks that cannot use the panel.
    @objc(convertFilesAtPaths:)
    public func convertFiles(atPaths paths: [String]) -> Bool {
        convert(paths.map { URL(fileURLWithPath: $0) })
    }

    @discardableResult
    private func convert(_ urls: [URL]) -> Bool {
        guard let context, conversion == nil else { return false }
        let groups = RasterImage.series(for: urls)
        guard !groups.isEmpty else {
            note("no image among the chosen files")
            return false
        }
        do {
            let database = try context.database()
            conversion = try context.startTask(named: "JPEG to DICOM") { [weak self] progress in
                var lines: [String] = []
                var failure: (any Error)?
                do {
                    guard let study = try await database.selectedStudies().first else {
                        throw Failure(reason: "First select, in the database window, the study the images go to.")
                    }
                    let total = groups.reduce(0) { $0 + $1.files.count }
                    var done = 0
                    for group in groups {
                        var images: [IsiXPixelData] = []
                        for file in group.files {
                            if progress.isCancelled { throw CancellationError() }
                            images.append(.rgba8(try RasterImage.pixels(of: file)))
                            done += 1
                            progress.report(Double(done) / Double(total))
                        }
                        let request = IsiXDerivedSeriesRequest(studyInstanceUID: study.studyInstanceUID,
                                                               seriesDescription: group.name, images: images)
                        let files = try await database.writeDerivedSeries(request)
                        let result = try await database.importFiles(at: files)
                        // The written files are the plugin's; the database keeps its own copies.
                        if let folder = files.first?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: folder) }
                        lines.append("series \"\(group.name)\": \(group.files.count) images written, \(result.importedFiles.count) imported "
                                     + "into study \(study.studyInstanceUID) series \(result.seriesInstanceUIDs.joined(separator: ",")) "
                                     + "failures \(result.failures.count)")
                    }
                } catch {
                    failure = error
                }
                let report = lines
                let error = failure
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.conversion = nil
                    for line in report { self.note(line) }
                    if let error { self.report(error) }
                }
            }
            return true
        } catch {
            report(error)
            return false
        }
    }

    private func report(_ error: any Error) {
        note("failed: \(error.localizedDescription)")
        guard !(error is CancellationError) else { return }
        // Without a running application (a test host) there is no one to tell.
        guard let application = NSApp, application.isRunning else { return }
        let alert = NSAlert()
        alert.messageText = "JPEG to DICOM"
        alert.informativeText = error.localizedDescription
        if let window = application.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
