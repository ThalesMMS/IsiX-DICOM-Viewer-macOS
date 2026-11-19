/*
 Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)

 This file is free software: you can redistribute it and/or modify it under the
 terms of the GNU Lesser General Public License as published by the Free
 Software Foundation, version 3 of the License.

 It is distributed in the hope that it will be useful, but WITHOUT ANY
 WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
 A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.
 */

// The zlib functions the application's executable defines and exports.
//
// The executable this application started from carried a static copy of zlib
// 1.2.3 with the library's own names (no prefix), and exported every global
// symbol. The static linker therefore bound the zlib references of plugins
// linked with the application's executable as their bundle loader to the
// executable itself: such a plugin records "_inflate, from the executable",
// and dyld refuses to load it when the executable does not define the name.
// A re-export of the system library cannot answer it: the linker accepts
// re-exported symbols for libraries only. The executable has to define them.
//
// Each function here is the public function of that copy's zlib.h under its
// own name, and hands the call to the system's zlib. No second zlib enters the
// application. Since the executable now defines these names, a direct call
// would bind to this file again; the system's functions are reached through
// pointers resolved once, by name, in the system library's own image.
//
// The application's own static code that calls zlib is bound to these
// definitions too: it makes one more indirect call and reaches the same system
// library as before.
//
// This is C for two reasons. Swift cannot define a C function with variable
// arguments, which gzprintf is. And these definitions carry the names of the
// functions zlib.h declares: a C compiler checks each one against that
// declaration, where a Swift function exported under the same symbol would be
// a second, unchecked declaration of a name the imported library already has.

#include <dlfcn.h>
#include <pthread.h>
#include <stdarg.h>
#include <stddef.h>
#include <zlib.h>

// The header gives gzgetc as a macro over the function of the same name.
#undef gzgetc

#define LEGACY_ZLIB_EXPORT __attribute__((used, visibility("default")))

// result, name, parameters, arguments, and what the function answers if the
// system library could not give it (never expected): the error the caller
// already handles, never an abort. The parameters are those of zlib.h 1.2.3,
// which the system's header declares with the same types, and the compiler
// checks each definition against it.
#define LEGACY_ZLIB_FUNCTIONS(F) \
    F(const char *, zlibVersion, (void), (), ZLIB_VERSION) \
    F(uLong, zlibCompileFlags, (void), (), 0) \
    F(const char *, zError, (int code), (code), "") \
    \
    F(int, deflateInit_, (z_streamp strm, int level, const char *version, int stream_size), \
      (strm, level, version, stream_size), Z_STREAM_ERROR) \
    F(int, deflateInit2_, (z_streamp strm, int level, int method, int windowBits, int memLevel, int strategy, \
                           const char *version, int stream_size), \
      (strm, level, method, windowBits, memLevel, strategy, version, stream_size), Z_STREAM_ERROR) \
    F(int, deflate, (z_streamp strm, int flush), (strm, flush), Z_STREAM_ERROR) \
    F(int, deflateEnd, (z_streamp strm), (strm), Z_STREAM_ERROR) \
    F(int, deflateSetDictionary, (z_streamp strm, const Bytef *dictionary, uInt dictLength), \
      (strm, dictionary, dictLength), Z_STREAM_ERROR) \
    F(int, deflateCopy, (z_streamp dest, z_streamp source), (dest, source), Z_STREAM_ERROR) \
    F(int, deflateReset, (z_streamp strm), (strm), Z_STREAM_ERROR) \
    F(int, deflateParams, (z_streamp strm, int level, int strategy), (strm, level, strategy), Z_STREAM_ERROR) \
    F(int, deflateTune, (z_streamp strm, int good_length, int max_lazy, int nice_length, int max_chain), \
      (strm, good_length, max_lazy, nice_length, max_chain), Z_STREAM_ERROR) \
    F(uLong, deflateBound, (z_streamp strm, uLong sourceLen), (strm, sourceLen), 0) \
    F(int, deflatePrime, (z_streamp strm, int bits, int value), (strm, bits, value), Z_STREAM_ERROR) \
    F(int, deflateSetHeader, (z_streamp strm, gz_headerp head), (strm, head), Z_STREAM_ERROR) \
    \
    F(int, inflateInit_, (z_streamp strm, const char *version, int stream_size), \
      (strm, version, stream_size), Z_STREAM_ERROR) \
    F(int, inflateInit2_, (z_streamp strm, int windowBits, const char *version, int stream_size), \
      (strm, windowBits, version, stream_size), Z_STREAM_ERROR) \
    F(int, inflate, (z_streamp strm, int flush), (strm, flush), Z_STREAM_ERROR) \
    F(int, inflateEnd, (z_streamp strm), (strm), Z_STREAM_ERROR) \
    F(int, inflateSetDictionary, (z_streamp strm, const Bytef *dictionary, uInt dictLength), \
      (strm, dictionary, dictLength), Z_STREAM_ERROR) \
    F(int, inflateSync, (z_streamp strm), (strm), Z_STREAM_ERROR) \
    F(int, inflateSyncPoint, (z_streamp strm), (strm), Z_STREAM_ERROR) \
    F(int, inflateCopy, (z_streamp dest, z_streamp source), (dest, source), Z_STREAM_ERROR) \
    F(int, inflateReset, (z_streamp strm), (strm), Z_STREAM_ERROR) \
    F(int, inflatePrime, (z_streamp strm, int bits, int value), (strm, bits, value), Z_STREAM_ERROR) \
    F(int, inflateGetHeader, (z_streamp strm, gz_headerp head), (strm, head), Z_STREAM_ERROR) \
    F(int, inflateBackInit_, (z_streamp strm, int windowBits, unsigned char *window, const char *version, \
                              int stream_size), \
      (strm, windowBits, window, version, stream_size), Z_STREAM_ERROR) \
    F(int, inflateBack, (z_streamp strm, in_func in, void *in_desc, out_func out, void *out_desc), \
      (strm, in, in_desc, out, out_desc), Z_STREAM_ERROR) \
    F(int, inflateBackEnd, (z_streamp strm), (strm), Z_STREAM_ERROR) \
    \
    F(int, compress, (Bytef *dest, uLongf *destLen, const Bytef *source, uLong sourceLen), \
      (dest, destLen, source, sourceLen), Z_STREAM_ERROR) \
    F(int, compress2, (Bytef *dest, uLongf *destLen, const Bytef *source, uLong sourceLen, int level), \
      (dest, destLen, source, sourceLen, level), Z_STREAM_ERROR) \
    F(uLong, compressBound, (uLong sourceLen), (sourceLen), 0) \
    F(int, uncompress, (Bytef *dest, uLongf *destLen, const Bytef *source, uLong sourceLen), \
      (dest, destLen, source, sourceLen), Z_STREAM_ERROR) \
    \
    F(gzFile, gzopen, (const char *path, const char *mode), (path, mode), NULL) \
    F(gzFile, gzdopen, (int fd, const char *mode), (fd, mode), NULL) \
    F(int, gzsetparams, (gzFile file, int level, int strategy), (file, level, strategy), Z_STREAM_ERROR) \
    F(int, gzread, (gzFile file, voidp buf, unsigned len), (file, buf, len), -1) \
    F(int, gzwrite, (gzFile file, voidpc buf, unsigned len), (file, buf, len), 0) \
    F(int, gzputs, (gzFile file, const char *s), (file, s), -1) \
    F(char *, gzgets, (gzFile file, char *buf, int len), (file, buf, len), NULL) \
    F(int, gzputc, (gzFile file, int c), (file, c), -1) \
    F(int, gzgetc, (gzFile file), (file), -1) \
    F(int, gzungetc, (int c, gzFile file), (c, file), -1) \
    F(int, gzflush, (gzFile file, int flush), (file, flush), Z_STREAM_ERROR) \
    F(z_off_t, gzseek, (gzFile file, z_off_t offset, int whence), (file, offset, whence), -1) \
    F(int, gzrewind, (gzFile file), (file), -1) \
    F(z_off_t, gztell, (gzFile file), (file), -1) \
    F(int, gzeof, (gzFile file), (file), 1) \
    F(int, gzdirect, (gzFile file), (file), 0) \
    F(int, gzclose, (gzFile file), (file), Z_STREAM_ERROR) \
    F(const char *, gzerror, (gzFile file, int *errnum), (file, errnum), NULL) \
    \
    F(uLong, adler32, (uLong adler, const Bytef *buf, uInt len), (adler, buf, len), 0) \
    F(uLong, adler32_combine, (uLong adler1, uLong adler2, z_off_t len2), (adler1, adler2, len2), 0) \
    F(uLong, crc32, (uLong crc, const Bytef *buf, uInt len), (crc, buf, len), 0) \
    F(uLong, crc32_combine, (uLong crc1, uLong crc2, z_off_t len2), (crc1, crc2, len2), 0)

#define LEGACY_ZLIB_POINTER(result, name, parameters, arguments, failure) result (*name) parameters;
#define LEGACY_ZLIB_RESOLVE(result, name, parameters, arguments, failure) \
    systemZlib.name = (result (*) parameters)dlsym(library, #name);
#define LEGACY_ZLIB_DEFINE(result, name, parameters, arguments, failure) \
    LEGACY_ZLIB_EXPORT result name parameters \
    { \
        pthread_once(&systemZlibOnce, resolveSystemZlib); \
        return systemZlib.name ? systemZlib.name arguments : (failure); \
    }

// Zlib 1.2.3 declared the table of get_crc_table as unsigned long, eight bytes
// an entry in a 64-bit process; the system's has four-byte entries. A caller
// built with the older header indexes eight-byte entries, so it is given the
// 256 values of the system's table at that width.
enum { legacyCRCTableLength = 256 };

static struct {
    LEGACY_ZLIB_FUNCTIONS(LEGACY_ZLIB_POINTER)
    void (*gzclearerr)(gzFile file);
    int (*gzvprintf)(gzFile file, const char *format, va_list arguments);
    const unsigned long *crcTable;
} systemZlib;

static pthread_once_t systemZlibOnce = PTHREAD_ONCE_INIT;

static void resolveSystemZlib(void)
{
    // The handle is the system library's image, which is part of the system
    // and already loaded with the process. A lookup in it never answers with a
    // function of this file, as a lookup among all images would.
    void *library = dlopen("/usr/lib/libz.1.dylib", RTLD_LAZY | RTLD_LOCAL);
    if (library == NULL)
        return;

    LEGACY_ZLIB_FUNCTIONS(LEGACY_ZLIB_RESOLVE)
    systemZlib.gzclearerr = (void (*)(gzFile))dlsym(library, "gzclearerr");
    systemZlib.gzvprintf = (int (*)(gzFile, const char *, va_list))dlsym(library, "gzvprintf");

    static unsigned long widened[legacyCRCTableLength];
    const z_crc_t *(*table)(void) = (const z_crc_t *(*)(void))dlsym(library, "get_crc_table");
    const z_crc_t *entries = table ? table() : NULL;
    if (entries != NULL) {
        for (int position = 0; position < legacyCRCTableLength; position++)
            widened[position] = entries[position];
        systemZlib.crcTable = widened;
    }
}

LEGACY_ZLIB_FUNCTIONS(LEGACY_ZLIB_DEFINE)

LEGACY_ZLIB_EXPORT void gzclearerr(gzFile file)
{
    pthread_once(&systemZlibOnce, resolveSystemZlib);
    if (systemZlib.gzclearerr)
        systemZlib.gzclearerr(file);
}

// The arguments go on as a list: a function with variable arguments cannot
// hand them to another one.
LEGACY_ZLIB_EXPORT int gzprintf(gzFile file, const char *format, ...)
{
    pthread_once(&systemZlibOnce, resolveSystemZlib);
    if (systemZlib.gzvprintf == NULL)
        return 0;
    va_list arguments;
    va_start(arguments, format);
    int written = systemZlib.gzvprintf(file, format, arguments);
    va_end(arguments);
    return written;
}

// Defined under another C name, with the symbol the callers ask for, because
// its result type is the older header's and the system's header declares
// get_crc_table with the narrower one.
const unsigned long *IsiXLegacyZlibCRCTable(void) __asm__("_get_crc_table");

LEGACY_ZLIB_EXPORT const unsigned long *IsiXLegacyZlibCRCTable(void)
{
    pthread_once(&systemZlibOnce, resolveSystemZlib);
    return systemZlib.crcTable;
}
