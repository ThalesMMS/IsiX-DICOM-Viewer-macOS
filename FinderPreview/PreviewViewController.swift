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
import Quartz

/// Quick Look preview. The process is this extension, not Horos.
///
/// The conformance is isolated to the main actor, like the view controller:
/// Quick Look asks a view-based preview for its content on the main thread.
@objc(PreviewViewController)
final class PreviewViewController: NSViewController, @MainActor QLPreviewingController {
    private let picture = NSImageView()
    private let message = NSTextField(wrappingLabelWithString: "")

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 512, height: 512))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.translatesAutoresizingMaskIntoConstraints = false
        message.isHidden = true
        message.alignment = .center
        message.font = NSFont.systemFont(ofSize: 16)
        message.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(picture)
        root.addSubview(message)
        NSLayoutConstraint.activate([
            picture.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            picture.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            picture.topAnchor.constraint(equalTo: root.topAnchor),
            picture.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            message.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            message.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            message.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        switch FinderPreview.load(url) {
        case .image(let image):
            picture.image = image
            picture.isHidden = false
            message.isHidden = true
        case .failure(let reason):
            picture.isHidden = true
            message.stringValue = reason.sentence
            message.isHidden = false
        }
        handler(nil)
    }
}
