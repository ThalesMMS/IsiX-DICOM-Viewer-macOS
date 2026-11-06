//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// What one copy of ITK in the process holds, for tests/test-plugin-own-libraries.py.
// The same source is compiled twice: into the host, against the application's
// ITK (ISIX_PROBE_HOST defined), and into the probe plugin, against the plugin's
// own copy. Each side reports its ITK version, its global state and the image
// that holds the code it runs, as one JSON object.

#ifndef ITK_STATE_PROBE_H
#define ITK_STATE_PROBE_H

#ifdef __cplusplus
extern "C" {
#endif

#ifdef ISIX_PROBE_HOST
#define ISIX_PROBE(name) isix_host_probe_##name
#else
#define ISIX_PROBE(name) isix_plugin_probe_##name
#endif

/// Sets this copy's global default number of threads to `threads` and
/// installs an output window of this side's own class, then reports.
const char *ISIX_PROBE(configure)(int threads);

/// Reports without changing anything.
const char *ISIX_PROBE(report)(void);

#ifdef __cplusplus
}
#endif

#endif
