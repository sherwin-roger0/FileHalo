# FileHalo for Mac

A native Swift/AppKit/SwiftUI recreation of the workflow visible in the supplied Tangerine video. Installed at `/Applications/FileHalo.app`. A second app bundle and all source code are included here.

## Use

Open FileHalo. Drag a file from Finder and hold Shift briefly. Drop onto a segment to convert. Keep holding Shift for about 1.25 seconds to switch to the image tools wheel. Outputs are saved alongside the original with a unique filename. Existing files are never overwritten.

You can also use the FileHalo menu-bar icon → **Choose File…**, then click a segment. Select **Tools** or **Formats** to change wheels. Quit from the menu-bar menu.

## Included

- Compact 248-point circular menus (24% smaller than the original build).
- Native macOS Liquid Glass materials for the wheel and editor windows; follows system light/dark appearance. Neutral gray selection accents.
- Image export: JPG, PNG, WebP, HEIC, TIFF, AVIF, BMP, PDF.
- PDF to JPG/PNG exports every page, with a separate file per page.
- PDF/text documents to TXT and DOCX. On-device Vision OCR provides text extraction for scanned PDFs.
- Crop with draggable corners and precise sliders.
- Background styling with colors, gradients, padding, rounded corners, and shadows.
- Flattened black rectangle redaction, freehand gray annotation, and undo.
- JPEG quality compression.
- Image adjustments: brightness, contrast, saturation, quarter-turn rotation.
- File and image metadata viewer.
- Audio/video conversions using this Mac’s FFmpeg installation.
- Local processing, no network services, and original files preserved.

## Scope and current limits

This is an independent recreation from a 21-second video, not Tangerine’s original source or a verified copy of its complete feature set. The wheel follows the video layout with a native macOS glass treatment, rather than matching the video pixel for pixel. PDF/DOCX text conversion does not reconstruct original page layout. Annotations support freehand strokes; redactions support rectangles. Compression exports JPEG and flattens transparency. Editors operate on the first page of PDFs; conversion exports all pages. Dragging currently handles the first file in a selection. The portable release bundles FFmpeg and WebP tools, so recipients do not need Homebrew.

The free direct-download release is ad-hoc signed and not Apple-notarized. macOS may require Control-click → Open on first launch. FileHalo registers itself as a login item on first launch; approve it under System Settings → General → Login Items if prompted. The download site includes the first-launch steps. The bundled FFmpeg is GPL-enabled; see `THIRD_PARTY_NOTICES.md` and the license/source files in the app bundle.

## Verification

Built with the installed Xcode Swift compiler for Apple silicon, macOS 14+. Automated checks cover eight image output formats, multipage PDF output, DOCX text round-trip, six editor rendering paths, crop pixel dimensions, and radial hit testing. The installed background editor was visually checked and its Save Copy action produced a real output file. The global Shift-drag interaction is implemented but has not been verified end-to-end through UI automation.

## Rebuild

Run `./build.sh` to rebuild the app using Xcode command-line tools. Run `./package-portable.sh` to bundle the local Homebrew FFmpeg/WebP builds and their dylib dependencies. That creates an Apple silicon release; it does not create a notarized build.

The executable accepts `--self-test /absolute/scratch/directory` to generate fixtures, or `--preview /absolute/image/path 'Add BG'` to open an editor.
