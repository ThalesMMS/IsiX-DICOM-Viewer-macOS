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

// NSFileManager (N2) is implemented in Swift; the selectors and
// <Horos/NSFileManager+N2.h> are those of the former category. Where the
// Objective-C raised an NSException, this raises the same one: the callers
// catch it.
//
// -findSystemFolderOfType:forDomain:, -sizeAtPath:, -sizeAtFSRef: and
// -destinationOfAliasAtPath: stay in Objective-C, in NSFileManager+N2+CAPI.m:
// FSRef and the File Manager calls they make are not visible to Swift.

/// `[NSException raise:name format:…]`.
private func raise(_ name: NSExceptionName, _ reason: String) -> Never {
    NSException(name: name, reason: reason, userInfo: nil).raise()
    fatalError("NSException.raise() returned")
}

/// The directories -confirmDirectoryAtPath: found not writable, reported once each.
// nonisolated(unsafe): every use synchronizes on the set itself
// (objc_sync_enter/objc_sync_exit), as the former @synchronized did.
nonisolated(unsafe) private let reportedUnwritableDirectories = NSMutableSet()

public extension FileManager {

    // Hands the item to the system Trash of its own volume.
    //
    // This used to build ~/.Trash/<name> by hand and *delete* whatever was already
    // there under that name before moving the item in - so trashing a file could
    // permanently destroy an earlier, unrelated item the user had discarded. It
    // also sent items on other volumes to the home Trash as a cross-volume copy.
    // The system picks the destination, renames on collision, and on failure the
    // item stays where it was: nothing is ever deleted as a fallback.
    @objc(moveItemAtPathToTrash:)
    func moveItemAtPath(toTrash path: String?) {
        var error: NSError?
        if !moveItemAtPath(toTrash: path, resultingPath: nil, error: &error), let path, (path as NSString).length != 0 {
            NSLog("Could not move %@ to the Trash; it was left where it is: %@", path, error?.localizedDescription ?? "(null)")
        }
    }

    // The system Trash of the item's volume; NO, with the item left in place, when it
    // cannot be trashed. resultingPath is where the system put it.
    @objc(moveItemAtPathToTrash:resultingPath:error:)
    @discardableResult
    func moveItemAtPath(toTrash path: String?, resultingPath: AutoreleasingUnsafeMutablePointer<NSString?>?,
                        error: NSErrorPointer) -> Bool {
        resultingPath?.pointee = nil
        guard let path, (path as NSString).length != 0 else {
            error?.pointee = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError,
                                     userInfo: [NSLocalizedDescriptionKey: "No item was named to move to the Trash."])
            return false
        }
        var resulting: NSURL?
        do {
            try trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
        } catch let failure {
            error?.pointee = failure as NSError
            return false
        }
        resultingPath?.pointee = resulting?.path as NSString?
        return true
    }

    @discardableResult
    @objc func userApplicationSupportFolderForApp() -> String? {
        let url = urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let path = (url as NSURL?)?.path
        confirmDirectory(atPath: path)
        return path
    }

    @objc(tmpFilePathInDir:)
    @discardableResult
    func tmpFilePath(inDir dirPath: String?) -> String {
        guard let dirPath, (dirPath as NSString).length != 0 else {
            raise(.invalidArgumentException, "A temporary file requires a parent directory.")
        }
        let pattern = (dirPath as NSString).appendingPathComponent("file-XXXXXX") as NSString
        guard let buffer = strdup(pattern.fileSystemRepresentation) else {
            raise(.mallocException, "Could not allocate a temporary file path.")
        }
        let descriptor = mkstemp(buffer)
        let code = errno
        var path: String? = nil
        if descriptor >= 0 {
            path = string(withFileSystemRepresentation: buffer, length: strlen(buffer))
            // The API returns a reserved pathname, not an open file descriptor.
            close(descriptor)
        }
        free(buffer)
        guard let path else {
            raise(.genericException, "Could not create a temporary file (\(code)).")
        }
        return path
    }

    @discardableResult
    @objc func tmpDirPath() -> String {
        // "%@_%@": the description of the bundle name, "(null)" without one.
        var name = "(null)"
        if let value = Bundle.main.object(forInfoDictionaryKey: kCFBundleNameKey as String) {
            name = String(describing: value as AnyObject)
        }
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("\(name)_\(NSUserName())")
        confirmDirectory(atPath: path)
        return path
    }

    // A temporary directory, made by mkdtemp, inside a directory of the caller's
    // choosing. -tmpFilePathInDir: is the wrong thing to ask for when a directory is
    // wanted: mkstemp creates the file and leaves it there, so
    // -confirmDirectoryAtPath: on the same path then finds a file in its way and
    // raises. That took down a whole medium scan when a disc carried a ZIP.
    @objc(tmpDirectoryPathInDir:)
    @discardableResult
    func tmpDirectoryPath(inDir dirPath: String?) -> String {
        guard let dirPath, (dirPath as NSString).length != 0 else {
            raise(.invalidArgumentException, "A temporary directory requires a parent directory.")
        }
        confirmDirectory(atPath: dirPath)
        let pattern = (dirPath as NSString).appendingPathComponent("directory-XXXXXX") as NSString
        guard let buffer = strdup(pattern.fileSystemRepresentation) else {
            raise(.mallocException, "Could not allocate a temporary directory path.")
        }
        var path: String? = nil
        if mkdtemp(buffer) != nil { path = string(withFileSystemRepresentation: buffer, length: strlen(buffer)) }
        let code = errno
        free(buffer)
        guard let path else {
            raise(.genericException, "Could not create a temporary directory (\(code)).")
        }
        return path
    }

    @discardableResult
    @objc func tmpDirectoryPathInTmp() -> String {
        tmpDirectoryPath(inDir: tmpDirPath())
    }

    @discardableResult
    @objc func tmpFilePathInTmp() -> String {
        tmpFilePath(inDir: tmpDirPath())
    }

    @discardableResult
    private func confirmDirectory(atPath dirPath: String?, subDirectory: Bool) -> String? {
        guard let dirPath else { return nil }
        let parentDirPath = (dirPath as NSString).deletingLastPathComponent

        if !(dirPath as NSString).isEqual(to: parentDirPath) {
            confirmDirectory(atPath: parentDirPath, subDirectory: true)
        }

        var isDir: ObjCBool = false
        var create = false

        //NSLog(@"==> %@",dirPath);

        if !fileExists(atPath: dirPath, isDirectory: &isDir) {
            create = true
        } else {
            if !isDir.boolValue {
                if !(dirPath as NSString).isEqual(to: "/tmp") {
                    // A directory request must never destroy an existing file,
                    // including a file encountered in a parent path.
                    raise(.genericException, "Cannot create directory: an existing file occupies \(dirPath)")
                } else {
                    NSLog("/tmp issue workaround")
                }
            }
        }

        if create {
            do {
                try createDirectory(atPath: dirPath, withIntermediateDirectories: true, attributes: nil)
            } catch {
                // The file system answers "you don't have permission" for an ejected
                // disk, which sends the reader to permissions they never changed. And
                // the message named no path at all, so there was nothing to act on.
                raise(.genericException, StorageFailure.reason(forError: error as NSError, path: dirPath))
            }
        }

        if !subDirectory && !isWritableFile(atPath: dirPath) {
            // Every part of the database asks for its directory, so a read-only
            // volume produced this line more than twenty times per launch and
            // buried whatever else was said. Once per place is the information.
            objc_sync_enter(reportedUnwritableDirectories)
            if !reportedUnwritableDirectories.contains(dirPath) {
                reportedUnwritableDirectories.add(dirPath)
                NSLog("-------- confirmDirectoryAtPath %@ is writable == NO", dirPath)
            }
            objc_sync_exit(reportedUnwritableDirectories)
        }

        return dirPath
    }

    @objc(confirmDirectoryAtPath:)
    @discardableResult
    func confirmDirectory(atPath dirPath: String?) -> String? {
        confirmDirectory(atPath: dirPath, subDirectory: false)
    }

    // Resolves "X" and "X.noindex" to the directory "X.noindex", moving a legacy
    // "X" directory there when nothing occupies the new name yet.
    //
    // The two branches used to be swapped: a suffixed path looked for a legacy
    // "X.noindex.noindex", and an unsuffixed one cut eight characters off its own
    // name - out of range for a short path. A regular file in the way was deleted.
    // Nothing is deleted now. A file at the destination is an error the caller
    // sees, and when both directories exist both are kept as they are: merging or
    // replacing either one is not a decision a path helper can make.
    @objc(confirmNoIndexDirectoryAtPath:)
    @discardableResult
    func confirmNoIndexDirectory(atPath requested: String?) -> String? {
        // An empty request creates and renames nothing.
        guard var path = requested as NSString?, path.length != 0 else {
            return nil
        }

        let ext: NSString = ".noindex"

        // "INCOMING.noindex/" names the same directory as "INCOMING.noindex". This
        // runs for every file the database stores, so it reads one character
        // instead of searching.
        while path.length > 1 && path.character(at: path.length - 1) == 0x2F { // '/'
            path = path.substring(to: path.length - 1) as NSString
        }

        let pathWithExt: NSString
        let pathWithoutExt: NSString

        if path.hasSuffix(ext as String) {
            pathWithExt = path
            pathWithoutExt = path.substring(to: path.length - ext.length) as NSString
        } else {
            pathWithoutExt = path
            pathWithExt = path.appending(ext as String) as NSString
        }

        var pathWithExtIsDir: ObjCBool = false
        var pathWithExtExists = fileExists(atPath: pathWithExt as String, isDirectory: &pathWithExtIsDir)

        if pathWithExtExists && !pathWithExtIsDir.boolValue {
            raise(.genericException, "Cannot create directory at \(pathWithExt): a file already exists there and is left untouched")
        }

        // A last component that is only ".noindex" has no legacy name: its
        // "unsuffixed" form is the parent folder, which must never be moved into
        // itself. Read from the last character, without allocating a component.
        if !pathWithExtExists && pathWithoutExt.length > 0 && pathWithoutExt.character(at: pathWithoutExt.length - 1) != 0x2F {
            var pathWithoutExtIsDir: ObjCBool = false
            let pathWithoutExtExists = fileExists(atPath: pathWithoutExt as String, isDirectory: &pathWithoutExtIsDir)
            if pathWithoutExtExists && pathWithoutExtIsDir.boolValue {
                var error: NSError? = nil
                var moved: Bool
                do {
                    try moveItem(atPath: pathWithoutExt as String, toPath: pathWithExt as String)
                    moved = true
                } catch let failure {
                    error = failure as NSError
                    moved = false
                }
                pathWithExtExists = fileExists(atPath: pathWithExt as String, isDirectory: &pathWithExtIsDir)
                // Another thread may have created the destination meanwhile: then
                // both directories exist and both are kept, which is not a failure.
                if !pathWithExtExists || !pathWithExtIsDir.boolValue {
                    raise(.genericException, "Could not rename directory at \(pathWithoutExt) to \(pathWithExt): \(error?.localizedDescription ?? "no reason given")")
                }
                if !moved {
                    NSLog("Kept both %@ and %@: the second appeared while the first was being renamed (%@)",
                          pathWithoutExt, pathWithExt, error?.localizedDescription ?? "(null)")
                }
            }
        }

        return confirmDirectory(atPath: pathWithExt as String)
    }

    @objc(copyItemAtPath:toPath:byReplacingExisting:error:)
    @discardableResult
    func copyItem(atPath srcPath: String, toPath dstPath: String, byReplacingExisting replace: Bool,
                  error err: NSErrorPointer) -> Bool {
        var success = true
        var pairs: [(String, String)] = [(srcPath, dstPath)]

        while !pairs.isEmpty {
            let (srcPath, dstPath) = pairs.removeFirst()

            let srcPathRes = (srcPath as NSString).expandingTildeInPath	//[srcPath resolvedPathString];
            var dstPathRes = (dstPath as NSString).expandingTildeInPath	//[dstPath resolvedPathString];

            /*BOOL srcPathIsDir, srcPathExists = [self fileExistsAtPath:srcPathRes isDirectory:&srcPathIsDir]*/
            var dstPathIsDir: ObjCBool = false
            var dstPathExists = fileExists(atPath: dstPathRes, isDirectory: &dstPathIsDir)

            if dstPathExists && replace {
                try? removeItem(atPath: dstPath)
                dstPathRes = dstPath
                dstPathExists = fileExists(atPath: dstPathRes, isDirectory: &dstPathIsDir)
            }

            if !dstPathExists {
                var copied: Bool
                do {
                    try copyItem(atPath: srcPathRes, toPath: dstPathRes)
                    copied = true
                } catch {
                    err?.pointee = error as NSError
                    copied = false
                }
                success = copied && success
            } else if dstPathIsDir.boolValue {
                for subPath in (try? contentsOfDirectory(atPath: srcPathRes)) ?? [] {
                    pairs.append(((srcPath as NSString).appendingPathComponent(subPath),
                                  (dstPath as NSString).appendingPathComponent(subPath)))
                }
            }
        }

        return success
    }

    @objc(applyFileModeOfParentToItemAtPath:)
    @discardableResult
    func applyFileModeOfParentToItem(atPath path: String?) -> Bool {
        guard let path = path as NSString? else {
            return false // stat(NULL) failed
        }
        var st = stat()
        if stat((path.deletingLastPathComponent as NSString).fileSystemRepresentation, &st) == -1 {
            return false
        }

        if chmod(path.fileSystemRepresentation, st.st_mode & 0o777) == -1 {
            return false
        }

        return true
    }

    @available(*, deprecated)
    @objc(destinationOfAliasOrSymlinkAtPath:)
    @discardableResult
    func destinationOfAliasOrSymlink(atPath path: String?) -> String? {
        destinationOfAliasOrSymlink(atPath: path, resolved: nil)
    }

    @available(*, deprecated)
    @objc(destinationOfAliasOrSymlinkAtPath:resolved:)
    @discardableResult
    func destinationOfAliasOrSymlink(atPath path: String?, resolved r: UnsafeMutablePointer<ObjCBool>?) -> String? {
        //if (![self fileExistsAtPath:path]) {
        if let temp = (path as NSString?)?.byConditionallyResolvingAlias() {
            r?.pointee = true
            return temp
        }

        //	if (r) *r = NO;
        //	return path;
        //}

        if let path,
           let attrs = try? attributesOfItem(atPath: path),
           let type = attrs[.type] as? NSString, type.isEqual(to: FileAttributeType.typeSymbolicLink.rawValue) {
            r?.pointee = true
            return try? destinationOfSymbolicLink(atPath: path)
        }

        r?.pointee = false
        return path
    }

    @objc(enumeratorAtPath:limitTo:)
    @discardableResult
    func enumerator(atPath path: String?, limitTo maxNumberOfFiles: Int) -> N2DirectoryEnumerator {
        N2DirectoryEnumerator(path: path, maxNumberOfFiles: maxNumberOfFiles)
    }

    @objc(enumeratorAtPath:filesOnly:)
    @discardableResult
    func enumerator(atPath path: String?, filesOnly: Bool) -> N2DirectoryEnumerator {
        enumerator(atPath: path, filesOnly: filesOnly, recursive: true)
    }

    @objc(enumeratorAtPath:filesOnly:recursive:)
    @discardableResult
    func enumerator(atPath path: String?, filesOnly: Bool, recursive: Bool) -> N2DirectoryEnumerator {
        let de = N2DirectoryEnumerator(path: path, maxNumberOfFiles: -1)
        de.filesOnly = filesOnly
        de.recursive = recursive
        return de
    }
}
