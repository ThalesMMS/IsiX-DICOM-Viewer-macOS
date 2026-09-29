# DICOM-Swift (vendored DICOMweb client)

These files come from **DICOM-Swift**, the Swift DICOM package of the Isis
DICOM Viewer, by Thales Matheus Mendonça Santos, under the **Apache License,
Version 2.0**. The license is in [`LICENSE`](LICENSE), copied unchanged.

- Canonical source: <https://github.com/ThalesMMS/Isis-DICOM-Viewer>, folder
  `DICOM-Swift/`, revision `1947fefa46e646a23f73019fd083f169088a1ab1`
  (2026-09-23), `Sources/DicomCore/`.
- Public mirror: <https://github.com/ThalesMMS/DICOM-Swift>.

Horos builds them into the application target. Its own adapter,
`Horos/Sources/DICOMwebClient.swift` (`HorosDICOMwebClient`), sends every
request through them: QIDO-RS, WADO-RS and STOW-RS.

## What was taken

Only what the client uses: no codec, no ZIPFoundation, no pixel pipeline, no
server, no DicomData module.

| File | Status | Purpose |
|---|---|---|
| `DicomWebClientCore.swift` | modified, renamed | The client: search pages, retrieve into a sink, STOW-RS from files |
| `DicomWebSearchParameters.swift` | modified | QIDO-RS URL, matches, `includefield`, `limit`, `offset` |
| `DicomWebSearchPager.swift` | modified | QIDO-RS page and pager |
| `DicomWebMediaTypeNegotiator.swift` | modified | Accept headers, including the retrieve transfer syntax |
| `DicomWebMultipartStreamParser.swift` | modified | Streaming multipart/related parser |
| `DicomWebStoreResponse.swift` | modified | Per-instance STOW-RS results (accepted, warning, failed) |
| `DicomWebStreamingTransport.swift` | modified | Streamed response type and transport protocol defaults |
| `DicomPart10FileMetaParser.swift` | modified | Part 10 File Meta Information, for the STOW-RS part types |
| `DicomWebMultipartStreamWriter.swift` | modified | Streaming multipart writer for the STOW-RS body |
| `DicomWebSTOWMultipartBodyBuilder.swift` | unchanged | STOW-RS part preparation and size accounting |
| `DicomWebRetrieveSink.swift` | unchanged | Retrieve sink protocol |
| `DicomWebMediaType.swift` | unchanged | Media type parsing |
| `DicomWebOriginPolicy.swift` | unchanged | Same-origin checks for requests and credentials |
| `DicomWebError.swift` | unchanged | Fixed, body-free errors |

## What was changed

Each modified file says so in a notice at its top (Apache 2.0, section 4(b)).
In short:

- **DicomData is not vendored.** Search pages hold the DICOM JSON objects as
  `JSONSerialization` reads them, the store response is read the same way, a
  search match names its VR by its two-letter code, and the Part 10 parser
  reads its integers itself. Data sets, the DICOM JSON and native XML codecs,
  metadata, bulk data and Part 10 writing are left out, and so are the
  buffered frame, rendered, thumbnail and WADO-URI retrievals.
- **Horos brings the transport.** The URLSession transport is left out: the
  Horos adapter supplies one that follows no redirect, uses an ephemeral
  session, and streams bodies through files it owns and removes.
- **Retrieve transfer syntax.** `instanceAcceptHeader(transferSyntaxUID:)` and
  `retrieve(pathComponents:accept:sink:)` let a retrieve ask for a transfer
  syntax, or for the objects as stored. The store response is asked for as
  DICOM JSON only.
- **Multipart delimiters.** A part without Content-Length ends only at a whole
  delimiter line, so bytes that merely begin like one, inside PixelData, stay
  payload.
- **Query encoding.** Query values are percent-encoded with an ASCII-only set,
  so a filter with letters such as "é" no longer makes the URL invalid.
- **STOW-RS memory.** `payload(file:)` reads each 64 KiB chunk of a file in
  an autorelease pool of its own. Without it, the chunks FileHandle returns
  autoreleased stayed in memory until the Swift task reached its next
  `await`, after the whole request body was written: a 48 MiB file added
  about 48 MiB to the peak memory of the send.
- **File name.** `DicomWebClient.swift` became `DicomWebClientCore.swift`: it
  differs from Horos's `DICOMwebClient.swift` only by case, and the two would
  build into the same object file on a case-insensitive disk.

To compare with the original, diff each file against the same path at the
revision above; the first commit that added this folder holds the unchanged
copies.
