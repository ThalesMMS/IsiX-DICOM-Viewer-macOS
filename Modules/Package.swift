// swift-tools-version: 6.0
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The app's internal modules. Each one lives in its own folder, Modules/<Name>,
// with Sources/ and Tests/, is named IsiX<Area>, and depends only on modules
// listed before it here, never on the app target. The app links every product
// statically through the Xcode project; `swift test --package-path Modules`
// runs the modules' tests without building or opening the app.

import PackageDescription

let package = Package(
    name: "IsiXModules",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "IsiXLogging", targets: ["IsiXLogging"]),
        .library(name: "IsiXPreferences", targets: ["IsiXPreferences"]),
        .library(name: "IsiXStorage", targets: ["IsiXStorage"]),
        .library(name: "IsiXROI", targets: ["IsiXROI"]),
        .library(name: "IsiXPluginLoading", targets: ["IsiXPluginLoading"]),
        .library(name: "IsiXImaging", targets: ["IsiXImaging"]),
        .library(name: "IsiXGeometry", targets: ["IsiXGeometry"]),
        .library(name: "IsiXDICOMFile", targets: ["IsiXDICOMFile"]),
        .library(name: "IsiXDICOMDataset", targets: ["IsiXDICOMDataset"]),
        .library(name: "IsiXDatabase", targets: ["IsiXDatabase"]),
        .library(name: "IsiXDICOMNetwork", targets: ["IsiXDICOMNetwork"]),
        .library(name: "IsiXSegmentation", targets: ["IsiXSegmentation"]),
        .library(name: "IsiXVolumeRendering", targets: ["IsiXVolumeRendering"]),
        .library(name: "IsiXHTTPServer", targets: ["IsiXHTTPServer"]),
        .library(name: "IsiXKeychain", targets: ["IsiXKeychain"]),
        .library(name: "IsiXMail", targets: ["IsiXMail"]),
        .library(name: "IsiXInstallation", targets: ["IsiXInstallation"]),
        .library(name: "IsiXCrashReporting", targets: ["IsiXCrashReporting"]),
    ],
    targets: [
        .target(name: "IsiXLogging", path: "IsiXLogging/Sources"),
        .testTarget(name: "IsiXLoggingTests", dependencies: ["IsiXLogging"], path: "IsiXLogging/Tests"),
        .target(name: "IsiXPreferences", dependencies: ["IsiXLogging"], path: "IsiXPreferences/Sources"),
        .testTarget(name: "IsiXPreferencesTests", dependencies: ["IsiXPreferences"], path: "IsiXPreferences/Tests"),
        .target(name: "IsiXStorage", path: "IsiXStorage/Sources"),
        .testTarget(name: "IsiXStorageTests", dependencies: ["IsiXStorage"], path: "IsiXStorage/Tests"),
        .target(name: "IsiXROI", path: "IsiXROI/Sources"),
        .testTarget(name: "IsiXROITests", dependencies: ["IsiXROI"], path: "IsiXROI/Tests"),
        .target(name: "IsiXPluginLoading", path: "IsiXPluginLoading/Sources"),
        .testTarget(name: "IsiXPluginLoadingTests", dependencies: ["IsiXPluginLoading"], path: "IsiXPluginLoading/Tests"),
        .target(name: "IsiXImaging", dependencies: ["IsiXLogging"], path: "IsiXImaging/Sources"),
        .testTarget(name: "IsiXImagingTests", dependencies: ["IsiXImaging"], path: "IsiXImaging/Tests"),
        // Optimized in every configuration: unoptimized, its simd code runs
        // several times slower than the C it replaced, and the CPR and the
        // ROIs call it on every update.
        .target(name: "IsiXGeometry", path: "IsiXGeometry/Sources", swiftSettings: [.unsafeFlags(["-O"])]),
        .testTarget(name: "IsiXGeometryTests", dependencies: ["IsiXGeometry"], path: "IsiXGeometry/Tests"),
        .target(name: "IsiXDICOMFile", dependencies: ["IsiXLogging", "IsiXImaging"], path: "IsiXDICOMFile/Sources"),
        .testTarget(name: "IsiXDICOMFileTests", dependencies: ["IsiXDICOMFile"], path: "IsiXDICOMFile/Tests"),
        .target(name: "IsiXDICOMDataset", dependencies: ["IsiXLogging", "IsiXImaging", "IsiXDICOMFile"], path: "IsiXDICOMDataset/Sources"),
        .testTarget(name: "IsiXDICOMDatasetTests", dependencies: ["IsiXDICOMDataset", "IsiXDICOMFile"], path: "IsiXDICOMDataset/Tests"),
        .target(name: "IsiXDatabase", dependencies: ["IsiXLogging"], path: "IsiXDatabase/Sources"),
        .testTarget(name: "IsiXDatabaseTests", dependencies: ["IsiXDatabase"], path: "IsiXDatabase/Tests"),
        .target(name: "IsiXDICOMNetwork", path: "IsiXDICOMNetwork/Sources"),
        .testTarget(name: "IsiXDICOMNetworkTests", dependencies: ["IsiXDICOMNetwork"], path: "IsiXDICOMNetwork/Tests"),
        .target(name: "IsiXSegmentation", path: "IsiXSegmentation/Sources"),
        .testTarget(name: "IsiXSegmentationTests", dependencies: ["IsiXSegmentation"], path: "IsiXSegmentation/Tests"),
        .target(name: "IsiXVolumeRendering", dependencies: ["IsiXLogging"], path: "IsiXVolumeRendering/Sources"),
        .testTarget(name: "IsiXVolumeRenderingTests", dependencies: ["IsiXVolumeRendering"], path: "IsiXVolumeRendering/Tests"),
        .target(name: "IsiXHTTPServer", path: "IsiXHTTPServer/Sources"),
        .testTarget(name: "IsiXHTTPServerTests", dependencies: ["IsiXHTTPServer"], path: "IsiXHTTPServer/Tests"),
        .target(name: "IsiXKeychain", dependencies: ["IsiXLogging"], path: "IsiXKeychain/Sources"),
        .testTarget(name: "IsiXKeychainTests", dependencies: ["IsiXKeychain"], path: "IsiXKeychain/Tests"),
        .target(name: "IsiXMail", path: "IsiXMail/Sources"),
        .testTarget(name: "IsiXMailTests", dependencies: ["IsiXMail"], path: "IsiXMail/Tests"),
        .target(name: "IsiXInstallation", path: "IsiXInstallation/Sources"),
        .testTarget(name: "IsiXInstallationTests", dependencies: ["IsiXInstallation"], path: "IsiXInstallation/Tests"),
        .target(name: "IsiXCrashReporting", path: "IsiXCrashReporting/Sources"),
        .testTarget(name: "IsiXCrashReportingTests", dependencies: ["IsiXCrashReporting"], path: "IsiXCrashReporting/Tests"),
    ],
    swiftLanguageModes: [.v6]
)
