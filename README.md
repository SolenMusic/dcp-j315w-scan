# DCP-J315W Network Scanner

A separate, independent native network-scanning prototype for the **Brother
DCP-J315W**. This project has no CUPS dependency and is separate from the
`dcp-j315w-cups` printing repository.

Created with LLM-assisted coding and controlled experiments on a real printer.
The first native ARM64 macOS scan has succeeded over Wi-Fi: the release-notes
page was acquired at 100 dpi grayscale, with a confirmed device page-end marker.
The result is 816 x 1145 pixels and contains readable text with a clean right edge.

## Current scope

- Direct IPv4 connection to the legacy scanner service on TCP port 54921.
- Read-only 100 dpi grayscale capability query.
- One flatbed grayscale scan at 100 dpi, saved locally as an 8-bit PGM image.
- Complete-row validation, a 45-second scan deadline, cancellation, and refusal
  to save incomplete scans or overwrite an existing output file.
- Native C11 executable, linking only to the system C runtime. No Python, SANE,
  vendor executable, calibration blob or CUPS filter is needed to scan.

This is an early prototype. Colour, higher resolutions, configurable scan regions,
discovery, calibrated tone reproduction, PDF export, a GUI, macOS Image Capture
integration and Linux SANE integration are not implemented. Only ARM64 macOS has
been physically checked so far. The source uses portable POSIX networking, but
Linux and Intel builds have not yet been verified.

## Build and use

From this project folder, with a C compiler installed:

```sh
./build.sh
./dcp-j315w-scan --info PRINTER_IPV4
./dcp-j315w-scan --scan PRINTER_IPV4 result.pgm
```

Replace `PRINTER_IPV4` with your printer's numeric network address. Put a document
on the glass and close the lid before `--scan`. The output filename must be new.
No administrator authentication or system installation is needed. Use Ctrl-C to
cancel. On macOS, make a PNG for viewing using ImageIO's format conversion:

```sh
sips -s format png result.pgm --out result.png
```

The build script accepts `CC`, `CFLAGS`, `LDFLAGS` and `OUTPUT`, and applies an
ad hoc signature on macOS. This is not yet a packaged or notarized release.

## Observations

This printer accepts the legacy `+OK 200` greeting and scan commands directly
over Wi-Fi. The tested eSCL capabilities URL returns 404, so no standard eSCL
support has been established. The old software's discovery/push-scan configuration
is not required for this successful computer-initiated session. The cause of the
user's historical wireless-scanning failures has not been established.

The scanner advertises a 100 dpi maximum of 826 x 1157 pixels. This prototype
requests a 16-pixel-aligned width of 816 to avoid an invalid edge. It saves the
1145 rows actually returned before the device's end marker, rather than inventing
or padding the advertised maximum height. Exact bed coverage and other settings
need further investigation. See [protocol notes](PROTOCOL.md).

Scans and raw experiments are in `captures/` and `research/`, both ignored by Git.
Do not commit private documents or machine logs. The printing project is untouched.

## Verification

```sh
python3 test_transport.py
```

This uses a local simulated scanner, not a physical printer. It checks fragmented
TCP responses, exact image bytes, incomplete transfer rejection, invalid row-size
rejection, cancellation and preservation of an existing output file. Python is
only a development dependency.

## Licence and provenance

Own source and documentation are MIT licensed. Protocol message names and framing
were researched using the GPL-licensed
[brscan project](https://github.com/dmikushin/brscan), then confirmed against the
actual DCP-J315W's responses. This client is independently written; no code,
decompiled algorithm, decoder or calibration file from that project is included
or linked. That project's code retains its GPL licence. This is not a formal
separated-team clean-room effort.
