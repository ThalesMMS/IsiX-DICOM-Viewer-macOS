/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ¬†version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ¬†See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ¬†If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ¬† OsiriX
 ¬†Copyright (c) OsiriX Team
 ¬†All rights reserved.
 ¬†Distributed under GNU - LGPL
 ¬†
 ¬†See http://www.osirix-viewer.com/copyright.html for details.
 ¬† ¬† This software is distributed WITHOUT ANY WARRANTY; without even
 ¬† ¬† the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ¬† ¬† PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Cocoa
import UniformTypeIdentifiers
import CoreMedia
import AVFoundation

/// C's conversion of a CGFloat to an integer type, without Swift's trap: the
/// value is truncated toward zero, and out of range or NaN saturates as arm64
/// does.
private func quicktimeExportInteger<T: FixedWidthInteger>(_ value: CGFloat) -> T {
    let value = Double(value)
    if value.isNaN { return 0 }
    if value >= Double(T.max) { return T.max }
    if value <= Double(T.min) { return T.min }
    return T(value)
}

/// N2LogStackTrace(message): a C variadic function, which Swift cannot call.
/// It logs the message and the stack of an exception raised for the purpose,
/// as the former call did.
private func quicktimeExportLogStackTrace(_ message: String) {
    var caught: NSException?
    do {
        try HorosObjCException.perform {
            NSException(name: NSExceptionName(rawValue: message), reason: "", userInfo: nil).raise()
        }
    } catch {
        caught = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
    if let caught {
        _N2LogExceptionImpl(caught, true, "")
    }
}

/// QuickTime export.
///
/// Implemented in Swift: the Objective-C name, the selectors, the
/// outlets and action of QuicktimeExport.xib and <Horos/QuicktimeExport.h>
/// are those of the former class.
// Main actor: the movie export runs its save panel and progress window on the
// main thread. +CVPixelBufferFromNSImage:, which other threads call, is
// nonisolated.
@MainActor
@objc(QuicktimeExport)
public final class QuicktimeExport: NSObject {
    private var object: Any?
    private var selector: Selector?
    private var numberOfFrames: Int = 0

    private var panel: NSSavePanel?
    private var exportTypes: NSArray?

    @IBOutlet @objc var rateValue: NSTextField!

    @IBOutlet @objc var view: NSView!
    @IBOutlet @objc var type: NSPopUpButton!

    private var tlos: NSArray?

    /// The accessory's slider and label are bound to it.
    @objc dynamic var exportFrameRate: Int = 0

    /// -init as the former class inherited it: no nib.
    public override init() {
        super.init()
    }

    @objc(initWithSelector:::)
    public init!(selector o: Any!, _ s: Selector!, _ f: Int) {
        super.init()

        Bundle(for: QuicktimeExport.self).loadNibNamed("QuicktimeExport", owner: self, topLevelObjects: &tlos)

        object = o
        selector = s
        numberOfFrames = f
    }

    @objc(availableComponents)
    func availableComponents() -> NSArray {
        let compressors = NSMutableArray()

        compressors.add(NSDictionary(dictionary: ["videoCodec": AVVideoCodecType.jpeg.rawValue, "name": "JPEG Quicktime Movie", "extension": "mov"]))
        compressors.add(NSDictionary(dictionary: ["videoCodec": AVVideoCodecType.h264.rawValue, "name": "H264 Movie", "extension": "mp4"]))

        return compressors
    }

    @IBAction @objc(changeExportType:)
    func changeExportType(_ sender: Any?) {
        if let exportTypes, exportTypes.count > 0 {
            let indexOfSelectedItem = type?.indexOfSelectedItem ?? 0

            let selected = exportTypes.object(at: indexOfSelectedItem) as AnyObject

            panel?.allowedContentTypes = [UTType(filenameExtension: selected.value(forKey: "extension") as! String)!]

            UserDefaults.standard.set(selected.value(forKey: "videoCodec"), forKey: "selectedMenuAVFoundationExport")
        }
    }

    @objc(createMovieQTKit:::) @discardableResult
    public func createMovieQTKit(_ openIt: Bool, _ produceFiles: Bool, _ name: String!) -> String! {
        return createMovieQTKit(openIt, produceFiles, name, 0)
    }

    /// A +1 pixel buffer, which the caller releases, as the former method returned it.
    /// Also called off the main thread (the web portal's movie, the database's export).
    @nonobjc
    nonisolated public class func CVPixelBufferFromNSImage(_ image: NSImage!) -> Unmanaged<CVPixelBuffer>? {
        var buffer: CVPixelBuffer? = nil

        // config
        let width: Int = quicktimeExportInteger(image?.size.width ?? 0)
        let height: Int = quicktimeExportInteger(image?.size.height ?? 0)
        let bitsPerComponent = 8
        // kCGColorSpaceGenericRGB, which Swift marks unavailable.
        let cs = CGColorSpace(name: "kCGColorSpaceGenericRGB" as CFString)
        let d: NSDictionary = [kCVPixelBufferCGImageCompatibilityKey as String: NSNumber(value: true), kCVPixelBufferCGBitmapContextCompatibilityKey as String: NSNumber(value: true)]

        // create pixel buffer
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, d as CFDictionary, &buffer)
        var rasterData: UnsafeMutableRawPointer? = nil
        var bytesPerRow = 0
        if let buffer {
            CVPixelBufferLockBaseAddress(buffer, [])
            rasterData = CVPixelBufferGetBaseAddress(buffer)
            bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        }

        // context to draw in, set to pixel buffer's address
        guard let cs, let ctxt = CGContext(data: rasterData, width: width, height: height, bitsPerComponent: bitsPerComponent, bytesPerRow: bytesPerRow, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
            NSLog("******** CVPixelBufferFromNSImage : could not create context")
            return nil
        }

        // draw
        let nsctxt = NSGraphicsContext(cgContext: ctxt, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsctxt
        image?.draw(at: NSMakePoint(0.0, 0.0), from: NSZeroRect, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        guard let buffer else { return nil }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return Unmanaged.passRetained(buffer)
    }

    // Objective-C's CF-returning selector is declared by QuicktimeExport.h and
    // bridged in QuicktimeExport+CAPI.m. A raw pointer avoids emitting Objective-C
    // ownership attributes on a Core Foundation pointer in the generated header.
    @objc(horos_retainedPixelBufferFromNSImage:)
    nonisolated public class func retainedPixelBufferPointer(from image: NSImage!) -> UnsafeMutableRawPointer? {
        return CVPixelBufferFromNSImage(image)?.toOpaque()
    }

    @objc(createMovieQTKit::::) @discardableResult
    public func createMovieQTKit(_ openIt: Bool, _ produceFiles: Bool, _ name: String!, _ framesPerSecond: Int) -> String! {
        var fps = framesPerSecond
        let savedFPS = UserDefaults.standard.integer(forKey: "quicktimeExportRateValue")
        // Interactive exports reuse the last confirmed rate instead of the viewer's cine rate.
        if (!produceFiles || fps <= 0) && savedFPS > 0 {
            fps = savedFPS
        }
        if fps <= 0 {
            fps = 10
        }

        self.exportFrameRate = fps

        var fileName: String?
        let result: Int

        exportTypes = availableComponents()

        let panel = NSSavePanel()
        self.panel = panel

        if let tempDirPath = BrowserController.currentBrowser()?.database?.tempDirPath() {
            try? FileManager.default.createDirectory(atPath: tempDirPath, withIntermediateDirectories: true, attributes: nil)
        }

        if produceFiles {
            result = NSApplication.ModalResponse.OK.rawValue

            if let path = (BrowserController.currentBrowser()?.database?.tempDirPath() as NSString?)?.appendingPathComponent("Photos") {
                try? FileManager.default.removeItem(atPath: path)
                try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
            }

            fileName = (BrowserController.currentBrowser()?.database?.tempDirPath() as NSString?)?.appendingPathComponent("OsiriXMovie.mov")
        } else {
            panel.canSelectHiddenExtension = true
            panel.accessoryView = view
            type?.removeAllItems()

            if let exportTypes, exportTypes.count > 0 {
                type?.addItems(withTitles: exportTypes.value(forKey: "name") as! [String])
            }

            var index = 0

            for d in exportTypes ?? NSArray() {
                let codec = (d as? NSDictionary)?.object(forKey: "videoCodec") as? NSString
                if let codec, let selected = UserDefaults.standard.object(forKey: "selectedMenuAVFoundationExport") as? String, codec.isEqual(to: selected) {
                    index = exportTypes!.index(of: d)
                }
            }

            type?.selectItem(at: index)
            changeExportType(self)

            if let name {
                panel.nameFieldStringValue = name
            } else {
                // -setNameFieldStringValue: as the former code sent it.
                _ = panel.perform(#selector(setter: NSSavePanel.nameFieldStringValue), with: nil)
            }

            result = panel.runModal().rawValue

            fileName = panel.url?.path
        }

        // A cancelled save panel must never modify its last selected destination.
        if result != NSApplication.ModalResponse.OK.rawValue {
            return nil
        }

        if let fileName {
            try? FileManager.default.removeItem(atPath: fileName)

            if FileManager.default.fileExists(atPath: fileName) {
                FileManager.default.moveItemAtPath(toTrash: fileName)
            }
        }

        var returned: String? = nil
        do {
            try HorosObjCException.perform {
                returned = self.writeMovie(result: result, openIt: openIt, produceFiles: produceFiles, fileName: fileName)
            }
        } catch {
            if let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                _N2LogExceptionImpl(e, true, "-[QuicktimeExport createMovieQTKit::::]")
            }
        }

        return returned
    }

    /// The body of the former @try: writes the frames and finalizes the movie.
    /// An NSException it raises is caught by the caller, as the @catch did.
    private func writeMovie(result: Int, openIt: Bool, produceFiles: Bool, fileName: String?) -> String? {
        if result == NSApplication.ModalResponse.OK.rawValue {
            let fps = self.exportFrameRate
            if !produceFiles {
                UserDefaults.standard.set(fps, forKey: "quicktimeExportRateValue")
            }

            // C's integer division on arm64: x / 0 is 0.
            let timeValue: CMTimeValue = fps != 0 ? CMTimeValue(600 / fps) : 0
            let frameDuration = CMTimeMake(value: timeValue, timescale: 600)

            var error: NSError? = nil
            var aborted = false
            var completed = false
            var failed = false

            // +[NSURL fileURLWithPath:] raised for a nil path.
            guard let fileName else {
                NSException(name: .invalidArgumentException, reason: "*** -[NSURL initFileURLWithPath:]: nil string parameter", userInfo: nil).raise()
                return nil
            }

            var writer: AVAssetWriter? = nil
            do {
                writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: fileName), fileType: .mov)
            } catch let writerError as NSError {
                error = writerError
            }
            var encoderReady = false
            if error == nil, let writer {
                let wait: Wait = Wait(string: NSLocalizedString("Movie Export", comment: ""))
                wait.showWindow(self)
                wait.setCancel(true)
                wait.progress().maxValue = Double(numberOfFrames)

                var writerInput: AVAssetWriterInput? = nil
                var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor? = nil
                var nextPresentationTimeStamp = CMTime.zero

                var curSample: Int32 = 0
                while Int(curSample) < numberOfFrames {
                    autoreleasepool {
                        do {
                            try HorosObjCException.perform {
                                var buffer: CVPixelBuffer? = nil

                                let im = (self.object as AnyObject?)?.perform(self.selector, with: NSNumber(value: Int(curSample)), with: NSNumber(value: self.numberOfFrames))?.takeUnretainedValue() as? NSImage

                                if let im {
                                    if writerInput == nil {
                                        // Define video settings to be passed to the AVAssetWriterInput instance

                                        let c = UserDefaults.standard.object(forKey: "selectedMenuAVFoundationExport") as? NSString

                                        var videoSettings: NSDictionary? = nil

                                        if let c, c.isEqual(to: AVVideoCodecType.h264.rawValue) {
                                            let bitsPerSecond = Double(im.size.width) * Double(im.size.height) * Double(fps) * 4 // Maximum bit rate for best quality

                                            if bitsPerSecond > 0 {
                                                videoSettings = NSDictionary(dictionary: [
                                                    AVVideoCodecKey: c,
                                                    AVVideoCompressionPropertiesKey: NSDictionary(dictionary: [
                                                        AVVideoAverageBitRateKey: NSNumber(value: bitsPerSecond),
                                                        AVVideoMaxKeyFrameIntervalKey: NSNumber(value: 1)]),
                                                    AVVideoWidthKey: NSNumber(value: quicktimeExportInteger(im.size.width) as Int32),
                                                    AVVideoHeightKey: NSNumber(value: quicktimeExportInteger(im.size.height) as Int32)])
                                            } else {
                                                quicktimeExportLogStackTrace("********** bitsPerSecond == 0")
                                                NSLog("%@", MovieExportDiagnostics.logLine(phase: .encoder,
                                                                                            errorDescription: "bitsPerSecond == 0",
                                                                                            stackSymbols: Thread.callStackSymbols))
                                            }
                                        } else if let c, c.isEqual(to: AVVideoCodecType.jpeg.rawValue) {
                                            videoSettings = NSDictionary(dictionary: [
                                                AVVideoCodecKey: c,
                                                AVVideoCompressionPropertiesKey: NSDictionary(dictionary: [AVVideoQualityKey: NSNumber(value: Float(0.9))]),
                                                AVVideoWidthKey: NSNumber(value: quicktimeExportInteger(im.size.width) as Int32),
                                                AVVideoHeightKey: NSNumber(value: quicktimeExportInteger(im.size.height) as Int32)])
                                        }

                                        if let videoSettings {
                                            writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings as? [String: Any])

                                            if writerInput == nil {
                                                quicktimeExportLogStackTrace(NSString(format: "**** writerInput == nil : %@", videoSettings) as String)
                                                NSLog("%@", MovieExportDiagnostics.logLine(phase: .encoder,
                                                                                            errorDescription: videoSettings.description,
                                                                                            stackSymbols: Thread.callStackSymbols))
                                            } else {
                                                encoderReady = true
                                            }

                                            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput!, sourcePixelBufferAttributes: nil)

                                            writer.add(writerInput!)
                                            writer.startWriting()
                                            writer.startSession(atSourceTime: nextPresentationTimeStamp)
                                        }
                                    }

                                    buffer = QuicktimeExport.CVPixelBufferFromNSImage(im)?.takeRetainedValue()
                                }

                                if let pixelBuffer = buffer {
                                    CVPixelBufferLockBaseAddress(pixelBuffer, [])
                                    while let writerInput, writer.status == .writing, !writerInput.isReadyForMoreMediaData {
                                        Thread.sleep(forTimeInterval: 0.1)
                                    }
                                    if writer.status != .writing ||
                                        !(pixelBufferAdaptor?.append(pixelBuffer, withPresentationTime: nextPresentationTimeStamp) ?? false) {
                                        failed = true
                                        NSLog("%@", MovieExportDiagnostics.logLine(phase: .write,
                                                                                    errorDescription: writer.error?.localizedDescription ?? "rejected pixel buffer",
                                                                                    stackSymbols: Thread.callStackSymbols))
                                    }
                                    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                                    buffer = nil

                                    nextPresentationTimeStamp = CMTimeAdd(nextPresentationTimeStamp, frameDuration)
                                }

                                wait.increment(by: 1)
                                if wait.aborted() {
                                    curSample = Int32(truncatingIfNeeded: self.numberOfFrames)
                                    aborted = true
                                }
                            }
                        } catch {
                            let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
                            if let e {
                                _N2LogExceptionImpl(e, true, "-[QuicktimeExport createMovieQTKit::::]")
                            }
                            failed = true
                            NSLog("%@", MovieExportDiagnostics.logLine(phase: .write,
                                                                        errorDescription: e?.reason,
                                                                        stackSymbols: Thread.callStackSymbols))
                        }
                    }
                    if failed { break }
                    curSample &+= 1
                }
                if writer.status == .writing {
                    writerInput?.markAsFinished()
                }
                // Do not expose the movie before AVFoundation has finalized its container.
                if aborted || failed {
                    writer.cancelWriting()
                } else if writer.status == .writing {
                    let finished = DispatchSemaphore(value: 0)
                    writer.finishWriting { finished.signal() }
                    finished.wait()
                    completed = writer.status == .completed
                }
                if !completed && !aborted {
                    error = writer.error as NSError?
                }

                _ = (object as AnyObject?)?.perform(selector, with: NSNumber(value: 0), with: NSNumber(value: numberOfFrames))

                if completed {
                    NSLog("%@", MovieExportDiagnostics.logLine(phase: .finalization,
                                                                errorDescription: "completed",
                                                                stackSymbols: nil))
                } else if !aborted && !failed && encoderReady {
                    NSLog("%@", MovieExportDiagnostics.logLine(phase: .finalization,
                                                                errorDescription: error?.localizedDescription ?? "writer did not reach Completed",
                                                                stackSymbols: Thread.callStackSymbols))
                } else if !aborted && !failed && !encoderReady {
                    NSLog("%@", MovieExportDiagnostics.logLine(phase: .encoder,
                                                                errorDescription: error?.localizedDescription ?? "encoder was not ready",
                                                                stackSymbols: Thread.callStackSymbols))
                }

                wait.close()

                if openIt && completed &&
                    !NSWorkspace.shared.open(URL(fileURLWithPath: fileName)) {
                    NSLog("%@", MovieExportDiagnostics.logLine(phase: .openingResult,
                                                                errorDescription: fileName,
                                                                stackSymbols: Thread.callStackSymbols))
                }
            } else if let error {
                NSLog("%@", MovieExportDiagnostics.logLine(phase: .encoder,
                                                            errorDescription: error.localizedDescription,
                                                            stackSymbols: Thread.callStackSymbols))
            }

            if completed {
                return fileName
            }
            if !aborted {
                HorosAlertPanel.run(title: NSLocalizedString("Movie Export", comment: ""),
                                    message: error?.localizedDescription ?? NSLocalizedString("The movie could not be saved. Check the destination and try again.", comment: ""),
                                    defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }
        }

        return nil
    }
}
