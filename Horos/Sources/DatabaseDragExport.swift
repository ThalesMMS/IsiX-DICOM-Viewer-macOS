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

import AppKit
import Synchronization

/// Dragging database rows and thumbnails out of Horos as file promises (#605).
///
/// A drag from the database used to advertise the legacy `NSFilesPromisePboardType`,
/// read the *current* selection at drop time, and spin the main thread for up to
/// four seconds waiting for the export thread. These types are the parts of the
/// replacement that hold no managed object and can be exercised without a
/// database: how the promised item is named, which files a JPEG export
/// produces and in what order, which series are reports and which are the
/// application's own state, how a multiframe record is expanded, and how a
/// staged export reaches its destination whole or not at all.
///
/// The #270 viewer drag (`DraggedImagePromise`) stays as it is; this is the
/// batch counterpart for studies, series and several thumbnails at once.

@objc(HorosBatchExportPlan)
public final class BatchExportPlan: NSObject {
    /// The SRs Horos writes for itself: ROIs, annotations, window state.
    @objc public static let internalStateSeriesNames: [String] = ["OsiriX ROI SR", "OsiriX Annotations SR", "OsiriX WindowsState SR"]
    static let structuredReportPrefix = "1.2.840.10008.5.1.4.1.1.88."
    static let encapsulatedPDF = "1.2.840.10008.5.1.4.1.1.104.1"

    /// A series that is a report a person would want as a PDF: a Structured
    /// Report or an encapsulated PDF, and not one of the application's own SRs.
    @objc(isReportSeriesWithName:sopClassUID:modality:)
    public static func isReportSeries(name: String?, sopClassUID: String?, modality: String?) -> Bool {
        if internalStateSeriesNames.contains(name ?? "") { return false }
        let uid = sopClassUID ?? ""
        return uid.hasPrefix(structuredReportPrefix) || uid == encapsulatedPDF
            || (modality ?? "").lowercased() == "pdf"
    }

    @objc(isEncapsulatedPDFSOPClassUID:)
    public static func isEncapsulatedPDF(sopClassUID: String?) -> Bool { sopClassUID == encapsulatedPDF }

    @objc(isStructuredReportSOPClassUID:)
    public static func isStructuredReport(sopClassUID: String?) -> Bool { (sopClassUID ?? "").hasPrefix(structuredReportPrefix) }

    /// Characters no destination file system or DICOMDIR wants in a name.
    static func sanitized(_ value: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:<>|?*\""))
        var result = ""
        for scalar in value.precomposedStringWithCanonicalMapping.unicodeScalars {
            result.unicodeScalars.append(forbidden.contains(scalar) ? " " : scalar)
        }
        let collapsed = result.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }

    static func capped(_ value: String, to limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }

    /// The name of the promised folder. One item keeps its own name; several
    /// items share a generic one. Hostile DICOM text is sanitized, a leading dot
    /// would hide the folder, and a JPEG export says so in its name.
    @objc(exportNameForItemNames:asJPEG:)
    public static func exportName(itemNames: [String], asJPEG jpeg: Bool) -> String {
        let generic = jpeg ? "Image and Report Export" : "DICOM Export"
        guard itemNames.count == 1 else { return generic }
        var name = capped(sanitized(itemNames[0]), to: 100)
        if name.isEmpty { return generic }
        if name.hasPrefix(".") { name = (jpeg ? "Export " : "DICOM ") + name }
        return jpeg ? name + " - Export" : name
    }

    /// The folder for one series inside a JPEG export, numbered in export order.
    @objc(seriesDirectoryNameForIndex:seriesName:)
    public static func seriesDirectoryName(index: Int, seriesName: String?) -> String {
        var name = capped(sanitized(seriesName ?? ""), to: 100)
        if name.isEmpty { name = "Series" }
        return String(format: "%04ld - %@", index, name)
    }

    @objc(imageFileNameForIndex:frame:)
    public static func imageFileName(index: Int, frame: Int) -> String {
        String(format: "IM-%06ld-%06ld.jpg", index, frame + 1)
    }

    @objc(reportFileNameForIndex:)
    public static func reportFileName(index: Int) -> String {
        String(format: "Report-%06ld.pdf", index)
    }

    /// How many frames to write for one database image. Old imports index a
    /// multiframe object as one record; those expand when the whole series was
    /// dragged. A series indexed frame by frame already has one record per
    /// frame and must not be written again per frame.
    @objc(frameCountForNumberOfFrames:seriesImageCount:wholeSeries:)
    public static func frameCount(numberOfFrames: Int, seriesImageCount: Int, wholeSeries: Bool) -> Int {
        guard wholeSeries, seriesImageCount == 1, numberOfFrames > 1 else { return 1 }
        return numberOfFrames
    }

    /// Whether a JPEG export must write this image at all.
    @objc(includesInJPEGExportImageStorage:reportSeries:)
    public static func includesInJPEGExport(imageStorage: Bool, reportSeries: Bool) -> Bool {
        imageStorage || reportSeries
    }
}

/// The pasteboard writer a database drag hands AppKit: a folder promise outside
/// Horos, the database object identifiers inside it (albums, Sources, viewers).
@objc(HorosDatabaseFilePromise)
public final class DatabaseFilePromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    @objc public var exportName: String = "Export"
    /// Property list of database object XIDs; nil for a JPEG export.
    @objc public var objectXIDs: Data?
    @objc public var extraTypes: [String] = []
    /// Called on the main queue (no operation queue of our own is given to
    /// AppKit); the completion it receives may be called from any thread.
    private var writer: ((URL, @escaping @Sendable (Error?) -> Void) -> Void)?
    @objc public private(set) var promiseWritten = false

    @objc public static func folderPromise() -> DatabaseFilePromise {
        let promise = DatabaseFilePromise()
        promise.fileType = "public.folder"
        promise.delegate = promise
        return promise
    }

    @objc public static func jpegPromise() -> DatabaseFilePromise {
        let promise = DatabaseFilePromise()
        promise.fileType = "public.jpeg"
        promise.delegate = promise
        return promise
    }

    @objc(setWriter:)
    public func setWriter(_ writer: @escaping (URL, @escaping @Sendable (Error?) -> Void) -> Void) {
        self.writer = writer
    }

    public override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = super.writableTypes(for: pasteboard)
        if objectXIDs != nil {
            types += extraTypes.map { NSPasteboard.PasteboardType(rawValue: $0) }
        }
        return types
    }

    public override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if extraTypes.contains(type.rawValue) { return objectXIDs }
        return super.pasteboardPropertyList(forType: type)
    }

    public func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        exportName
    }

    public func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                                    completionHandler: @escaping (Error?) -> Void) {
        promiseWritten = true
        guard let writer else {
            completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                      userInfo: [NSLocalizedDescriptionKey: "This export has no writer."]))
            return
        }
        // nonisolated(unsafe): AppKit's completion block is meant to be called
        // once, from whatever thread finishes the write, but the SDK does not
        // declare it @Sendable. It is only ever called, never stored beyond
        // that one call. Remove when the SDK declares the block Sendable.
        nonisolated(unsafe) let handler = completionHandler
        writer(url) { handler($0) }
    }
}

/// Staging: an export is written next to its destination and moved into place
/// only when complete; a failure or cancellation leaves the destination alone.
@objc(HorosExportStaging)
public final class ExportStaging: NSObject {
    /// A fresh directory on the destination's volume. Nothing of a previous
    /// export is touched: the name is unique to this call.
    @objc(stagingDirectoryForDestination:error:)
    public static func stagingDirectory(for destination: URL) throws -> URL {
        let parent = destination.deletingLastPathComponent()
        let base = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: parent, create: true)
        let staging = base.appendingPathComponent("export-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    /// Moves the staged export to its destination. An existing destination is
    /// never overwritten: the promise's name was accepted by the drop target
    /// and a file that appeared meanwhile is somebody else's.
    @objc(commitStaging:toDestination:error:)
    public static func commit(staging: URL, to destination: URL) throws {
        guard destination.isFileURL else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnsupportedSchemeError, userInfo: nil)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError, userInfo: [
                NSLocalizedDescriptionKey: "\(destination.lastPathComponent) already exists at the destination; nothing was replaced."])
        }
        try FileManager.default.moveItem(at: staging, to: destination)
    }

    /// Removes the staging directory and its parent replacement directory when
    /// that is empty. Only what this export created goes.
    @objc(discardStaging:)
    public static func discard(staging: URL) {
        try? FileManager.default.removeItem(at: staging)
        let parent = staging.deletingLastPathComponent()
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: parent.path), contents.isEmpty {
            try? FileManager.default.removeItem(at: parent)
        }
    }

    /// The staged export must contain something the destination can use.
    @objc(stagingHasContent:)
    public static func stagingHasContent(_ staging: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: staging, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
        for case let url as URL in enumerator {
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               values.isRegularFile == true, (values.fileSize ?? 0) > 0 {
                return true
            }
        }
        return false
    }
}

/// Every database object identifier on a pasteboard. A drag of several rows
/// carries one pasteboard item per row, so reading the pasteboard-level
/// property list saw the first row only.
@objc(HorosPasteboardObjectIdentifiers)
public final class PasteboardObjectIdentifiers: NSObject {
    @objc(identifiersOnPasteboard:types:)
    public static func identifiers(on pasteboard: NSPasteboard, types: [String]) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        func absorb(_ value: Any?) {
            var list: [Any] = []
            if let data = value as? Data,
               let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
                list = plist as? [Any] ?? []
            } else if let array = value as? [Any] {
                list = array
            }
            for case let identifier as String in list where !identifier.isEmpty && seen.insert(identifier).inserted {
                found.append(identifier)
            }
        }
        let wanted = types.map { NSPasteboard.PasteboardType(rawValue: $0) }
        for item in pasteboard.pasteboardItems ?? [] {
            if let type = item.availableType(from: wanted) { absorb(item.propertyList(forType: type)) }
        }
        if found.isEmpty, let type = pasteboard.availableType(from: wanted) {
            absorb(pasteboard.propertyList(forType: type))
        }
        return found
    }
}

/// The drop's completion handler must run exactly once, whatever happens to
/// the worker. An `NSThread` cancelled before it starts never runs its main;
/// AppKit would then wait for a promise that nobody fulfils. The worker keeps
/// this object in its parameters: it fires on request, and if it is released
/// without having fired, it reports cancellation.
@objc(HorosPromiseCompletionGuard)
public final class PromiseCompletionGuard: NSObject, Sendable {
    /// The worker fires it, the main thread's watch and the last release may.
    private let completion: Mutex<(@Sendable (Error?) -> Void)?>

    @objc(initWithCompletion:)
    public init(completion: @escaping @Sendable (Error?) -> Void) {
        self.completion = Mutex(completion)
        super.init()
    }

    @objc public var hasFired: Bool { completion.withLock { $0 == nil } }

    /// Delivers the outcome once; later calls are ignored.
    @objc(fireWithError:)
    public func fire(error: Error?) {
        let handler = completion.withLock { handler in
            defer { handler = nil }
            return handler
        }
        handler?(error)
    }

    /// A thread cancelled before it starts finishes without running its main and
    /// without posting `NSThreadWillExitNotification`, and whoever holds it keeps
    /// this guard alive. Watch the thread: finished and never fired means it
    /// never ran, and the drop is told so.
    @objc(watchThread:)
    public func watch(thread: Thread) {
        // nonisolated(unsafe): the timer only reads the thread's isFinished and
        // isExecuting, which NSThread answers from any thread.
        nonisolated(unsafe) let thread = thread
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.hasFired { timer.invalidate(); return }
            if thread.isFinished && !thread.isExecuting {
                timer.invalidate()
                self.fire(error: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: [
                    NSLocalizedDescriptionKey: "The export was cancelled before it started."]))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit {
        if let handler = completion.withLock({ $0 }) {
            handler(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: [
                NSLocalizedDescriptionKey: "The export was cancelled before it started."]))
        }
    }
}
