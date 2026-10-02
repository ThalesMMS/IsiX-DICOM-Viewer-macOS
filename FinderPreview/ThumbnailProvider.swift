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
import QuickLookThumbnailing

/// Finder icon thumbnail. The process is this extension, not Horos.
@objc(ThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        switch FinderPreview.load(request.fileURL) {
        case .image(let image):
            let size = request.maximumSize
            handler(QLThumbnailReply(contextSize: size, currentContextDrawing: {
                image.draw(in: NSRect(origin: .zero, size: size),
                           from: NSRect(origin: .zero, size: image.size),
                           operation: .copy, fraction: 1)
                return true
            }), nil)
        case .failure(let reason):
            handler(nil, NSError(domain: "thalesmms.isis.workstation.FinderPreview",
                                 code: 1,
                                 userInfo: [NSLocalizedDescriptionKey: reason.sentence]))
        }
    }
}
