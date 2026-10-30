#!/usr/bin/env python3
"""The parsed-file cache and the preview's pixel reuse follow the file revision.

`DCMPix` shares one parsed, memory-mapped `DCMObject` per source file across
every pix that reads it, in a process-wide dictionary that used to be keyed by
the pathname. While any pix for a path was alive (a browser preview, a second
viewer, a 4D set), a new pix for the same path — after a re-import, a rename
over the path or a reused database number — was served the previous file's
mapping: old geometry, old rescale, and pixels from a mapping of a file that
no longer exists. The browser also copied pixels from an open viewer by path.

Source level, on the real methods: every access to `cachedParsedDICOMFiles`
inside `loadDICOMWithDCMTK` uses `parsedFileCacheKey`, the release path uses
the key that was stored, the decoded pixels record their file revision, the
revert and the copy carry it, and the preview refuses a loaded frame whose
file no longer matches the disk. Object level: the key and the revision come
from `HorosFileRevision`, exercised by test-file-revision.py.
"""
from pathlib import Path
import re
import subprocess
import sys
from sources import class_text

root = Path(__file__).resolve().parents[1]


def read(path):
    """The working tree, or `<revision>:<path>` when a git revision is given (negative control)."""
    if len(sys.argv) > 1:
        return subprocess.check_output(['git', '-C', str(root), 'show', sys.argv[1] + ':' + path]).decode('latin1')
    return (root / path).read_bytes().decode('latin1')


# DCMPix.m, or the Swift class once DCMPix moved (DCMPix+Loading.swift has the cache).
try:
    pix = read('Horos/Sources/DCMPix.m')
except (subprocess.CalledProcessError, FileNotFoundError):
    pix = '' if len(sys.argv) > 1 else class_text('DCMPix')
pix_objc = '- (BOOL)loadDICOMWithDCMTK' in pix
header = read('Horos/Sources/DCMPix.h')
browser = class_text('BrowserController')
# The preview's reuse of a viewer's frame is Swift (BrowserController+Thumbnails.swift).
try:
    thumbnails = read('Horos/Sources/BrowserController+Thumbnails.swift')
except (subprocess.CalledProcessError, FileNotFoundError):
    thumbnails = ''
failures = []


def method(source, signature, terminator='\n}\n'):
    start = source.find(signature)
    if start < 0:
        return ''
    return source[start:source.find(terminator, start) + len(terminator)]


if pix_objc:
    # --- the cache is keyed by revision, everywhere it is touched ----------------
    load = method(pix, '- (BOOL)loadDICOMWithDCMTK\n')
    if not load:
        failures.append('loadDICOMWithDCMTK is gone from DCMPix.m')
    else:
        if 'NSString *parsedFileKey = [self parsedFileCacheKey];' not in load:
            failures.append('loadDICOMWithDCMTK does not compute the parsed-file key')
        for access in re.finditer(r'cachedParsedDICOMFiles (objectForKey|setObject:[^\]]*forKey|valueForKey):\s*([^\]\s]+)', load):
            if access.group(2) != 'parsedFileKey':
                failures.append('loadDICOMWithDCMTK still keys the cache by %s' % access.group(2))
        if load.count('cachedFileKey = [parsedFileKey retain];') != 2:
            failures.append('both the hit and the miss must remember the key they used (found %d)' % load.count('cachedFileKey = [parsedFileKey retain];'))

    clear = method(pix, '- (void) clearCachedDCMFrameworkFiles\n')
    if 'NSString *key = cachedFileKey ?: self.srcFile;' not in clear or 'removeObjectForKey:key]' not in clear:
        failures.append('clearCachedDCMFrameworkFiles must release under the key that stored the group')
    if 'cachedFileKey = nil;' not in clear:
        failures.append('clearCachedDCMFrameworkFiles must forget the key once the group is released')

    key = method(pix, '- (NSString*) parsedFileCacheKey\n')
    if '[HorosFileRevision cacheKeyForPath: self.srcFile]' not in key or 'return self.srcFile;' not in key:
        failures.append('parsedFileCacheKey must ask HorosFileRevision and fall back to the path')

    # --- decoded pixels remember the file they came from -------------------------
    check_load = method(pix, '- (void) CheckLoadIn\n')
    if 'loadedFileRevision = [[HorosFileRevision alloc] initWithPath: self.srcFile];' not in check_load:
        failures.append('CheckLoadIn does not record the file revision of the decoded pixels')
    if check_load.find('[loadedFileRevision release];') > check_load.find('loadedFileRevision = [[HorosFileRevision alloc]'):
        failures.append('the previous revision must be released before a new one is recorded')

    revert = method(pix, '- (void) revert:(BOOL) reloadAnnotations\n')
    if '[loadedFileRevision release];' not in revert or 'loadedFileRevision = nil;' not in revert:
        failures.append('revert: must forget the file revision with the pixels')

    copy = method(pix, '- (id)copyWithZone:(NSZone *)zone\n')
    if 'copy->loadedFileRevision = [self->loadedFileRevision retain];' not in copy:
        failures.append('a copy of decoded pixels must carry their file revision')

    dealloc = method(pix, '- (void) dealloc\n')
    for ivar in ('cachedFileKey', 'loadedFileRevision'):
        if '[%s release];' % ivar not in dealloc:
            failures.append('dealloc leaks %s' % ivar)

    matches = method(pix, '- (BOOL) loadedFileMatchesDisk\n')
    if 'return fImage == nil;' not in matches or 'matchesDisk]' not in matches:
        failures.append('loadedFileMatchesDisk must trust nothing decoded without a record and ask the disk otherwise')

    for declaration in ('- (NSString*) parsedFileCacheKey;', '- (id) loadedFileRevision;', '- (BOOL) loadedFileMatchesDisk;',
                        'NSString\t\t\t*cachedFileKey;', 'id\t\t\t\t\tloadedFileRevision;'):
        if declaration not in header:
            failures.append('DCMPix.h lacks %r' % declaration)

else:
    load = method(pix, '    final func loadDICOM() -> Bool {', '\n    }\n')
    if not load:
        failures.append('the DICOM loading is gone from DCMPix')
    elif 'let key = parsedFileCacheKey()' not in load or 'DCMPixParsedFileCache.take(key, parsed: parsed, for: self)' not in load:
        failures.append('the DICOM loading does not take the parsed file under the parsed-file key')
    take = method(pix, '    static func take(', '\n    }\n')
    for access in re.finditer(r'parsedFiles\.(?:object\(forKey|setObject\([^,]*, forKey): ([^)\s]+)', take):
        if access.group(1) not in ('$0', 'key!'):
            failures.append('the cache is still keyed by %s' % access.group(1))
    if take.count('pix.horos_cachedFileKey = key as NSString?') != 2:
        failures.append('both the hit and the miss must remember the key they used (found %d)'
                        % take.count('pix.horos_cachedFileKey = key as NSString?'))
    release = method(pix, '    static func release(_ pix: DCMPix) {', '\n    }\n')
    if ('let key = (pix.horos_cachedFileKey as String?) ?? pix.srcFile' not in release
            or 'parsedFiles.removeObject(forKey: key! as NSString)' not in release
            or 'func releaseParsedFile() { DCMPixParsedFileCache.release(self) }' not in pix):
        failures.append('releaseParsedFile must release under the key that stored the group')
    if 'pix.horos_cachedFileKey = nil' not in release:
        failures.append('releaseParsedFile must forget the key once the group is released')
    key = method(pix, '    final func cacheKey() -> String? {', '\n    }\n')
    if ('func parsedFileCacheKey() -> String! { cacheKey() }' not in pix
            or 'FileRevision.cacheKey(forPath: path)' not in key or 'return srcFile' not in key):
        failures.append('parsedFileCacheKey must ask HorosFileRevision and fall back to the path')
    check_load = method(pix, '    final func loadIfNeeded() {', '\n    }\n')
    recorded = check_load.find('horos_loadedFileRevision = FileRevision(path: path)')
    if recorded < 0:
        failures.append('CheckLoadIn does not record the file revision of the decoded pixels')
    elif not 0 <= check_load.find('horos_loadedFileRevision = nil') < recorded:
        failures.append('the previous revision must be dropped before a new one is recorded')
    revert = method(pix, '    final func revertLoading(', '\n    }\n')
    if 'self.horos_loadedFileRevision = nil' not in revert:
        failures.append('revert: must forget the file revision with the pixels')
    copy = method(pix, '    func copy(with zone: NSZone?) -> Any {', '\n    }\n')
    if 'copy.horos_loadedFileRevision = horos_loadedFileRevision' not in copy:
        failures.append('a copy of decoded pixels must carry their file revision')
    # Strong references, which the object releases when it goes.
    for storage in ('final var horos_cachedFileKey: NSString?', 'final var horos_loadedFileRevision: AnyObject?'):
        if storage not in pix:
            failures.append('DCMPix does not own %r' % storage)
    matches = method(pix, '    func loadedFileMatchesDisk() -> Bool {', '\n    }\n')
    if 'return horos_fImage == nil' not in matches or 'revision.matchesDisk()' not in matches:
        failures.append('loadedFileMatchesDisk must trust nothing decoded without a record and ask the disk otherwise')
    for declaration in ('- (NSString*) parsedFileCacheKey;', '- (id) loadedFileRevision;', '- (BOOL) loadedFileMatchesDisk;'):
        if declaration not in header:
            failures.append('DCMPix.h lacks %r' % declaration)
    # The former instance variables, still read by key.
    for name in ('cachedFileKey', 'loadedFileRevision'):
        if '"%s": object(' % name not in pix:
            failures.append('the former instance variable %s is not read by key' % name)

# --- the preview does not copy pixels of a file that changed -----------------
reuse = method(browser, '- (DCMPix*) getDCMPixFromViewerIfAvailable: (NSString*) pathToFind frameNumber: (int) frameNumber expectedFrame:')
if reuse:
    if '[dcmPix loadedFileMatchesDisk] == NO' not in reuse:
        failures.append('the browser reuses a viewer frame without checking the file on disk')
    if reuse.find('[dcmPix CheckLoad];') > reuse.find('loadedFileMatchesDisk'):
        failures.append('the disk check must come after CheckLoad, or an unloaded pix is judged before it has a revision')
    if 'refusalForReusingFileWithLoaded:' not in reuse:
        failures.append('the refusal to reuse must say why (HorosFileRevision refusal)')
    if not re.search(r'else if\( \[dcmPix isLoaded\]\)\s*\{\s*DCMPix \*dcmPixCopy = \[\[vPixList objectAtIndex: i\] copy\];', reuse):
        failures.append('the copy must only be taken when the pix is loaded and current')
else:
    reuse = method(thumbnails, 'nonisolated func getDCMPix(fromViewerIfAvailable pathToFind: String!, frameNumber: Int32, expectedFrame:', '\n    }\n}\n')
    if not reuse:
        failures.append('getDCMPixFromViewerIfAvailable:frameNumber:expectedFrame: is in neither BrowserController.m nor BrowserController+Thumbnails.swift')
    if 'if dcmPix.isLoaded() && !dcmPix.loadedFileMatchesDisk() {' not in reuse:
        failures.append('the browser reuses a viewer frame without checking the file on disk')
    if reuse.find('dcmPix.checkLoad()') < 0 or reuse.find('dcmPix.checkLoad()') > reuse.find('loadedFileMatchesDisk'):
        failures.append('the disk check must come after CheckLoad, or an unloaded pix is judged before it has a revision')
    if 'FileRevision.refusalForReusingFile(loaded:' not in reuse:
        failures.append('the refusal to reuse must say why (HorosFileRevision refusal)')
    if not re.search(r'\} else if dcmPix\.isLoaded\(\) \{\s*if let copy = dcmPix\.copy\(\) as\? DCMPix \{', reuse):
        failures.append('the copy must only be taken when the pix is loaded and current')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    raise SystemExit(1)
print('ok: the parsed-file cache and the preview reuse are keyed by file revision')
