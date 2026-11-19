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
import CoreVideo
import IsiXDICOMFile

// Selectors of several classes in the plugin SDK of Horos and OsiriX whose
// work moved to another type or another name: a plugin built for that SDK
// still sends the old one, and each answers by what does the work now.
extension QuicktimeExport {
    /// A pixel buffer of the image, +1: the caller releases it.
    @objc(CVPixelBufferFromNSImage:) nonisolated class func legacyPixelBuffer(from image: NSImage?) -> Unmanaged<CVPixelBuffer>? {
        CVPixelBufferFromNSImage(image)
    }
}

extension AnonymizationTagsPopUpButton {
    @objc(selectedDCMAttributeTag) var legacySelectedDCMAttributeTag: DICOMAttributeTag? {
        get { selectedAttributeTag }
        set { selectedAttributeTag = newValue }
    }

    @objc class var keyPathsForValuesAffectingSelectedDCMAttributeTag: Set<String> { ["selectedAttributeTag"] }
}

extension O2DicomPredicateEditorView {
    @objc(DCMAttributeTag) var legacyDCMAttributeTag: DICOMAttributeTag? {
        get { attributeTag }
        set { attributeTag = newValue }
    }

    @objc class var keyPathsForValuesAffectingDCMAttributeTag: Set<String> { ["attributeTag"] }
}

extension QueryController {
    /// The query of one instance of the automatic queries; the index only told the log which one.
    @objc(queryWithDisplayingErrors:instance:index:)
    func legacyQuery(displayingErrors showError: Bool, instance: NSMutableDictionary?, index: Int32) -> Bool {
        queryWithDisplayingErrors(showError, instance: instance)
    }

    /// The timer of the automatic queries fired.
    @objc(autoQueryTimerFunction:) func legacyAutoQueryTimerFunction(_ timer: Timer?) { autoQueryTimer(timer) }

    /// The body of the thread of an automatic query. The queries run on the
    /// window's own schedule: this asks for one now and returns.
    @objc(autoQueryThread:) nonisolated func legacyAutoQueryThread(_ instance: [AnyHashable: Any]?) {
        Task { @MainActor [weak self] in self?.autoQueryTimer(nil) }
    }

    /// Shows the results of an automatic query and retrieves what its instance asks for.
    @objc(displayAndRetrieveQueryResults:) func legacyDisplayAndRetrieveQueryResults(_ instance: [AnyHashable: Any]?) {
        autoQueryInstancesDidChange()
    }
}

extension SendController {
    /// The body of the thread that sent the controller's files, list by list.
    /// Sends are queued now: this queues the controller's own send to the
    /// destination its sheet shows, on the main thread, and returns. The
    /// reference the send gives back when it is queued is taken here.
    @objc(sendDICOMFilesOffis:) nonisolated func legacySendDICOMFilesOffis(_ lists: [AnyHashable: Any]?) {
        Task { @MainActor [self] in
            _ = Unmanaged.passRetained(self)
            sendToNode(nil)
        }
    }

    /// Waited for the send and released the controller. The queue keeps what it needs: nothing is released twice.
    @objc(releaseSelfWhenDone:) nonisolated func legacyReleaseSelfWhenDone(_ sender: Any?) {}
}
