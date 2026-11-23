# DICOM X-ray Viewer for macOS

A tiny, native macOS app to **view DICOM X-ray images and convert them to PNG with a dark background**. It is the kind of thing you need when a hospital hands you a CD or download full of `.dcm` files (or extensionless DICOM files plus a Windows-only viewer) and you just want to look at the pictures on your Mac.

- **Small and fast:** a ~200 KB installer, no dependencies, no background services, no network access.
- **Runs on every Mac:** universal binary for Apple silicon (arm64) and Intel (x86_64), macOS 11 or newer.
- **Dark by default:** black background, bones bright. Inverted `MONOCHROME1` X-rays are fixed automatically.
- **History by patient:** every scan you open is remembered and listed in a sidebar, grouped by patient name and sorted by date (newest or oldest first).
- **Compare scans:** select several scans to put them side by side on one canvas. Drag each scan to set how far apart they sit, and zoom them all together.
- **Convert:** export one image, a patient's scans, or the compare view to PNG, from the app or the command line.

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

Open a DICOM file or a whole folder (a CD's `DICOM` or `IMAGES` folder works, subfolders are scanned) with **File → Open** (⌘O), the **+** button in the sidebar, by dragging onto the window or the Dock icon, or via **Open With** in Finder. Everything readable is added to the library in the sidebar.

### Library and history

- Scans are **grouped by patient name** (A to Z). Inside each patient they are **sorted by scan date**; switch between **Newest first** and **Oldest first** with the menu at the top of the sidebar (or **View → Sort**). Scans without a date go last.
- The date comes from the DICOM acquisition date, falling back to the content or study date.
- Click a scan to view it. **⌘-click or ⇧-click** to select several and compare them. Right-click a patient to **Compare All Scans**, or to remove them from the history.
- Select scans and press **Delete** (or right-click → **Remove from History**) to forget them. This never deletes your DICOM files. **File → Clear History…** wipes the whole list.
- The history is a small JSON file in `~/Library/Application Support/X-ray Viewer/library.json`. It stores file paths, patient names, dates and image sizes, and stays on your Mac. Files that were moved or deleted show as *(missing)*.

### Comparing scans

Select two or more scans and they appear side by side on one canvas, ordered by date.

- **Move a scan:** drag it. Place scans as close, far apart, or even overlapping as you like. Click a scan to bring it to the front.
- **Spacing:** the **Spacing** slider re-spaces all scans evenly; **Arrange** (⌘L) lines them up again.
- **Zoom everything together:** pinch, scroll the mouse wheel, ⌘-scroll on a trackpad, use the **− / +** buttons or the zoom slider, **Fit** or **1:1**. One zoom applies to every scan, so you can inspect the same region across scans.
- **Pan:** drag on the empty background, or two-finger scroll.
- **Contrast per scan:** ⇧-drag on a scan (double-click resets it).
- **Blend:** turns overlapping areas into a see-through screen blend, so you can lay one scan over another.
- Up to 12 scans are shown at once.

| Action | How |
| --- | --- |
| Next / previous scan | → / ← |
| Brightness & contrast (single scan) | Drag with the mouse |
| Reset contrast | Double-click, or `R` |
| Auto contrast | `A` |
| Invert | `I` |
| Zoom | Pinch, mouse wheel, ⌘+ / ⌘− |
| Pan | Two-finger scroll, right-drag, or ⌥-drag |
| Fit to window / actual size | ⌘0 / ⌘1 |
| Show / hide the library | ⌃⌘S |
| Arrange scans side by side / blend overlaps | ⌘L / `B` |
| Show patient name, modality, date | ⌘I (hidden by default) |
| Export current view as PNG (the compare view too) | ⌘E |
| Export all of a patient's scans as PNG | ⇧⌘E |

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

The app is a handful of Swift files in [`Sources/`](Sources) using only AppKit and ImageIO: `DICOM.swift` (parser, lossless JPEG decoder, windowing and rendering), `Library.swift` (history and grouping), `Sidebar.swift` (patient list), `Canvas.swift` (single and compare view with shared zoom) and `main.swift` (window and menus).

### Test files

No real patient data is in this repository. [`tools/make_test_dicom.py`](tools/make_test_dicom.py) generates synthetic DICOM files (uncompressed, RLE, lossless JPEG, inverted `MONOCHROME1`) with plain Python 3, no packages needed:

```bash
python3 tools/make_test_dicom.py samples
"build/X-ray Viewer.app/Contents/MacOS/XrayViewer" --convert samples out
```

## Privacy

The app works entirely offline on local files and never uploads anything. Patient names are shown in the sidebar library (they are how scans are grouped), and the history file described above is stored only on your Mac. Use **File → Clear History…** to remove it. The patient name overlay on the image itself is off by default.

## License

[MIT](LICENSE)
