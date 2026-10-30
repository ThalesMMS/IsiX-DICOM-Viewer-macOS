/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import CoreData
import Foundation

/** \brief Base class for plugins

 The messages the application sends a filter plugin's principal class, with
 what they answer when a filter does not override them. The optional ones (the
 events and toolbar items of the viewers, the web portal's pages) are declared
 by HorosPluginFilterMessages (PluginFilter.h) and implemented here by none.
 */
@objc(PluginFilter)
open class PluginFilter: NSObject {
    /// Current (frontmost and active) 2D viewer containing an image serie, as
    /// -prepareFilter: was given it.
    @objc public var viewerController: ViewerController?

    @objc(filter)
    open class func filter() -> PluginFilter {
        self.init()
    }

    @objc public required override init() {
        super.init()
        initPlugin()
    }

    deinit {
        NSLog("PluginFilter dealloc")
    }

    // FUNCTIONS TO SUBCLASS

    /// Called to apply the plugin.
    @discardableResult
    @objc(filterImage:)
    open func filterImage(_ menuName: String?) -> Int {
        NSLog("Error, you should not be here!: %@", menuName ?? "(null)")
        return -1
    }

    /// The entry point of Pre-Process plugins.
    @discardableResult
    @objc(processFiles:)
    open func processFiles(_ files: NSMutableArray?) -> Int {
        0
    }

    /// The entry point of Report plugins: @"dateReport" answers the date the
    /// report was created or changed, @"deleteReport" deletes it, @"openReport"
    /// opens it, creating it when there is none.
    @discardableResult
    @objc(report:action:)
    open func report(_ study: NSManagedObject?, action: String?) -> Any? {
        nil
    }

    /// Called at startup, for the plugin's allocations.
    @objc open func initPlugin() {}

    /// Called when the application must unload the plugin, to install an update for example.
    @objc open func willUnload() {}

    /// Whether the plugin may run without the warning about plugins not certified for medical imaging.
    @objc open func isCertifiedForMedicalImaging() -> Bool {
        false
    }

    /// The plugin's opportunity to change the menus.
    @objc open func setMenus() {}

    // UTILITY FUNCTIONS

    /// The 2D viewers open in the application.
    @MainActor @objc open func viewerControllersList() -> [Any]? {
        ViewerController.getDisplayed2DViewers() as? [Any]
    }

    /// A new 2D window, with a copy of the current series.
    @discardableResult
    @MainActor @objc open func duplicateCurrent2DViewerWindow() -> ViewerController? {
        viewerController?.horosDuplicatedViewerWindow()
    }

    // Stubs that report filters override.

    @discardableResult
    @objc(reportDateForStudy:)
    open func reportDate(forStudy study: NSManagedObject?) -> Any? {
        nil
    }

    @discardableResult
    @objc(deleteReportForStudy:)
    open func deleteReport(forStudy study: NSManagedObject?) -> Bool {
        false
    }

    @discardableResult
    @objc(createReportForStudy:)
    open func createReport(forStudy study: NSManagedObject?) -> Bool {
        false
    }

    /// PRIVATE FUNCTIONS - DON'T SUBCLASS OR MODIFY
    @discardableResult
    @objc(prepareFilter:)
    open func prepareFilter(_ vC: ViewerController?) -> Int {
        NSLog("Prepare Filter")
        viewerController = vC
        return 0
    }
}
