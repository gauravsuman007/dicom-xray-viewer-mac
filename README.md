# DICOM X-ray Viewer for macOS

A tiny, native macOS app to **view DICOM X-ray images and convert them to PNG with a dark background**. It is the kind of thing you need when a hospital hands you a CD or download full of `.dcm` files (or extensionless DICOM files plus a Windows-only viewer) and you just want to look at the pictures on your Mac.

- **Small and fast:** a ~200 KB installer, no dependencies, no background services, no network access.
- **Runs on every Mac:** universal binary for Apple silicon (arm64) and Intel (x86_64), macOS 11 or newer.
- **Dark by default:** black background, bones bright. Inverted `MONOCHROME1` X-rays are fixed automatically.
- **Convert:** export one image or a whole folder to PNG, from the app or the command line.

> **Not a medical device.** This is a convenience viewer for personal use. It is not validated for diagnosis or clinical decisions. Always rely on the original images and your doctor's report.

## Install

Download the latest installer from the [Releases page](../../releases/latest):

| File | How to install |
| --- | --- |
| `XrayViewer-x.y.z.pkg` | Double-click and follow the installer. The app lands in `/Applications`. |
| `XrayViewer-x.y.z.dmg` | Open it and drag **X-ray Viewer** onto **Applications**. |

### First launch: macOS security prompt

The app is not signed with a paid Apple Developer ID, so macOS Gatekeeper will warn you the first time. This is expected.

- **For the `.pkg`:** right-click the file, choose **Open**, then confirm. Alternatively open **System Settings → Privacy & Security** and click **Open Anyway** after the first blocked attempt.
- **For the app:** right-click **X-ray Viewer** in Applications, choose **Open**, and confirm once.

You can verify the download against the checksums in the release notes, or build it yourself (see below).

## Using it

Open a DICOM file or a whole folder (a CD's `DICOM` or `IMAGES` folder works, subfolders are scanned) with **File → Open** (⌘O), by dragging onto the window or the Dock icon, or via **Open With** in Finder.

| Action | How |
| --- | --- |
| Next / previous image | → / ← |
| Brightness & contrast (window/level) | Drag with the mouse |
| Reset to the file's own setting | Double-click, or `R` |
| Auto contrast | `A` |
| Invert | `I` |
| Zoom | Pinch, or mouse wheel (⌘+ / ⌘−) |
| Pan | Two-finger scroll, or right-drag |
| Fit to window / actual size | ⌘0 / ⌘1 |
| Show patient name, modality, date | ⌘I (hidden by default) |
| Export current image as PNG | ⌘E |
| Export all images as PNG | ⇧⌘E |

### Convert from the command line

```bash
"/Applications/X-ray Viewer.app/Contents/MacOS/XrayViewer" --convert /path/to/dicom/folder /path/to/output
```

Writes one PNG per DICOM file. Add `--invert` to flip the contrast.

## Supported DICOM formats

| Format | Status |
| --- | --- |
| Uncompressed (implicit and explicit VR little endian), 8/16-bit grayscale, RGB | Supported |
| RLE Lossless | Supported |
| JPEG Lossless (process 14, the common PACS default) | Supported (built-in decoder) |
| JPEG Baseline / Extended, JPEG 2000 | Supported through macOS ImageIO (see note) |
| JPEG-LS, big-endian, deflated | Not supported, shows a clear error |

Notes and limitations:

- Only the first frame of multi-frame files is shown.
- Exported PNGs are 8-bit and contain what you see on screen (the current window/level). They do not keep the DICOM metadata or the full bit depth, so **keep your original files**.
- For JPEG and JPEG 2000 the window/level is computed automatically, because the original scaling is not available after decoding. The JPEG 2000 and baseline JPEG paths have not been tested against real-world files yet. Bug reports with the error text are welcome (please do not attach patient data).
- Files that are not valid DICOM, and `DICOMDIR` index files, are skipped when opening a folder.

## Build from source

You only need the Xcode command line tools (`xcode-select --install`).

```bash
git clone https://github.com/gauravsuman007/dicom-xray-viewer-mac.git
cd dicom-xray-viewer-mac
./build.sh
```

This produces `build/X-ray Viewer.app`, `build/XrayViewer-<version>.pkg` and `build/XrayViewer-<version>.dmg`. Set `VERSION=1.2.3 ./build.sh` to change the version number.

The whole app is one Swift file, [`Sources/main.swift`](Sources/main.swift), using only AppKit and ImageIO: a DICOM parser, a lossless JPEG decoder, a windowing/rendering step, and a small window.

### Test files

No real patient data is in this repository. [`tools/make_test_dicom.py`](tools/make_test_dicom.py) generates synthetic DICOM files (uncompressed, RLE, lossless JPEG, inverted `MONOCHROME1`) with plain Python 3, no packages needed:

```bash
python3 tools/make_test_dicom.py samples
"build/X-ray Viewer.app/Contents/MacOS/XrayViewer" --convert samples out
```

## Privacy

The app works entirely offline on local files. It never uploads anything, and patient details are not shown unless you turn them on.

## License

[MIT](LICENSE)
