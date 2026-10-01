# Selected-field anonymization test contract

The production helper edits only selected attributes at the dataset root.
This test contract deliberately retains empty-versus-remove, empty-only SQ,
private empty-only replacement. It does not assert
a confidentiality profile, recursive deidentification or an ISO 2022 encoder.

Replacement encoding uses the full root SpecificCharacterSet declaration and
the actual serialized VR (the dictionary VR for an absent element). PN, LO,
SH, ST, LT, UC and UT use that repertoire; other VRs and private creators use
ASCII. Simple declared charsets use DCMTK UTF-8 conversion with the explicit
abort-on-illegal-sequence flag and exact reverse-conversion equality. No
transliteration, byte discard or dataset-wide charset conversion is allowed.
Unknown declarations refuse nonempty affected text. Empty text remains safe.

DCMTK can decode ISO 2022 code extensions, but does not offer a destination
encoder for them. A declaration containing multiple terms or ISO 2022 accepts
only ASCII whose decoding under the full declaration is exactly the requested
text, including VR-specific delimiters. Non-ASCII requests are explicitly
refused with the selected tag. Raw ESC, NUL and C1 controls are also refused;
NUL would otherwise truncate a C-string replacement. Changing/clearing the
charset declaration is refused because unselected text would require global
re-encoding. An unchanged declaration is allowed.

An absent or empty declaration retains the host's existing default preference
and implicit Latin-1 fallback, with lossless Foundation encoding/round-trip.
This compatibility policy is distinct from an explicit ISO_IR 6 declaration,
which is ASCII. The editor does not rewrite the declaration to describe a
host default; it retains the legacy host interpretation for such inputs.

The discriminant is a PN request QA^Élodie under ISO 2022 IR 6\\ISO 2022 IR 87.
The previous implementation accepted Latin-1 byte C9 without an ISO 2022 escape;
strict Python iso2022_jp decoding refuses it. Pydicom's permissive IR 6 decoding
alone is not an encoding-validity oracle. The corrected batch refuses that
request and rolls back both files, including one encoded successfully in UTF-8.
The charset matrix checks strict raw replacement decoding, preserved declaration,
byte-identical unselected PN/LO (including escaped text), recursive unselected
semantics, pixels, UID/meta and original full-file hashes. It includes PN
components/groups/VM, LO, simple UTF-8/Latin-1, explicit ASCII, host defaults,
unrepresentable/unknown declarations, VRs outside the repertoire, empty values,
embedded controls and declaration changes. Failed batches leave no DICOM output.

Public field eligibility is frozen from the GDCM 3.2.11 dictionary as numeric
tag/policy data in `HorosSelectedAnonymizationCatalog.h`: 1 textual, 2 empty
binary, 3 empty-only public sequence. Repeating even groups 50xx/60xx/7fxx use
their base group. Generic group length is binary and private creators are LO.
The actual element is created using the pinned DCMTK dictionary. An unknown
or incompatible dictionary/serialized VR produces a field diagnostic, rather
than accepting a new binary/text conversion. A selected public SQ with no value
or an empty string is inserted/replaced as a present sequence with no items.
Success follows the insertion condition; an insertion failure reports the tag
and invalidates the batch. Nonempty SQ replacement is refused. Existing private
SQ can be emptied; an absent private data element is never created.

The sequence batch cases cover present, absent and already empty public SQ,
existing private SQ, nonempty public/private SQ refusal and absent private SQ
refusal. Pydicom checks presence, VR and item count, all unselected dataset/meta
values and pixels, including the same selected tag nested inside an unselected
sequence. Callbacks are counted: zero on success, exactly one per rejected input.
The separate insertion-fault executable replaces only the public SQ insertion
result with a bad condition in its temporary copy of the production helper.
This preserves the error/rollback checks without adding a production fault hook.

The storage whitelist is the 65 IOD classes previously enabled by the GDCM
storage gate, including DICOMDIR, retired classes, two Fuji classes and Siemens
CSA. A normal instance needs nonempty root UI SOPClassUID and SOPInstanceUID;
DICOMDIR uses its existing meta identity. Missing normal identity is refused
instead of falling back to meta or inferring SOP Class from Modality. Emptying
an SOP identity or choosing a class outside the whitelist is also refused.
Identity and transfer syntax UI values are limited to 64 serialized bytes
before string access; this uses the stored length without materializing the
value. Small 64/65-byte controls verify acceptance/refusal. No identity is
generated to repair invalid inputs. A selected empty compressed
PixelData is written with an empty BOT and no frames; clearing the byte-value
base class alone would retain its compressed representation. Malformed binary VR at a
textual field is explicitly refused, while valid existing textual VR is kept.

Serialization uses the original transfer syntax, EWM_updateMeta,
EGL_recalcGL, EPD_noChange and EET_UndefinedLength. Permitted changes are
preamble, legal padding, group lengths, ImplementationClassUID/VersionName,
sequence/item length encoding, and the deflate stream. Additional file meta is
retained; SOP meta mirrors selected root identities. Neither an extra meta
field nor an unselected private creator/data element is removed as a privacy
side effect. Equality of reserialized files is not the oracle.

The harness independently compares pydicom semantic trees and exact PixelData
Value Fields (including BOT/fragment sequence for encapsulated data), plus
original full-file hashes. Native LE/BE/implicit, valid deflated and real
multiframe RLE are generated locally. Other codec envelopes contain opaque
fragments and demonstrate byte preservation without codec registration, not
decoding validity. The existing 12-instance order verifier checks the export;
using that output for both of its destination arguments does not claim a Core
Data reimport or viewer inspection. Those remain app integration checks.

Payloads larger than DCM_MaxReadLength exercise deferred reads. Both input
and output verification use the shared HorosDCMTKSeekableInput owner. Deflated
input is backed by a private seekable file; its original transfer syntax is
read from retained meta, since the inflated dataset reports Explicit LE.
Both owners survive until their reads/save have ended and clean their backing.
The benign valid Deflated case verifies this serialization round trip without
repeating allocation probes or malformed-input campaigns owned by the reader. The production
helper probes deferred EOF, holds source/owner until save and verification,
compares leaf lengths and tree boundaries before publication, and checks
source identity/access/size/timestamps. It does not hash pixels twice in
production. File-level injections exercise source removal/truncation/access,
libc fwrite/fclose failures, and rename refusal. Injections are confined to
the existing test executable; production and upstream archives are unchanged.

Run `python3 tests/test-anonymization-diagnostics.py`; `--empty-sequences` selects
the sequence batches and the per-file gates. `--charsets` selects the 27 charset
batches, helpers and three established success/mixed-encoding/date batches only,
without parser failure injections or allocation probes. Dependencies missing
from the checkout cause exit 2. `HOROS_TEST_CONFIGURATION=Release` chooses
Release dependency archives. Historical `--compare` also needs built GDCM
and compares reports and semantic trees, never whole output-file bytes. The
sequence correction cases are excluded from historical equivalence: the former
backend deliberately reported a public-SQ empty failure even after mutation.
