/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork
//
//  NSString+SymlinksAndAliases.m
//  ResolvePath
//
//  Created by Matt Gallagher on 2010/02/22.
//  Copyright 2010 Matt Gallagher. All rights reserved.
//
//  Permission is given to use this source code file, free of charge, in any
//  project, commercial or otherwise, entirely at your risk, with the condition
//  that any redistribution (in part or whole) of source code must retain
//  this copyright and permission notice. Attribution in compiled projects is
//  appreciated but not required.
//

import Foundation

/// Paths through symbolic links and Finder aliases, for the database and
/// import folders a user may have replaced by an alias. The Objective-C
/// names are those of the former NSString (SymlinksAndAliases) category.
extension NSString {
    /// A standardized, absolute path with every symbolic link and alias in
    /// it resolved, component by component; nil when the path is relative or
    /// a link cannot be followed.
    @objc(stringByResolvingSymlinksAndAliases)
    public func resolvingSymlinksAndAliases() -> String? {
        let path = standardizingPath as NSString
        guard path.hasPrefix("/") else { return nil }
        let components = path.pathComponents
        // The first component, "/", needs no resolution.
        var resolved: String = components[0]
        for component in components.dropFirst() {
            guard let next = ((resolved as NSString).appendingPathComponent(component) as NSString)
                .byIterativelyResolvingSymlinkOrAlias() else { return nil }
            resolved = next
        }
        return resolved
    }

    /// The path with its last component resolved for as long as it is a
    /// symbolic link or an alias (an alias may stand anywhere in the path);
    /// the path itself when it does not exist, nil when a link cannot be followed.
    @objc(stringByIterativelyResolvingSymlinkOrAlias)
    public func byIterativelyResolvingSymlinkOrAlias() -> String? {
        var path: String? = self as String
        var info = stat()
        guard linkStatus(self as String, &info) else {
            return self as String
        }
        while let current = path {
            let isLink = (info.st_mode & S_IFMT) == S_IFLNK
            var aliasTarget: String?
            if !isLink {
                guard (info.st_mode & S_IFMT) != S_IFDIR,
                      let target = (current as NSString).byConditionallyResolvingAlias() else { break }
                aliasTarget = target
            }
            if isLink {
                guard let target = (current as NSString).byConditionallyResolvingSymlink() else { return nil }
                path = target
            } else {
                path = aliasTarget
            }
            if let next = path, !linkStatus(next, &info) {
                // A link to nothing.
                return nil
            }
        }
        return path
    }

    /// lstat(2) of a path, in its file system representation.
    private func linkStatus(_ path: String, _ info: inout stat) -> Bool {
        lstat(FileManager.default.fileSystemRepresentation(withPath: path), &info) >= 0
    }

    /// The target of the alias at the end of the path, or the path itself.
    @objc(stringByResolvingAlias)
    public func resolvingAlias() -> String {
        byConditionallyResolvingAlias() ?? self as String
    }

    /// The target of the symbolic link at the end of the path, or the path itself.
    @objc(stringByResolvingSymlink)
    public func resolvingSymlink() -> String {
        byConditionallyResolvingSymlink() ?? self as String
    }

    /// The target of the symbolic link at the end of the path, standardized
    /// when it is relative; nil when the path is not a link.
    @objc(stringByConditionallyResolvingSymlink)
    public func byConditionallyResolvingSymlink() -> String? {
        guard var target = try? FileManager.default.destinationOfSymbolicLink(atPath: self as String) else { return nil }
        if !target.hasPrefix("/") {
            target = (deletingLastPathComponent as NSString).appendingPathComponent(target)
            let standardized = (target as NSString).standardizingPath
            // Standardizing can lead back to this very path; keep the joined
            // one then, rather than loop on it.
            if standardized != self as String {
                target = standardized
            }
        }
        return target
    }

    /// The target of the Finder alias at the path; nil when it is not an
    /// alias or cannot be resolved without asking the user.
    @objc(stringByConditionallyResolvingAlias)
    public func byConditionallyResolvingAlias() -> String? {
        let url = URL(fileURLWithPath: self as String)
        // Bookmark data would also ask LaunchServices for quarantine
        // metadata; an ordinary file needs only the Finder alias flag.
        if let isAlias = try? url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile, !isAlias {
            return nil
        }
        guard let bookmark = try? NSURL.bookmarkData(withContentsOf: url) else { return nil }
        var stale = false
        guard let target = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI],
                                    relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return target.path
    }
}
