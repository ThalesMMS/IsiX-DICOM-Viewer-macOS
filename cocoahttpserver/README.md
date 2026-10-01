The `upstream/` directory contains byte-identical CocoaHTTPServer HTTP/DD
sources from revision `fd15e39ee6e959dae37950874f13f10171821006`
(2009-10-05), with their original BSD license. `UPSTREAM.json` records each
original SHA-256 and its actual production use. Root wrappers preserve the
existing Horos/OsiriX credits.

The production target compiles six original implementations through wrappers:
DDData, DDNumber, DDRange, HTTPAuthenticationRequest, HTTPConnection and
HTTPServer. The root public headers remain compatibility declarations with the
same instance-variable layout. HTTPResponse and HTTPAsyncFileResponse still
compile the response compatibility implementations; this production composition
is not a fully original eight-component HTTP core.

Host behavior lives outside the original sources. WebPortalServer installs a
HorosPortalSocket listener using narrow protected-ivar interop. AsyncSocket
creates accepted sockets using the listener's class. The socket bounds body
reads using the original connection's remaining-byte counters and the portal's
2 MiB upload budget. It does not parse HTTP or replace the transport.
WebPortalConnection chooses the authentication realm and synchronous TLS
settings on the portal's owning thread. The existing socket timeout delegate
extends original 30-second header/error writes to the host's 240-second deadline.
An overridden response preprocessor rejects null messages before the original
release point, inside the portal's existing exception and context guard. Parser,
Range, chunked framing, keepalive and response orchestration remain original.
Server defaults are configured through the original copying setters. The host
also supplies the existing startTLSThread compatibility selector, which is absent
from the pinned original source, and delegate conformance.

The remaining SDK distinction is explicit. The public HTTPResponse protocol has
an optional `int statusCode` selector; the pinned original protocol does not.
Production retains both response implementations using the same augmented
protocol, preserving the public metadata. An independent derived host protocol
can preserve the concrete selector and Swift override through a class facade,
but typed callers must use that host protocol and original HTTPResponse metadata
will no longer describe statusCode. Choosing that public SDK migration is
required before production can compile all eight original implementations.
The retained response classes also use the current file-attributes API and
schedule failed-initializer release through autorelease. Original initializers
return nil and release once; their deallocation occurs earlier.

The existing focused policy test compiles the production composition and, with
`--original-core`, all eight original implementations against the same host
adapters. Its synthetic wire scenarios exercise GET/HEAD, single and multiple
Range, chunked responses, keepalive, upload reads, TLS dispatch, deadline
callbacks, failed initializers and null-response protection. It also compiles
the SDK status caller and a derived-protocol/class-facade alternative. This is
focused source validation, not a full application or packaged-SDK build.

AsyncSocket, its Security-key provider, DDKeychain and SSCrypto remain host
compatibility components. Their descriptor ownership, native TLS and identity
adaptations are not covered by the HTTP source pin. The published transport and
identity interfaces remain available; no GCD transport migration is made here.
