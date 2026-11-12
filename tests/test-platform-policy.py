#!/usr/bin/env python3
"""Product macOS 15 policy, SDK vs encoded target, and update eligibility."""
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = root / 'Horos/Sources/HorosPlatformPolicy.swift'
assert source.is_file(), 'FAIL: HorosPlatformPolicy.swift is missing'

driver = r'''
import Foundation

@main struct Check {
    static func main() {
        precondition(HorosPlatformPolicy.productMinimumMajor == 15)
        precondition(HorosPlatformPolicy.productMinimumMinor == 0)
        precondition(HorosPlatformPolicy.productMinimumDisplay() == "15.0")

        let v150 = HorosPlatformPolicy.parseVersion("15.0")!
        let v155 = HorosPlatformPolicy.parseVersion("15.5")!
        let v146 = HorosPlatformPolicy.parseVersion("14.6")!
        let v265 = HorosPlatformPolicy.parseVersion("26.5")!
        let v2662 = HorosPlatformPolicy.parseVersion("26.6.2")!
        let v27 = HorosPlatformPolicy.parseVersion("27.0")!
        let v11 = HorosPlatformPolicy.parseVersion("11.0")!
        precondition(v265.major == 26 && v265.minor == 5)
        precondition(v2662.patch == 2)
        precondition(v265 < v27)
        precondition(v11 < v146 && v146 < v150 && v150 < v155 && v155 < v265)

        // The SDK on this host can express the product minimum; an older one
        // cannot, which is the case the policy exists to keep separate.
        precondition(!HorosPlatformPolicy.sdkCanEncodeProductMinimum(v146))
        precondition(!HorosPlatformPolicy.sdkCanEncodeProductMinimum(sdk: "14.6"))
        precondition(HorosPlatformPolicy.sdkCanEncodeProductMinimum(v150))
        precondition(HorosPlatformPolicy.sdkCanEncodeProductMinimum(sdk: "26.5"))
        precondition(HorosPlatformPolicy.sdkCanEncodeProductMinimum(v27))

        precondition(HorosPlatformPolicy.encodedTargetIsLegal(encoded: v150, sdk: v265))
        precondition(HorosPlatformPolicy.encodedTargetIsLegal(encoded: v11, sdk: v265))
        precondition(!HorosPlatformPolicy.encodedTargetIsLegal(encoded: v27, sdk: v265))
        precondition(HorosPlatformPolicy.encodedTargetIsLegal(encoded: v27, sdk: v27))

        // A 15.0 package reaches a 15.5 or a 26.6.2 Mac and must never reach a 14.6 one.
        precondition(HorosPlatformPolicy.shouldOfferInstallableUpdate(runtime: v155, packageMinimum: v150))
        precondition(HorosPlatformPolicy.shouldOfferInstallableUpdate(runtime: "26.6.2", packageMinimum: "15.0"))
        precondition(!HorosPlatformPolicy.shouldOfferInstallableUpdate(runtime: v146, packageMinimum: v150))
        precondition(!HorosPlatformPolicy.shouldOfferInstallableUpdate(runtime: "14.6", packageMinimum: "15.0"))
        // A package of the former 26.0 minimum still never reaches a 15.5 Mac.
        precondition(!HorosPlatformPolicy.shouldOfferInstallableUpdate(runtime: "15.5", packageMinimum: "26.0"))
        precondition(!HorosPlatformPolicy.shouldOfferInstallableUpdate(runtime: v2662, packageMinimum: v27))
        precondition(HorosPlatformPolicy.shouldOfferInstallableUpdate(runtime: v2662, packageMinimum: v11))

        let blocked = HorosPlatformPolicy.incompatibilityMessage(runtime: v146)!
        precondition(blocked.contains("macOS 15.0"))
        precondition(blocked.contains("14.6"))
        precondition(HorosPlatformPolicy.incompatibilityMessage(runtime: v150) == nil)
        precondition(HorosPlatformPolicy.incompatibilityMessage(runtime: v2662) == nil)

        // The Swift runtime has been in macOS since 10.14.4, so a product that
        // starts at 15.0 never needs a copy inside the bundle. An orphan there
        // is an artefact of an earlier deployment target.
        precondition(!HorosPlatformPolicy.bundleMayEmbedSwiftRuntime(productMinimum: v150))
        precondition(!HorosPlatformPolicy.bundleMayEmbedSwiftRuntime(productMinimum: "15.0"))
        precondition(!HorosPlatformPolicy.bundleMayEmbedSwiftRuntime(productMinimum: v146))
        precondition(HorosPlatformPolicy.bundleMayEmbedSwiftRuntime(
            productMinimum: HorosPlatformPolicy.parseVersion("10.13")!))
        precondition(!HorosPlatformPolicy.bundleMayEmbedSwiftRuntime(
            productMinimum: HorosPlatformPolicy.swiftRuntimeInOSSince))
        precondition(HorosPlatformPolicy.embeddedFileIsSwiftRuntime("libswift_Concurrency.dylib"))
        precondition(HorosPlatformPolicy.embeddedFileIsSwiftRuntime("libswiftCore.dylib"))
        precondition(!HorosPlatformPolicy.embeddedFileIsSwiftRuntime("libswift_Concurrency.dylib.bak"))
        precondition(!HorosPlatformPolicy.embeddedFileIsSwiftRuntime("Horos"))
        precondition(!HorosPlatformPolicy.embeddedFileIsSwiftRuntime("libgdcmMSFF.dylib"))

        // Span is in macOS only since 26.0: a product that starts at 15.0 and
        // uses it loads the toolchain's back-deployment library from its own
        // bundle, and does not launch on macOS 15 without it. From 26.0 on the
        // macOS has it and the copy is an orphan again. The runtime itself and
        // a library that is not Swift's are judged as before.
        let span = "libswiftCompatibilitySpan.dylib"
        precondition(HorosPlatformPolicy.embeddedFileIsSwiftRuntime(span))
        precondition(HorosPlatformPolicy.bundleMayEmbedSwiftRuntime(named: span, productMinimum: v150))
        precondition(HorosPlatformPolicy.bundleMayEmbedSwiftRuntime(named: span, productMinimum: "15.0"))
        precondition(HorosPlatformPolicy.bundleMayEmbedSwiftRuntime(
            named: span, productMinimum: HorosPlatformPolicy.productMinimum))
        precondition(HorosPlatformPolicy.bundleMayEmbedSwiftRuntime(named: span, productMinimum: v155))
        precondition(!HorosPlatformPolicy.bundleMayEmbedSwiftRuntime(named: span, productMinimum: "26.0"))
        precondition(!HorosPlatformPolicy.bundleMayEmbedSwiftRuntime(named: span, productMinimum: v265))
        precondition(!HorosPlatformPolicy.bundleMayEmbedSwiftRuntime(named: span, productMinimum: v27))
        precondition(!HorosPlatformPolicy.bundleMayEmbedSwiftRuntime(named: span, productMinimum: "not a version"))
        for runtime in ["libswiftCore.dylib", "libswift_Concurrency.dylib", "libswiftCompatibilityUnknown.dylib"] {
            precondition(!HorosPlatformPolicy.bundleMayEmbedSwiftRuntime(named: runtime, productMinimum: v150))
            precondition(HorosPlatformPolicy.bundleMayEmbedSwiftRuntime(named: runtime, productMinimum: "10.13"))
        }
        precondition(!HorosPlatformPolicy.bundleMayEmbedSwiftRuntime(named: "libgdcmMSFF.dylib", productMinimum: "10.13"))
        precondition(!HorosPlatformPolicy.bundleMayEmbedSwiftRuntime(named: span + ".bak", productMinimum: v150))

        // The audit of the built bundles reads a second thing in that answer:
        // while the bundle may carry a back-deployment library, the macOS of
        // the minimum does not have it, so code that loads it finds it in the
        // bundle or does not start. That holds only if the answer changes at
        // the macOS that has the library and nowhere else, for every library
        // the policy lists.
        precondition(HorosPlatformPolicy.swiftBackDeploymentLibraryInOSSince[span]
                     == HorosPlatformPolicy.parseVersion("26.0")!)
        for (library, since) in HorosPlatformPolicy.swiftBackDeploymentLibraryInOSSince {
            precondition(HorosPlatformPolicy.embeddedFileIsSwiftRuntime(library))
            precondition(HorosPlatformPolicy.swiftRuntimeInOSSince < since)
            let before = HorosPlatformPolicy.Version(major: since.major - 1, minor: 99, patch: 99)
            precondition(HorosPlatformPolicy.bundleMayEmbedSwiftRuntime(named: library, productMinimum: before))
            precondition(HorosPlatformPolicy.bundleMayEmbedSwiftRuntime(named: library, productMinimum: before.display))
            precondition(!HorosPlatformPolicy.bundleMayEmbedSwiftRuntime(named: library, productMinimum: since))
            precondition(!HorosPlatformPolicy.bundleMayEmbedSwiftRuntime(named: library, productMinimum: since.display))
        }

        precondition(HorosPlatformPolicy.trackedSigningTeamIsAllowed(""))
        precondition(HorosPlatformPolicy.trackedSigningTeamIsAllowed("$(HOROS_DEVELOPMENT_TEAM)"))
        precondition(!HorosPlatformPolicy.trackedSigningTeamIsAllowed("TPT6TVH8UY"))
        precondition(HorosPlatformPolicy.donorSigningTeamThatMustNotBeCopied == "TPT6TVH8UY")

        print("PASS: product minimum 15.0 is encodable by this SDK, an older SDK cannot encode it, a 15.0 package never reaches an older Mac, and the bundle needs no Swift runtime of its own beyond the back-deployment library for Span")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='horos-platform-policy-') as folder:
    path = Path(folder)
    (path / 'check.swift').write_text(driver)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(source),
                    str(path / 'check.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
