# Contributing to Camcord

Thank you for helping. Camcord sees whatever is on someone's screen, so every change is held to two standards: it must
work the way the user expects, and it must never put their captures somewhere they did not choose.

## Before you start

- For anything larger than a small fix, open an issue first so we can agree on the approach.
- Security and privacy problems go through the private process in [SECURITY.md](SECURITY.md), not public issues.

## Setting up

You need macOS 26 or later and Xcode 26.5 or later (Swift 6.2). The project is a Swift package; its only third-party
code is vendored under `Packages/`, so nothing is downloaded during a build.

```sh
git clone https://github.com/tunatavsan/camcord.git
cd camcord
swift build
swift test
scripts/build.sh --ad-hoc   # package a release build into dist/Camcord.app
```

See the README for signing and installing a copy you can use every day.

## Making a change

1. Create a branch from `main`.
2. Keep the change focused. Refactors and behavior changes belong in separate pull requests.
3. Add or update tests. New behavior needs a test that fails without your change. Tests use Swift Testing and must use
   their own `UserDefaults` suite, temporary directories, named pasteboards and synthetic images; never read or change
   the user's settings, Library, clipboard or devices.
4. Run the same check as CI:

   ```sh
   scripts/check.sh
   ```

   It builds with warnings treated as errors and runs every test.
5. Open a pull request and describe what changed, why, and how you tested it. For anything visible, describe what you
   checked in the running app; passing tests do not prove that capture, recording or permission flows work.

## Guidelines

- **Captures stay where the user put them.** Do not add network access, analytics or automatic uploads. A capture goes
  to the clipboard, the Library or a folder the user chose, and nowhere else.
- **Redaction must be real.** Solid redaction replaces pixels in the flattened export. Blur and pixelation are visual
  effects; do not describe them as hiding information.
- **Say what happened.** When a capture or recording is partial, skipped or refused, the interface says so and keeps
  whatever was recorded.
- **User-facing text** uses `String(localized:)` or `LocalizedStringResource` and lives in
  `Resources/Localizable.xcstrings` with English and Turkish translations. A test checks every key the compiler sees
  against the catalog.
- **Design tokens.** Colors, radii, spacing and type come from `Sources/Camcord/App/Design`. Prefer native, accessible
  system controls.
- **Concurrency.** The package uses Swift 6 strict concurrency. Keep capture, encoding and file work off the main actor,
  and respect the queue that each recording component is confined to.
- **Architecture.** Read [ARCHITECTURE.md](ARCHITECTURE.md) before changing the capture or recording pipelines.

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `perf:`, `refactor:`, `test:`,
`docs:`, `build:`, `ci:` or `chore:`, optionally with a scope, followed by a short summary, for example
`fix(scroll): stop at the page end instead of stitching it twice`.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
