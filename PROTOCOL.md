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
