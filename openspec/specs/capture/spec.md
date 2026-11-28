# Capture Specification

## Purpose

Screenshots and screen recordings: shortcuts, capture options, storage and
gallery, on-device OCR, the annotator, pins, and permission failures.

## Requirements

### Requirement: Capture shortcuts

`⌘⇧3`, `⌘⇧4` and `⌘⇧6` SHALL capture the full screen, a region and a window
from anywhere, replacing the macOS shortcuts while Palette runs. `⌘⇧5` SHALL
start or stop a recording. All four SHALL be editable or clearable in Settings →
Shortcuts. A cleared shortcut SHALL return that key to macOS.

#### Scenario: Global screenshot

- **WHEN** Palette runs and the user presses `⌘⇧4` in another app
- **THEN** a region capture starts without showing the launcher

#### Scenario: Cleared shortcut

- **WHEN** the screenshot shortcut is cleared
- **THEN** Palette registers nothing for it and macOS handles the key

### Requirement: Capture options

`[capture]` SHALL control `directory` (default `~/Pictures/Palette`),
`screenshot_format` (`png`/`jpg`), `recording_format` (`mov`/`mp4`), `delay`,
`hide_palette`, `capture_cursor`, `show_clicks`, `sound` and `thumbnail`.
`hide_palette = true` SHALL keep the panel out of the capture.

#### Scenario: JPG format

- **WHEN** `screenshot_format = "jpg"`
- **THEN** the system capture engine is asked for JPEG and the file ends `.jpg`

#### Scenario: Delay

- **WHEN** `delay = 3`
- **THEN** the capture waits three seconds before taking the picture

### Requirement: Capture action

`screenshot_action` and `recording_action` SHALL accept `save`, `copy`,
`save-copy` or `preview`. A copy-only action SHALL put the file on the
pasteboard without saving it in the capture directory.

#### Scenario: Save and copy

- **WHEN** the action is `save-copy`
- **THEN** the file lands in the capture directory and is also on the pasteboard

### Requirement: Storage and naming

Captures SHALL be written into the configured directory with millisecond
resolution and a free-name check, as `shot-*` or `rec-*` plus the format
extension. An existing capture SHALL never be overwritten by a new one in the
same second. Palette SHALL NOT prune the directory; only the user removes
captures.

#### Scenario: Two captures in one second

- **WHEN** two screenshots are taken within the same second
- **THEN** both files exist with distinct names

#### Scenario: Missing directory

- **WHEN** the capture directory does not exist
- **THEN** it is created, and a creation failure is reported before capturing

### Requirement: Gallery

`/shots` SHALL list the capture directory newest first, grouped by day, with a
thumbnail for images and a poster frame for videos. `[capture] gallery` SHALL
accept `all` or `palette`; `palette` SHALL list only Palette's own `shot-*` and
`rec-*` files. Thumbnails SHALL be cached by path and modification date.

#### Scenario: Palette-only gallery

- **WHEN** `gallery = "palette"` and the folder holds other images
- **THEN** `/shots` lists only Palette's captures

#### Scenario: Empty gallery

- **WHEN** the directory has no captures
- **THEN** a row says so and names the capture keys and folder

#### Scenario: No matches

- **WHEN** the query matches no capture
- **THEN** the card reports the query and the number of captures in the folder

### Requirement: Recording options

Every recording start SHALL first show a compact options panel for audio,
microphone, display and area, remember the last choice, and keep the options
panel out of the recording. `recording_target` SHALL accept `screen`, `display`
or `region`, with `recording_display` and `recording_region` selecting the
target.

#### Scenario: Recording a display

- **WHEN** the user starts a recording and picks display 2
- **THEN** only display 2 is recorded

#### Scenario: Microphone choice

- **WHEN** audio is on and the user picks an input
- **THEN** that microphone is used and remembered next time

### Requirement: Recording completion

When a recording stops, the file SHALL be finalised, converted to mp4 when that
format is configured, and offered the configured action. With
`preview_recording = true` a player window SHALL open with play, scrub, reveal
and copy path. A cancelled recording SHALL leave no file.

#### Scenario: Stopping a recording

- **WHEN** the user stops a recording with preview on
- **THEN** a player opens on the finished file

#### Scenario: MP4 conversion fails

- **WHEN** `recording_format = "mp4"` and conversion fails
- **THEN** the original recording is kept and reported

### Requirement: Capture feedback

A capture SHALL report the same way everywhere: in the panel when it is open,
otherwise a Notification Center banner plus a brief menu-bar flash. A
screenshot SHALL play the shutter sound and show a brief thumbnail when those
toggles are on. The status menu SHALL show a live **Stop recording · m:ss**
item while a recording runs.

#### Scenario: Capture with the panel hidden

- **WHEN** a screenshot completes while the panel is closed
- **THEN** a banner and menu-bar flash report it

### Requirement: Capture failure and permission

A capture that cannot run SHALL report the reason and preserve the panel. A
failed recording SHALL name Screen Recording permission and the Settings path
when the system capture engine exits non-zero for lack of TCC. Screen
Recording SHALL be requested once per build, not once per capture.

#### Scenario: Permission missing

- **WHEN** Screen Recording is not granted
- **THEN** the failure message names System Settings → Privacy & Security and the capture is not marked successful

#### Scenario: Empty capture

- **WHEN** a full-screen capture produces no file
- **THEN** the capture is reported as failed rather than saved empty

### Requirement: OCR and codes

Clipboard images, the last screenshot, pins and the annotator SHALL offer Copy
Text through on-device Vision OCR, and Open Detected Link for QR, EAN and
Code128 codes. `/ocr` SHALL list the text found in a clipboard image or a given
path. No image SHALL leave the Mac.

#### Scenario: QR code

- **WHEN** the user chooses Copy Text on a screenshot containing a QR code
- **THEN** the decoded link is offered and no network request is made

### Requirement: Annotator

The annotator SHALL offer pointer, arrow, rectangle, text and crop, six colours,
`⌘Z` undo, `⌘C` copy, `⌘S` save over the original and `⌘⇧S` save as a copy.
Marks SHALL be stored as fractions of the image so they survive resizing, and
cropping SHALL remap marks instead of dropping them.

#### Scenario: Crop after drawing

- **WHEN** the user draws an arrow and then crops the image
- **THEN** the arrow keeps its position relative to the cropped content

#### Scenario: Undo

- **WHEN** the user presses `⌘Z`
- **THEN** the last mark or move is undone

### Requirement: Pins

A pinned screenshot SHALL float above other apps and pass clicks through. Up to
8 pins SHALL exist at once, cascading down and right from the previous one; the
oldest SHALL close when a ninth is pinned. Holding `⌥` SHALL show the grip for
drag, resize and zoom.

#### Scenario: Ninth pin

- **WHEN** eight pins are open and the user pins another
- **THEN** the oldest pin closes and the new one appears in the cascade

#### Scenario: Click through

- **WHEN** the user clicks a pin without holding `⌥`
- **THEN** the click reaches the app underneath
