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

/// One third-party or host notice that the distributed app must keep.
@objc(HorosLicensedComponent)
public final class LicensedComponent: NSObject {
    @objc public let identifier: String
    @objc public let name: String
    @objc public let license: String
    @objc public let sourcePath: String
    @objc public let incorporated: Bool
    @objc public let origin: String
    @objc public let distributionNote: String

    @objc public init(identifier: String,
                      name: String,
                      license: String,
                      sourcePath: String,
                      incorporated: Bool,
                      origin: String,
                      distributionNote: String) {
        self.identifier = identifier
        self.name = name
        self.license = license
        self.sourcePath = sourcePath
        self.incorporated = incorporated
        self.origin = origin
        self.distributionNote = distributionNote
    }
}

/// Provenance, credits and the notices that belong in the checkout and app bundle.
///
/// This is not legal advice. It records what is actually in this fork and
/// their recorded origins. It does not copy donor-fork source.
@objc(HorosLicenseAttribution)
public final class LicenseAttribution: NSObject {
    /// The maintainer of this fork. Its changes were not made or endorsed by
    /// the Horos Project.
    @objc public static let forkAuthor = "Thales Matheus M Santos (ThalesMMS)"
    @objc public static let forkCopyright =
        "Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork"

    /// The donor fork this fork adapted excerpts from. Credited by author,
    /// not by repository handle; NOTICE records which components were adapted.
    @objc public static let donorRevision = "23722fb552d96fa2d60c7f58a6d4ac2c27950f86"
    @objc public static let donorAuthor = "Yves Starreveld"
    /// Historical SDK metadata, paired with the origin hashes below.
    /// This path is not a distributed resource or a catalog/UI link.
    @objc public static let snapshotDirectory =
        "docs/third-party/donor-horos-23722fb552d96fa2d60c7f58a6d4ac2c27950f86"
    @objc public static let originLicenseSHA256 =
        "d885acd3300b5464fe5e6774610b35fb2d83192f272be3325d69b89d2d666f38"
    @objc public static let originCopyingLesserSHA256 =
        "c9f740e3eddbb3a01de0d3924a9afd17782567e20c28e55d0e2436376b5c9000"
    @objc public static let catalogID = "L368"

    @objc public static let requiredRootResourceNames = ["LICENSE", "COPYING.LESSER", "NOTICE"]
    @objc public static let requiredSplashResourceNames = ["about.html", "licenses.html", "OpenSSL-LICENSE.txt",
                                                           "DICOM-Swift-LICENSE.txt", "ThirdParty/licenses.html"]

    /// Full texts that the third-party index must always accompany.
    @objc public static let requiredThirdPartyResourceNames = [
        "DICOMSwift/ThirdPartyNotices.txt",
        "Rendered/DICOMSwift/ThirdPartyNotices.txt.html",
        "DICOMSwift/DistributionProvenance.json",
        "Rendered/DICOMSwift/DistributionProvenance.json.html",
        "DICOMSwift/pydicom/LICENSE",
        "Rendered/DICOMSwift/pydicom/LICENSE.html",
        "DICOMSwift/DCMTK/COPYRIGHT",
        "Rendered/DICOMSwift/DCMTK/COPYRIGHT.html",
        "DICOMSwift/GDCM/Copyright.txt",
        "Rendered/DICOMSwift/GDCM/Copyright.txt.html",
        "DICOMSwift/GDCM/COPYRIGHT.dicom3tools",
        "Rendered/DICOMSwift/GDCM/COPYRIGHT.dicom3tools.html",

        "Native/DCMTK/COPYRIGHT", "Native/ITK/LICENSE", "Native/ITK/NOTICE",
        "Native/VTK/Copyright.txt", "Native/OpenJPEG/LICENSE",
        "Compatibility/SelectedAnonymizationCatalog-Copyright.txt",
        "Native/DCMTK/dcmjpls/docs/License.txt",
        "Native/ITK/Modules/ThirdParty/GDCM/src/gdcm/Utilities/gdcmcharls/License.txt",
        "Native/FeedbackReporter/LICENSE.txt", "Native/cocoahttpserver/LICENSE.txt",
        "Native/Legacy/NOTICES.txt", "Native/Legacy/jquery-MIT-LICENSE.txt",
        "Native/Legacy/mousewheel-MIT-LICENSE.txt", "Native/Legacy/sha1-BSD-LICENSE.txt", "Provenance.json",
        "dicom3tools/COPYRIGHT", "dicom3tools/Python-packaging-LICENSE",
        "Weasis/EPL-2.0.txt", "Weasis/dcm4che-5.20.0-MPL-1.1.txt",
        "Weasis/DockingFrames-LGPL-2.1.txt",
    ]

    @objc public static func components() -> [LicensedComponent] {
        [
            LicensedComponent(
                identifier: "fork",
                name: forkAuthor,
                license: "LGPLv3",
                sourcePath: "LICENSE",
                incorporated: true,
                origin: "fork",
                distributionNote: "Modifications in this fork, ThalesMMS/horos. Not made or endorsed by the Horos Project. Keep this notice with the others."),
            LicensedComponent(
                identifier: "horos",
                name: "Horos Project",
                license: "LGPLv3",
                sourcePath: "LICENSE",
                incorporated: true,
                origin: "host",
                distributionNote: "Offer Corresponding Source with the app. COPYING.LESSER ships in the bundle."),
            LicensedComponent(
                identifier: "osirix",
                name: "OsiriX",
                license: "LGPLv3",
                sourcePath: "LICENSE",
                incorporated: true,
                origin: "host",
                distributionNote: "Historical fork. Keep OsiriX Team credit and file headers."),
            LicensedComponent(
                identifier: "donor",
                name: "Yves Starreveld (donor fork)",
                license: "LGPLv3",
                sourcePath: "LICENSE",
                incorporated: true,
                origin: "adapted-source",
                distributionNote: "The query/retrieve server uses adapted excerpts from the recorded revision. Preserve their headers and distinguish local changes."),
            LicensedComponent(
                identifier: "kfsplitview",
                name: "KFSplitView compatibility",
                license: "LGPLv3 (replacement); historical CC BY-NC 1.0 notice retained",
                sourcePath: "Horos/Sources/KFSplitView.swift",
                incorporated: true,
                origin: "independent-implementation",
                distributionNote: "New Swift/AppKit implementation by Thales Matheus M Santos (ThalesMMS), 2026. Former v1.3 credits: Ken Ferry, Kirk Baker and John Pannell. No alternative permission established for the removed implementation; historical notices remain in compatibility files."),
            LicensedComponent(
                identifier: "dcmtk",
                name: "DCMTK",
                license: "BSD-style (OFFIS)",
                sourcePath: "DCMTK/COPYRIGHT",
                incorporated: true,
                origin: "host",
                distributionNote: "Keep copyright, conditions and disclaimer in documentation."),
            LicensedComponent(
                identifier: "itk",
                name: "ITK",
                license: "Apache-2.0",
                sourcePath: "Horos/Scripts/external-sources.json",
                incorporated: true,
                origin: "upstream release archive",
                distributionNote: "ITK 5.4.7 original source record, license and NOTICE ship in Resources/CompiledSources/ITK. Keep NOTICE and Apache terms with binaries."),
            LicensedComponent(
                identifier: "vtk",
                name: "VTK",
                license: "BSD-3-Clause",
                sourcePath: "Horos/Scripts/external-sources.json",
                incorporated: true,
                origin: "upstream release archive",
                distributionNote: "VTK 9.7.1 original source record and copyright ship in Resources/CompiledSources/VTK. Preserve VTK, FreeType and MetaIO notices. The installed FreeType module and aggregate have a separate host binary adaptation record; the original source has no patches."),
            LicensedComponent(
                identifier: "selected-anonymization-data",
                name: "Selected anonymization compatibility data (GDCM 3.2.11)",
                license: "BSD-3-Clause",
                sourcePath: "Binaries/Splash/ThirdParty/Compatibility/SelectedAnonymizationCatalog-Copyright.txt",
                incorporated: true,
                origin: "derived-dictionary-data",
                distributionNote: "Selected fields derived from the GDCM 3.2.11 public dictionary; the GDCM runtime library is removed. Preserve Mathieu Malaterre and CREATIS copyright, BSD conditions and disclaimer with the compatibility data."),
            LicensedComponent(
                identifier: "openjpeg",
                name: "OpenJPEG",
                license: "BSD-2-Clause",
                sourcePath: "Horos/Scripts/external-sources.json",
                incorporated: true,
                origin: "upstream archive",
                distributionNote: "OpenJPEG's original copyright and disclaimer ship in Splash/ThirdParty/Native/OpenJPEG/LICENSE. The compiled source pin and license ship in Resources/CompiledSources/OpenJPEG."),
            LicensedComponent(
                identifier: "openssl",
                name: "OpenSSL 3.5.9",
                license: "Apache-2.0",
                sourcePath: "OpenSSL/upstream/LICENSE.txt",
                incorporated: true,
                origin: "host",
                distributionNote: "The unmodified upstream Apache license ships in Splash/OpenSSL-LICENSE.txt."),
            LicensedComponent(
                identifier: "charls",
                name: "CharLS",
                license: "BSD-3-Clause",
                sourcePath: "DCMTK/dcmjpls/docs/License.txt",
                incorporated: true,
                origin: "host",
                distributionNote: "Keep copyright and disclaimer. The runtime copy is private to the DCMTK JPEG-LS adapter. Optional copies in the ITK source distribution retain their own notices."),
            LicensedComponent(
                identifier: "dicom-swift",
                name: "DICOM-Swift (DICOMweb client), Thales Matheus Mendonça Santos",
                license: "Apache-2.0",
                sourcePath: "Binaries/Splash/DICOM-Swift-LICENSE.txt",
                incorporated: true,
                origin: "remote-package",
                distributionNote: "Unmodified public DICOM-Swift 2.0.0-rc.1, revision 95df9768de8c905e619e150d3fe887aff3935af2. Horos links DicomWebClient and DicomData; optional codecs, ZIP, UI and server products are not linked. The package license, pertinent third-party notices and distribution provenance ship in Splash."),
            LicensedComponent(
                identifier: "horoscloud",
                name: "HorosCloud / Purview",
                license: "Proprietary notice in LICENSE",
                sourcePath: "LICENSE",
                incorporated: true,
                origin: "local-fork",
                distributionNote: "Present in this fork, absent from the donor fork's LICENSE. Do not import that removal. The bundled plugin archive, built for Intel only, is no longer shipped; the notice stays."),
            LicensedComponent(
                identifier: "external-libraries",
                name: "libtiff, libjpeg-turbo, libwebp, Zstandard, XZ Utils (liblzma)",
                license: "libtiff license, IJG/BSD-3-Clause/zlib, BSD-3-Clause, BSD-3-Clause or GPLv2, 0BSD",
                sourcePath: "Horos/Scripts/external-inputs.lock",
                incorporated: true,
                origin: "host",
                distributionNote: "Dynamic libraries in Contents/Frameworks, from the pinned bottles of external-inputs.lock. Their license texts and versions ship in Resources/ExternalLibraries."),
            LicensedComponent(
                identifier: "feedback-reporter",
                name: "FeedbackReporter",
                license: "Apache-2.0",
                sourcePath: "FeedbackReporter/LICENSE.txt",
                incorporated: true,
                origin: "host",
                distributionNote: "Pristine provider 92230feade69e1298cd5a8cbc0c8ddd2dc939934. Three host sources are selected once; project/eight XIB adaptations happen outside the provider. BuildSource.json records the framework inputs; 2.0 is a local history label. Apache texts accompany the framework."),
            LicensedComponent(
                identifier: "cocoa-http-server",
                name: "CocoaHTTPServer / Deusty Designs",
                license: "Deusty BSD notice",
                sourcePath: "cocoahttpserver/LICENSE.txt",
                incorporated: true,
                origin: "host",
                distributionNote: "Preserve the original Deusty text and existing author credits."),
            LicensedComponent(
                identifier: "dicom3tools",
                name: "dicom3tools / David A. Clunie, PixelMed Publishing",
                license: "BSD-style validator; Apache-2.0 Python packaging",
                sourcePath: "Binaries/Splash/ThirdParty/dicom3tools/COPYRIGHT",
                incorporated: true,
                origin: "host",
                distributionNote: "Validator snapshot 20260901072548, source/build/artifact pins and identity evidence in the bundled dciodvfy.lock.json. Acquisition preserves the identified helper; a local source rebuild is not claimed. Preserve its BSD-style terms and clinical disclaimer, distinct from Python packaging Apache terms."),
            LicensedComponent(
                identifier: "weasis",
                name: "Weasis portable 3.6.0 and its dependencies",
                license: "EPL-2.0; dependency MPL/LGPL/BSD/MIT and public-domain terms",
                sourcePath: "Binaries/Splash/ThirdParty/Weasis/EPL-2.0.txt",
                incorporated: true,
                origin: "host",
                distributionNote: "Separate portable application. Preserve embedded JAR notices and offer the corresponding sources listed in Splash/ThirdParty/licenses.html; dcm4che alternatives remain in its notices."),
            LicensedComponent(
                identifier: "libarchive-headers",
                name: "Apple libarchive headers",
                license: "BSD-2-Clause",
                sourcePath: "Horos/Sources/ThirdParty/Libarchive/UPSTREAM.json",
                incorporated: true,
                origin: "pinned-headers",
                distributionNote: "Headers from Apple revision 5649597e7975dd1f8c24ab0176f131f47a1cdae0, source version 3.7.4. Runtime is the installed macOS libarchive.2, not pinned to that version."),
            LicensedComponent(
                identifier: "nifti",
                name: "NIfTI / znzlib",
                license: "public domain / zlib-style",
                sourcePath: "Horos/Scripts/NIfTI/UPSTREAM.json",
                incorporated: true,
                origin: "upstream archive",
                distributionNote: "Unmodified files selected at build time from the nifti_clib archive of revision 8f72d1165aa62320cc6982d6ddd71a7f6b9924c5; notices remain in each file."),
            LicensedComponent(
                identifier: "legacy-controls",
                name: "Inherited controls and helpers",
                license: "CC BY-NC 1.0 / GPLv3+ / unresolved grants",
                sourcePath: "Binaries/Splash/ThirdParty/Native/Legacy/NOTICES.txt",
                incorporated: true,
                origin: "adapted-source",
                distributionNote: "The current KFSplitView engine is host code; Ken Ferry historical CC BY-NC 1.0 notice remains without claiming an alternative grant. CMIV Linköping FlyAssistant retains GPLv3+. Other named authors and unresolved grants remain in their notices."),
            LicensedComponent(
                identifier: "lets-move",
                name: "Native application installation and alias/Dock helpers",
                license: "LGPLv3 host / historical public-domain PFMove notice / unresolved alias-helper grant",
                sourcePath: "Horos/Sources/HorosApplicationInstaller.swift",
                incorporated: true,
                origin: "native-host",
                distributionNote: "The host Swift installer implements the historical PFMove entry point. LetsMove v1.25 candidate 70c5772c2ce84613ba539cb122e4065a9e33db5b was inspected and is not shipped. Historical Andy Kim/Potion Factory and Matt Brewer Dock notices remain; Matt Gallagher data-alias helpers are independent, with their separate grant unresolved."),
            LicensedComponent(
                identifier: "portal-javascript",
                name: "Portal JavaScript",
                license: "MIT / BSD / CC BY-SA 2.5",
                sourcePath: "Binaries/Splash/ThirdParty/Provenance.json",
                incorporated: true,
                origin: "web-resource",
                distributionNote: "jQuery 1.9.1 and Brandon Aaron mousewheel 3.1.3 are MIT; Paul Johnston SHA-1 2.2 is BSD; frequency decoder slider 1.4 is CC BY-SA 2.5. Exact snapshot revisions remain unestablished."),
            LicensedComponent(
                identifier: "host-sdk",
                name: "Nitrogen, DCM facade, API and helpers",
                license: "host LGPLv3 with preserved per-file terms",
                sourcePath: "LICENSE",
                incorporated: true,
                origin: "host-source",
                distributionNote: "Application and plugin SDK code, not new generic upstream dependencies; inherited SBJSON public headers retain their original BSD notices."),
            LicensedComponent(
                identifier: "weights",
                name: "External model weights",
                license: "not imported",
                sourcePath: "",
                incorporated: false,
                origin: "none",
                distributionNote: "No ONNX/PyTorch/HDF5 weights are shipped. Do not copy weights without their terms."),
        ]
    }

    @objc public static func incorporatedComponents() -> [LicensedComponent] {
        components().filter(\.incorporated)
    }

    @objc public static func materialQuestions() -> [String] {
        [
            "Horos is LGPLv3 and its linked libraries keep their own terms; do not treat the tree as uniformly LGPL.",
            "Unknown origins and unresolved grants are not distribution permission. Preserve historical KFSplitView CC BY-NC 1.0 notices and FlyAssistant GPLv3+ terms; the current split engine is host code.",
            "The Purview/HorosCloud notice is local; replacing LICENSE with the donor fork's file would delete it.",
            "The donor fork's source tree is not copied here. Credit its author without claiming exclusive authorship of Horos.",
            "This catalog is not a legal opinion and does not authorise distribution of an incompatible combination.",
        ]
    }

    @objc public static func preservesPurviewNotice(in licenseText: String) -> Bool {
        licenseText.contains("Purview") && licenseText.contains("HorosCloud")
    }

    @objc public static func creditsDonor(in text: String) -> Bool {
        text.contains(donorAuthor)
    }

    /// Whether a notice credits the author of this fork's changes.
    @objc public static func creditsForkAuthor(in text: String) -> Bool {
        text.contains("Thales Matheus M Santos")
    }

    @objc public static func isBlindOriginReplacement(originLicense: String,
                                                    workbenchLicense: String) -> Bool {
        originLicense == workbenchLicense
    }

    @objc public static func treatsAllComponentsAsLGPL() -> Bool {
        let licenses = Set(incorporatedComponents().map(\.license))
        return licenses.count == 1 && licenses.contains("LGPLv3")
    }

    @objc(missingNoticesInDirectory:)
    public static func missingNotices(inDirectory directory: URL) -> [String] {
        var missing: [String] = []
        let files = FileManager.default
        for name in requiredRootResourceNames {
            let url = directory.appendingPathComponent(name)
            if !files.isReadableFile(atPath: url.path) || (try? Data(contentsOf: url).isEmpty) != false {
                missing.append(name)
            }
        }
        let splash = directory.appendingPathComponent("Splash")
        for name in requiredSplashResourceNames {
            let url = splash.appendingPathComponent(name)
            if !files.isReadableFile(atPath: url.path) || (try? Data(contentsOf: url).isEmpty) != false {
                missing.append("Splash/\(name)")
            }
        }
        let thirdParty = splash.appendingPathComponent("ThirdParty")
        var texts = Set(requiredThirdPartyResourceNames)
        if let index = try? String(contentsOf: thirdParty.appendingPathComponent("licenses.html"), encoding: .utf8),
           let links = try? NSRegularExpression(pattern: "href=\"([^\"]+)\"") {
            for match in links.matches(in: index, range: NSRange(index.startIndex..., in: index)) {
                if let range = Range(match.range(at: 1), in: index) {
                    let path = String(index[range])
                    if !path.contains(":") && !path.hasPrefix("#") { texts.insert(path) }
                }
            }
        }
        for name in texts.sorted() {
            let url = thirdParty.appendingPathComponent(name)
            if !files.isReadableFile(atPath: url.path) || (try? Data(contentsOf: url).isEmpty) != false {
                missing.append("Splash/ThirdParty/\(name)")
            }
        }
        return missing
    }

    @objc(missingNoticesIn:)
    public static func missingNotices(in bundle: Bundle) -> [String] {
        guard let root = bundle.resourceURL else {
            return requiredRootResourceNames + requiredSplashResourceNames.map { "Splash/\($0)" }
                + requiredThirdPartyResourceNames.map { "Splash/ThirdParty/\($0)" }
        }
        return missingNotices(inDirectory: root)
    }

    @objc public static func aboutCreditsHTML() -> String {
        let rows = components().map { component in
            let status = component.incorporated ? "in the app" : "not copied"
            return "<li><strong>\(escape(component.name))</strong> — \(escape(component.license)). \(escape(status)). \(escape(component.distributionNote))</li>"
        }.joined(separator: "\n")
        return """
        <h2>Credits and licenses</h2>
        <p>This fork of Horos is maintained by <strong>\(forkAuthor)</strong> and is based on Horos and OsiriX. \(escape(forkCopyright)). The changes in this fork were not made or endorsed by the Horos Project.</p>
        <p>Selected excerpts were adapted from a donor fork of Horos authored by <strong>\(donorAuthor)</strong>, revision \(donorRevision). LICENSE and NOTICE preserve the credits and notices; COPYING.LESSER contains the LGPLv3 and GPLv3 terms. Reused excerpts keep their headers and are distinct from local modifications such as the Purview/HorosCloud notice.</p>
        <ul>
        \(rows)
        </ul>
        """
    }

    @objc public static func attributionSummary() -> String {
        let names = components().map(\.name).joined(separator: ", ")
        return "\(forkAuthor); Horos LGPLv3; OsiriX; \(donorAuthor); \(names)"
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
