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
@testable import IsiXPluginLoading

@Suite struct LegacyPluginLoadFailureTests {
    typealias Failure = LegacyPluginLoadFailure

    func linkError(_ reason: String?) -> NSError {
        var info: [String: Any] = [NSLocalizedDescriptionKey: "The bundle “Zombies.osirixplugin” couldn’t be loaded."]
        if let reason { info[NSDebugDescriptionErrorKey] = reason }
        return NSError(domain: NSCocoaErrorDomain, code: NSExecutableLinkError, userInfo: info)
    }

    // What dyld writes when a plugin linked with -undefined dynamic_lookup
    // looks for a symbol the application does not have.
    @Test func flatNamespaceSymbol() {
        let failure = Failure(linkError("dlopen(/Plugins/Zombies.osirixplugin/Contents/MacOS/Zombies, 0x0109): symbol not found in flat namespace '_NSThreadModalForWindowControllerKey'"))
        #expect(failure.isLinkError)
        #expect(!failure.isArchitectureMismatch)
        #expect(failure.dyldReason?.hasPrefix("dlopen(/Plugins/Zombies.osirixplugin") == true)
        #expect(failure.dyldMessage == "symbol not found in flat namespace '_NSThreadModalForWindowControllerKey'")
        #expect(failure.missingSymbol == "_NSThreadModalForWindowControllerKey")
        #expect(failure.linkDetail == failure.dyldMessage)
    }

    // A two-level namespace import: the symbol, then the lines naming the
    // binary that refers to it and the one expected to define it.
    @Test func twoLevelNamespaceSymbol() {
        let reason = """
        dlopen(/Plugins/Old.horosplugin/Contents/MacOS/Old, 0x0109): Symbol not found: _OBJC_IVAR_$_ViewerController.imageView
          Referenced from: <FFDD00A5-3B2F-38F7-B9AA-A27DE8B947F2> /Plugins/Old.horosplugin/Contents/MacOS/Old
          Expected in:     <7D613EAE-1D47-3D53-9780-E4B2329BCE8B> /Applications/IsiX.app/Contents/MacOS/IsiX
        """
        let failure = Failure(linkError(reason))
        #expect(failure.dyldReason == reason)
        #expect(failure.dyldMessage == "Symbol not found: _OBJC_IVAR_$_ViewerController.imageView")
        #expect(failure.missingSymbol == "_OBJC_IVAR_$_ViewerController.imageView")
        #expect(failure.linkDetail == "Symbol not found: _OBJC_IVAR_$_ViewerController.imageView")
    }

    @Test func noReasonOrAnotherError() {
        let silent = Failure(linkError(nil))
        #expect(silent.isLinkError && silent.dyldReason == nil && silent.dyldMessage == nil && silent.missingSymbol == nil && silent.linkDetail == nil)
        #expect(Failure(linkError("  \n")).dyldReason == nil)
        // A message without the dlopen prefix is kept as it is.
        #expect(Failure(linkError("something else went wrong")).linkDetail == "something else went wrong")
        #expect(Failure(linkError("something else went wrong")).missingSymbol == nil)

        // A missing library is a link error too; it names no symbol.
        let missingLibrary = Failure(linkError("dlopen(/Plugins/Old.horosplugin/Contents/MacOS/Old, 0x0109): Library not loaded: @executable_path/../Frameworks/HorosDCM.framework/Versions/A/HorosDCM"))
        #expect(missingLibrary.missingSymbol == nil)
        #expect(missingLibrary.linkDetail == "Library not loaded: @executable_path/../Frameworks/HorosDCM.framework/Versions/A/HorosDCM")

        // Another load error keeps its own description in the reason; the log still has dyld's.
        let loadError = Failure(NSError(domain: NSCocoaErrorDomain, code: NSExecutableLoadError, userInfo: [
            NSDebugDescriptionErrorKey: "dlopen(/Plugins/Old.horosplugin/Contents/MacOS/Old, 0x0109): not a mach-o file",
        ]))
        #expect(!loadError.isLinkError && loadError.linkDetail == nil)
        #expect(loadError.dyldMessage == "not a mach-o file")

        let architecture = Failure(domain: NSCocoaErrorDomain, code: NSExecutableArchitectureMismatchError, dyldReason: nil)
        #expect(architecture.isArchitectureMismatch && !architecture.isLinkError)
        #expect(!Failure(domain: "Other", code: NSExecutableLinkError, dyldReason: "x").isLinkError)
    }
}
