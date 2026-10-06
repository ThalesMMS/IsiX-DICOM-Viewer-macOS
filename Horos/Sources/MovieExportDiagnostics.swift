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

/// Distinguishes the movie-export stages a failure report has to tell apart.
///
/// A completed writer followed by the viewer going away is `viewerClose`.
/// That is not an encoder, write or finalization failure.
@objc(HorosMovieExportPhase)
public enum MovieExportPhase: Int {
    case encoder = 1
    case write = 2
    case finalization = 3
    case openingResult = 4
    case viewerClose = 5
}

@objc(HorosMovieExportDiagnostics)
public final class MovieExportDiagnostics: NSObject {
    @objc(nameForPhase:)
    public static func name(for phase: MovieExportPhase) -> String {
        switch phase {
        case .encoder: return "encoder"
        case .write: return "write"
        case .finalization: return "finalization"
        case .openingResult: return "openingResult"
        case .viewerClose: return "viewerClose"
        }
    }

    @objc(classifyEncoderReady:writeFailed:finalizationCompleted:openSucceeded:viewerClosed:aborted:)
    public static func classify(
        encoderReady: Bool,
        writeFailed: Bool,
        finalizationCompleted: Bool,
        openSucceeded: Bool,
        viewerClosed: Bool,
        aborted: Bool
    ) -> MovieExportPhase {
        if viewerClosed && encoderReady && !writeFailed && finalizationCompleted {
            return .viewerClose
        }
        if encoderReady && !writeFailed && finalizationCompleted && !openSucceeded {
            return .openingResult
        }
        if !encoderReady {
            return .encoder
        }
        if writeFailed || aborted {
            return .write
        }
        return .finalization
    }

    @objc(logLineForPhase:errorDescription:stackSymbols:)
    public static func logLine(
        phase: MovieExportPhase,
        errorDescription: String?,
        stackSymbols: [String]?
    ) -> String {
        var line = "Movie export phase \(name(for: phase))"
        if let errorDescription, !errorDescription.isEmpty {
            line += ": \(errorDescription)"
        }
        if let stackSymbols, !stackSymbols.isEmpty {
            line += "\n" + stackSymbols.joined(separator: "\n")
        }
        return line
    }
}
