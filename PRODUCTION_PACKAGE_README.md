# RELIQ Solutions V2.3.1 Production Package

This is the V2.3.1 production source package. It carries the V2.3.0 production baseline plus the in-workspace party-ledger and WhatsApp reliability hotfixes requested before distribution.

## macOS
Run:

    chmod +x BUILD_MACOS_RELEASE.command
    ./BUILD_MACOS_RELEASE.command

Outputs are written to `dist/`.

## Windows
Run `BUILD_WINDOWS_RELEASE.bat` from a Windows machine with Flutter configured. Outputs are written to `dist/`.

## Important
Do not distribute a build until the production checklist passes. The included macOS DMG builder uses ad-hoc signing and does not notarize with Apple.
