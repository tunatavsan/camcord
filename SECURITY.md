# Security Policy

Camcord captures the screen, the camera and the microphone, so bugs that could expose what a user captured are treated
as security issues.

## Reporting a vulnerability

Please do not open a public issue. Report privately through GitHub instead: open the
[Security tab](https://github.com/tunatavsan/camcord/security) of this repository and choose
**Report a vulnerability**.

Examples of what to report:

- A capture, recording or recognized text reaching a place the user did not choose, such as an unexpected file, the
  clipboard or another app.
- Redaction that leaves the original pixels recoverable in an exported image.
- The camera or microphone starting without the user turning it on, or staying on after they turned it off.
- A recording continuing after it was stopped, or capturing a window or display that was not selected.
- Cached screenshots that outlive the retention the user set.

Please include the macOS version, the Camcord commit or version, and steps to reproduce using neutral content. Do not
attach real captures, personal file paths or recognized text. You can expect an initial response within a week. Fixes
are made as soon as they are verified, and reporters are credited unless they prefer otherwise.

## What Camcord does with your data

Camcord makes no network connections, has no account and collects no analytics. Text recognition uses Vision on your
Mac. Content leaves Camcord only through actions you take: copying, saving, dragging, sharing, or a Shortcut you
configure yourself.

Blur and pixelation only hide information visually. Use solid redaction for anything sensitive, and check the exported
image before you share it. The original capture is kept unchanged.

## Supported versions

Camcord is in early development. Security fixes are made on the `main` branch.
