# Changelog

## 0.2.0
- Introduced the 0.2.x capture-suite overhaul.

## 0.2.1
- Restored system capture sounds and visible selection chrome; gated recording audio during start and resume cues.

## 0.2.2
- Added scrolling recovery feedback and serialized capture handoffs.

## 0.2.3
- Fixed the camera timer executor crash and kept recording controls accessible in a detached panel.

## 0.2.4
- Reworked manual scrolling around copied stream frames and removed automatic scrolling; superseded by Freeze 1.

## 0.2.5
- Added native microphone-level control and responsive audio meters.

## 0.2.6
- Added a floating camera preview with drag, resize and live recording placement.

## 0.2.7
- Fixed camera output format handling and standardized the rectangular camera presentation.

## 0.2.8
- Optimized scrolling alignment and added spring camera placement and updated screenshot previews.

## 0.2.9
- Improved camera corner resizing, hover handles and magnetic docking.

## 0.2.10
- Adjusted short-overlap scrolling, repeated-content matching and final whitespace capture; superseded by Freeze 1.

## Freeze 0
- Preserved the complete 0.2.10 capture suite and added version tags before restoring scrolling capture.

## Freeze 1
- Restored snapshot-driven manual and automatic scrolling, kept sRGB output, and replaced export blocking with a brief gap hint; removed the stream queue and WebKit harness.

## Freeze 2
- Release the panel when recording starts, stop idle microphone capture, and close the camera overlay and its preview source when its owning UI or recording ends.

## Freeze 3
- Limit frozen capture to the cursor display, capture clicked windows independently, show hold selection promptly, bound retries, and preserve OCR identifiers and block indentation.

## Freeze 4
- Deliver salvaged recordings at the last accepted media end, append camera video on screen callbacks with an idle fallback, lower default system audio gain, and allow microphone recovery after resume.

## Freeze 5
- Removed app QA commands and compositor instrumentation, staged and verified installation, pruned release bundles, and retained the three core documents under the minimum-freeze scope.
