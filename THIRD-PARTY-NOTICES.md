# Third-party notices

Camcord uses system frameworks that ship with macOS and includes the following third-party components.

## KeyboardShortcuts

Camcord vendors [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) 3.0.1 by Sindre Sorhus,
upstream revision `49c3fc04ea827f816df67843bfcc57286b47ff06`, under the MIT License.

- [Complete original license](Packages/KeyboardShortcuts/license)
- [Why it is vendored, and the local changes](Packages/KeyboardShortcuts/VENDORED.md)

The original license and copyright notice are preserved in the vendored package. Its localization resources are copied
into the app bundle by `scripts/build.sh`.

## DM Sans

DM Sans by The DM Sans Project Authors is bundled unmodified from
[Google Fonts](https://github.com/google/fonts/tree/main/ofl/dmsans) under the
[SIL Open Font License 1.1](Resources/Fonts/OFL.txt).

## Artwork

The app icon (`Resources/Camcord.icon`) and the menu bar icon are original artwork made for Camcord. Interface symbols
are SF Symbols provided by macOS.
