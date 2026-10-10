# Native macOS scanner integration

## Verified path

```text
Image Capture
      |
Apple's built-in AirScan scanner module
      |
Local-only eSCL bridge (this project)
      |
Independent C scanner core
      |
DCP-J315W over Wi-Fi
```

On the development Apple Silicon Mac running macOS 27, Image Capture recognised
**DCP-J315W Open Scanner**, displayed a colour overview, and saved a PDF with a
300 dpi colour page and a 100 dpi grayscale page. Both pages came from a stationary
30 x 30 cm canvas, cropped physically by the smaller scanner bed. The PDF had two
pages, each 586.8 x 823.68 points: embedded images were 2445 x 3432 RGB pixels and
815 x 1144 grayscale pixels. Both rendered correctly. This is a scanning-system
integration check, not an automatic document-feeder test.

Preview also lists **Import from DCP-J315W Open Scanner...** in its File menu
with the installed helper running. A separate physical acquisition through Preview
has not been performed; Image Capture is the physically verified scanning app.

## Build, install, remove

From the project root:

```sh
./build-macos-airscan.sh
./install-macos-airscan.sh --address PRINTER_IPV4
./uninstall-macos-airscan.sh
```

Do not use sudo. The installed app and private log live in this user's
`Library/Application Support/DCPJ315WScan`. The LaunchAgent label is
`org.dcpj315w.scan.airscan`. No image files are written by the bridge itself;
Image Capture or another native client decides where documents are saved.

For foreground development, stop the installed helper first so there are not two
providers for the same scanner:

```sh
launchctl bootout "gui/$(id -u)/org.dcpj315w.scan.airscan"
./build/DCPJ315WAirScanBridge.app/Contents/MacOS/DCPJ315WAirScanBridge --address PRINTER_IPV4
```

Rerun the installer to restore login startup. `--no-discovery` is available for
loopback-only integration testing. Test dependencies are Python and Pillow; they
are not needed for normal scanning.

## Bounds and open work

- Native controls expose 100 and 300 dpi, RGB, grayscale and thresholded text.
  The lower-level client also accepts 150 dpi; that setting is not advertised
  by the native bridge yet.
- The printer address is configured manually. Discovery makes the local helper
  visible to native apps; it does not automatically locate a changed printer IP.
- Native JPEG transport uses maximum ImageIO quality. Lossless PNG is also offered,
  but the tested Apple client chooses JPEG. Image Capture can export PNG/TIFF/PDF;
  this does not make the underlying JPEG transport lossless.
- At 100 dpi, the core's maximum aligned width is 816 pixels. Regions extending
  beyond that window return only available pixels; none are fabricated. Higher
  resolution and exact edge coverage remain constrained by the observed device
  geometry described in PROTOCOL.md.
- Native PDF assembly is tested. OCR, rotation, multiple detected items, very long
  sessions, login after a full reboot, and physical cancellation through the GUI
  have not all been checked. Core cancellation and bridge cancellation simulations
  pass; physical core cancellation has a documented device recovery delay.
- ScannerStatus currently reports bridge/job state, not a continuously probed
  printer health state. Offline acquisition fails within bounded deadlines and
  never produces a partial image.
- This remains a development prototype with local ad hoc signing. A signed,
  notarized public scanner installer has not yet been produced. Only one printer
  model and one physical Mac have been tested.

## Protocol references

The eSCL field names were checked against primary implementations
[sane-airscan](https://github.com/alexpevzner/sane-airscan) and
[AirSane](https://github.com/SimulPiscator/AirSane), and against actual requests from
Apple's native AirScan client. Their GPL source was not copied or linked; this
provider is independently implemented. Apple's
[VirtualScanner sample archive](https://developer.apple.com/library/archive/samplecode/VirtualScanner/VirtualScanner.zip)
was used to research the separate legacy ICA attempt, not included in this
working provider. Own code and resources remain MIT licensed.
