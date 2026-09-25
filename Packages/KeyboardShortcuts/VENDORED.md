# KeyboardShortcuts (vendored)

Upstream: https://github.com/sindresorhus/KeyboardShortcuts, version 3.0.1, revision
`49c3fc04ea827f816df67843bfcc57286b47ff06`. MIT licence, see `license`.

Why it is vendored: upstream ships its localized strings as a SwiftPM resource, so SwiftPM
generates `Bundle.module`. That accessor looks for the bundle at the `.app` root (not in
`Contents/Resources`) and otherwise at the absolute `.build` path of the machine that built
the app. A release build therefore crashed the moment the shortcut recorder appeared, on any
Mac where that path did not exist.

Local changes, and nothing else:
- `Package.swift`: `Localization` is excluded from the target, the test target and the DocC
  catalogue are dropped. Without resources, no `Bundle.module` is generated.
- `Utilities.swift`: `String.localized` reads `KeyboardShortcuts.bundle` from
  `Bundle.main.resourceURL`, which `scripts/build.sh` fills from `Localization/`. When the
  bundle is absent (`swift run`, tests) it falls back to the English text.
