# Observed legacy network protocol

These notes describe experiments on one DCP-J315W, not a general Brother scanner
specification. Source pointers used during research:
[brscan's network transport](https://github.com/dmikushin/brscan/blob/51a719b7df0d31e3371868e0bb7ad0847dd2b89a/libsane-brother/brother_netdev.c),
[command definitions](https://github.com/dmikushin/brscan/blob/51a719b7df0d31e3371868e0bb7ad0847dd2b89a/libsane-brother/brother_mfccmd.h).

## Session

The device listens on TCP 54921 and sends ASCII `+OK 200\r\n` when accepting a
connection. The client consumes that greeting before sending commands. Closing
the socket releases the network session.

## Information query

Observed query bytes:

```text
ESC I LF
R=100,100 LF
M=GRAY256 LF
0x80
```

The response starts with a zero status byte and a little-endian two-byte payload
length. The observed 26-byte ASCII payload is:

```text
100,100,2,209,826,294,1157
```

Fields represent x/y resolution, flatbed source (2), width in mm/pixels and height
in mm/pixels. The prototype validates all fields and limits memory allocations.

## Tested scan request

```text
ESC X LF
R=100,100 LF
M=GRAY256 LF
C=NONE LF
B=50 LF
N=50 LF
U=OFF LF
P=OFF LF
A=0,0,816,1157 LF
0x80
```

Area coordinates are pixels. The tested width is aligned to 16 pixels and lies
within the advertised limit. `C=NONE` requests uncompressed data; no proprietary
decoder or tone table is involved.

The observed image records are byte `0x40`, followed by a little-endian two-byte
length, then one grayscale row. The aligned scan returned 1145 records with
816 data bytes each, followed by byte `0x80` at a record boundary. Pixel bytes can
also contain `0x80`, so checking arbitrary TCP chunk endings is not sufficient.

The first unaligned experiment returned 1145 rows of 826 pixels with visible
right-edge artifacts. Its short idle wait missed the page-end marker. The aligned
experiment with a longer wait received a confirmed end marker, and the native
client reproduced that successful acquisition. Scanner completion must be parsed
from the byte stream rather than assumed after a short idle timeout.

On interrupted or failed acquisition, `ESC R` is the researched cancellation
command. Native cancellation and malformed-transfer behaviour are checked using
a simulated scanner. Physical mid-scan cancellation has not yet been verified.

## Higher resolution and scan regions

Read-only queries also returned:

```text
150,150,2,209,1240,294,1736
300,300,2,209,2480,294,3472
```

A native 300 dpi grayscale full-bed request returned 3435 rows of 2480 bytes and
then a confirmed page-end marker. The height difference (37 rows, about 3.1 mm)
is similar in physical scale to the 12-row difference at 100 dpi. The reason is
not established. A full-bed image must use the actual row count.

**`A` carries left, top, right, bottom pixel coordinates**, not x/y/width/height.
The CLI accepts the latter and converts them. A 300 dpi request
`A=160,300,960,900` returned exactly 600 grayscale rows of 800 bytes; the image
content matched that offset region of the full-bed scan. The first region test
using width/height as absolute bounds failed strict row validation and produced
no output; correcting the bounds resolved it.

A physical 300 dpi acquisition cancelled after the first returned row exited
without a saved image. The first subsequent query timed out; a later 300 dpi
capability query succeeded. With bounded draining after cancellation, the client
exited in about 0.03 seconds in a second experiment, but an immediate capability
query still returned an unexpected response. Draining does not establish that
the hardware is instantly ready. Cancellation acknowledgement and recovery timing
remain open work, along with offline-device recovery.

## Observed colour framing and RGB conversion

Queries with `M=CGRAY` succeeded at 100 and 300 dpi, with the same dimensions as
gray at those resolutions. A controlled 100 dpi scan of the monochrome release
notes with `C=NONE` returned 1145 sets of three records:

- `0x44`, two-byte little-endian length 816, 816 bytes;
- `0x48`, two-byte little-endian length 816, 816 bytes;
- `0x4c`, two-byte little-endian length 816, 816 bytes.

A page-end `0x80` followed the final complete set. The stream length was 2,813,266
bytes. On white paper the middle channel was around 252/253, while the other two
were around 129/130. This suggests a luminance plus colour-difference encoding;
it is not direct RGB. This monochrome-page experiment alone could not determine which colour-difference
channel was which; the coloured-page experiment below resolved the assignment.
Fine sample alignment and calibrated colour fidelity still need investigation.

A second 100 dpi acquisition used a coloured artwork canvas and returned the same
record counts and dimensions. Decoding both possible chroma assignments showed a
clear difference: treating 0x44 as Cr and 0x4c as Cb reproduced the original's warm
yellow/orange sky, orange foliage and green foliage. The opposite interpretation
changed the sky and orange foliage to blue/cyan. The user supplied the digital
original, confirming the warm interpretation and channel order.

The native core subsequently acquired a 300 dpi colour scan: 2480 x 3435 pixels,
three records per row, and a confirmed page-end marker. It exported a native PNG
with 300 dpi metadata, an sRGB output profile, and file mode 0600. The independent
converter uses the full-range YCbCr inverse in
[ITU-T T.871 section 7](https://www.itu.int/rec/T-REC-T.871); it does not use a
vendor decoder, calibration blob or tone table. The result preserves the major
colour relationships in the original. This establishes channel assignment and
a practical conversion, not a calibrated colour match between digital source,
ink on paper and scanner. Colour-region geometry, fine colour registration and
150 dpi colour acquisition remain physically unverified.

The test object was a 30 x 30 cm printed canvas, larger than the approximately
30 x 20 cm scanner bed. The visible crop is therefore expected physical coverage,
not evidence of a colour-decoder crop error. The user confirmed that the colours
from the scan appear accurate against the canvas. This is a visual confirmation,
not a measured ICC calibration.

## Native macOS AirScan transport

The Mac adapter translates a local eSCL service into the legacy network core.
Its HTTP listener binds only to 127.0.0.1, and both its hostname record and
_uscan._tcp service are registered on Bonjour's local-only interface. Native
Image Capture discovers it through Apple's built-in AirScan scanner module.
The per-user installed LaunchAgent has been checked running with private
configuration and log permissions. A full reboot/login remains a separate check.

Important observations from actual native requests:

- JPEG capability/transport is needed by the tested Apple client for usable
  settings and visible previews. PNG-only capability advertising led to compact
  default requests and no visible overview. JPEG and PNG are now offered.
- Native clients can create a minimal job containing only input source, intent
  and BlackAndWhite1. Missing region/resolution/format fields use bounded defaults.
  Creating then deleting such a job must not move the scanner: acquisition is
  deferred until NextDocument is requested.
- ScannerCapabilities needs usable profiles, physical extents and resolution
  data. Native region coordinates use 1/300-inch units, converted to scan pixels.
  The core acquires a 16-pixel-aligned rectangle; the adapter crops the left edge
  and width back to the client's requested area. No missing pixels are invented.
- ScannerStatus job entries include JobUri, JobUuid, JobState and ImagesCompleted
  in their appropriate namespaces.
- Long acquisitions must not leave dead document requests able to consume the
  image. Pending NextDocument calls use a bounded wait and return 503 with
  Retry-After. The tested native client retries. Only a successful image send
  consumes the single flatbed page; subsequent NextDocument returns 404.

Actual native export produced a two-page PDF from the same stationary canvas:
300 dpi RGB (2445 x 3432 pixels), then 100 dpi grayscale (815 x 1144). Both PDF
pages have identical physical dimensions, 586.8 x 823.68 points. Page count, image
dimensions, colour-component counts and rendered appearance were checked.
