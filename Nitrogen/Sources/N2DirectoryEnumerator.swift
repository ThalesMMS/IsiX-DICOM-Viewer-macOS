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

import Foundation

/// stat(2), which the class's own -stat: hides inside it.
private func posixStat(_ path: UnsafePointer<CChar>?, _ s: UnsafeMutablePointer<stat>?) -> Int32 {
    stat(path, s)
}

/// A directory enumerator on opendir/readdir: depth first, a folder before its
/// contents, readdir order within a folder, with a maximum number of items.
///
/// Implemented in Swift since #710; the Objective-C name, the selectors and
/// <Horos/N2DirectoryEnumerator.h> are those of the former class.
@objc(N2DirectoryEnumerator)
public final class N2DirectoryEnumerator: FileManager.DirectoryEnumerator {
    private var basepath: NSString?
    private var currpath: NSString?
    /// The open folders, innermost last, with their path below basepath.
    private var dirs: [(dir: UnsafeMutablePointer<DIR>, subpath: NSString?)] = []
    private var counter: UInt = 0
    private var max: UInt = 0

    /// Atomic in the former header; reads and writes of a BOOL are atomic here too.
    @objc public var filesOnly: Bool = false
    @objc public var recursive: Bool = false

    @objc(initWithPath:maxNumberOfFiles:)
    public init(path: String?, maxNumberOfFiles m: Int) {
        counter = 0
        max = UInt(bitPattern: m)
        currpath = nil
        basepath = path as NSString?
        recursive = true
        super.init()

        // opendir(NULL), for a nil path, opened nothing.
        if let path, let dir = opendir((path as NSString).fileSystemRepresentation) {
            pushDIR(dir, subpath: nil)
        }
    }

    /// -[NSObject init], which the class inherited: nothing to enumerate.
    public override init() {
        super.init()
    }

    deinit {
        while !dirs.isEmpty {
            popDIR()
        }
    }

    // MARK: NSEnumerator API

    public override var allObjects: [Any] {
        let all = NSMutableArray()

        var i: Any?
        repeat {
            i = nextObject()
            if let i { all.add(i) }
        } while i != nil

        return all as! [Any]
    }

    public override func nextObject() -> Any? {
        if counter >= max {
            return nil
        }
        counter += 1

        let fm = FileManager.default

//        if (currpath && ![fm fileExistsAtPath:[basepath stringByAppendingPathComponent:currpath]])
//            rewinddir(self.DIR); Why this? Antoine: this can lead to infinite loop

        var subpath: NSString?
        while let dir = dirAndSubpath(&subpath) {
            //NSLog(@"dir %X subpath %@", dir, subpath);
            if let dirp = readdir(dir) {
                let name = UnsafeRawPointer(dirp).advanced(by: MemoryLayout<dirent>.offset(of: \dirent.d_name)!)
                    .assumingMemoryBound(to: CChar.self)
                let subsubpath = fm.string(withFileSystemRepresentation: name, length: strlen(name)) as NSString
                //NSLog(@"nextItem %@", subsubpath);
                if subsubpath.isEqual(to: ".") || subsubpath.isEqual(to: "..") {
                    continue
                }

                let currpath: NSString = subpath.map { $0.appendingPathComponent(subsubpath as String) as NSString } ?? subsubpath
                self.currpath = currpath
                let fullpath = appendingToBasepath(currpath) ?? ""

                var isDir: ObjCBool = false
                if dirp.pointee.d_type == UInt8(DT_DIR)
                    || (dirp.pointee.d_type == UInt8(DT_UNKNOWN) && FileManager.default.fileExists(atPath: fullpath, isDirectory: &isDir) && isDir.boolValue) {
                    if recursive {
                        let sdir = opendir((fullpath as NSString).fileSystemRepresentation)
                        //NSLog(@"\tPushed");
                        if let sdir { pushDIR(sdir, subpath: currpath) }
                    }
                    if filesOnly { continue }
                }

                return currpath
            } else {
                popDIR()
            }
        }

        return nil
    }

    // MARK: NSDirectoryEnumerator API

    public override var fileAttributes: [FileAttributeKey: Any]? {
        // The Objective-C touched -allKeys of the dictionary here
        // (http://www.noodlesoft.com/blog/2007/03/07/mystery-bug-heisenbergs-uncertainty-principle/);
        // bridging it to Swift reads every entry.
        appendingToBasepath(currpath).flatMap { try? FileManager.default.attributesOfItem(atPath: $0) }
    }

    public override var directoryAttributes: [FileAttributeKey: Any]? {
        // As -fileAttributes.
        appendingToBasepath(currpath).flatMap { try? FileManager.default.attributesOfItem(atPath: $0) }
    }

    @objc(stat:)
    @discardableResult
    public func stat(_ s: UnsafeMutablePointer<Darwin.stat>?) -> Int32 {
        posixStat(appendingToBasepath(currpath).map { ($0 as NSString).fileSystemRepresentation }, s)
    }

    public override func skipDescendants() {
        skipDescendents()
    }

    // Only the folder just returned, and only if it was opened: after a file, or a
    // folder opendir refused, popping would close the parent and end its listing.
    public override func skipDescendents() {
        var subpath: NSString?
        if dirAndSubpath(&subpath) != nil, let currpath, let subpath, subpath.isEqual(to: currpath as String) {
            popDIR()
        }
    }

    public override var level: Int {
        let c = dirs.count
        return c != 0 ? c - 1 : c
    }

    // MARK: Private API

    /// `[basepath stringByAppendingPathComponent:currpath]`, where a nil
    /// currpath appended nothing; nil without a basepath (a nil path, or -init).
    private func appendingToBasepath(_ path: NSString?) -> String? {
        guard let basepath else { return nil }
        guard let path else { return basepath as String }
        return basepath.appendingPathComponent(path as String)
    }

    private func pushDIR(_ dir: UnsafeMutablePointer<DIR>, subpath p: NSString?) {
        dirs.append((dir, p))
    }

    private func dirAndSubpath(_ name: inout NSString?) -> UnsafeMutablePointer<DIR>? {
        guard let d = dirs.last else { return nil }
        name = d.subpath
        return d.dir
    }

    // Each handle is closed here, once, on the thread that enumerates (#627). A
    // thread used to be started for every closedir - one per folder of a scan -
    // which cost more than the call and left descriptors open until it ran.
    private func popDIR() {
        if let dir = dirs.popLast()?.dir {
            closedir(dir)
        }
    }
}
