RELIQ Solutions V2.0.2 - Customer Release Source
===============================================
Brand: RELIQ Solutions
Tagline: Reliable Intelligent Solutions
Copyright: Copyright © 2026 RELIQ Solutions. All rights reserved.
Built-in application owner account: unchanged (username: owner; first launch asks to create its password/PIN).

CLEAN DATABASE
--------------
This release does not contain a customer database or sample transaction data.
It uses a new production data location named "RELIQ Solutions" and creates reliq_solutions.db on first launch.
A new installation therefore starts with an empty business database plus only the minimum system records needed to operate: Owner, Main Branch, local terminal, default category/unit master values, and system metadata.

MAC BUILD
---------
On a Mac with Flutter and Xcode installed:
  ./BUILD_MACOS_RELEASE.command
Outputs:
  dist/RELIQ Solutions.app
  dist/RELIQ_Solutions_macOS.dmg
The DMG is ad-hoc signed, not Apple-notarized.

WINDOWS BUILD
-------------
On Windows with Flutter and Visual Studio Desktop development with C++ installed:
  BUILD_WINDOWS_RELEASE.bat
Outputs:
  dist\RELIQ_Solutions_Windows\RELIQ_Solutions.exe
  dist\RELIQ_Solutions_Windows.zip
Distribute the full folder/ZIP. The EXE depends on the adjacent Flutter DLL/data files.

BRANDING
--------
The supplied RELIQ logo is embedded as the application brand logo and release icon source.
A customer's invoice/business logo remains separately configurable from Settings.


V1.1 WORKING UPDATE - KEYBOARD & HELP
- Global command palette: Ctrl/Cmd + K
- Universal product lookup: Ctrl/Cmd + F
- Alt+1..9 navigation helpers for key operational pages
- Help menu with Help Center and Keyboard Shortcuts
- Settings > Sales & POS > Show keyboard shortcut helpers
- Detailed Help Center guides for sales, purchases, products, payments, stock, returns, reports and backups
- Screen-specific F-key actions will be connected incrementally in the following refinement steps.

V1.9 UPDATE ENGINE
------------------
RELIQ now supports in-place application updates while preserving the customer database.
Open Settings -> System & Updates for online checks or offline .reliq packages.
See UPDATE_ENGINE_V1.9_GUIDE.txt for package creation, rollback and offline instructions.


V1.9.1 UI POLISH
------------------
Settings content alignment and the main application sidebar were reorganized for a cleaner desktop workflow. Database schema remains v22. See UI_POLISH_V1.9.1_GUIDE.txt.


V1.9.2 BRAND + MIGRATION FILE ACCESS
===================================
- New RELIQ icon/logo and brand palette (#1C2D30 / #E1FF05).
- Refreshed login and Morning Brief branding while keeping the workspace clean.
- Desktop window opens maximized on macOS/Windows/Linux.
- Migration Center CSV/ZIP pickers use a more robust desktop file path flow.
- Product bulk-import picker/template flow updated.
- macOS builds add user-selected read/write entitlement for native open/save dialogs.
- Template saves fall back to Downloads if a native save panel cannot be opened.
- Database schema remains v22; no business-data migration is required.


V2.0 MIGRATION + PROFITABILITY
- Migration aliases are entity-specific so generic date/name/supplier columns no longer map to the wrong entity fields.
- Migration preview validates required row values, dates, numeric values, duplicates and cross-file references before import.
- Historical payment/receipt dates accept ISO, DD/MM/YYYY, DD-MM-YYYY, timestamps and Excel serial dates.
- Sales History shows invoice gross profit and gross margin to users with view_profit permission, plus a filtered-range profitability summary.
- Reports includes a permission-controlled Profit & Loss statement with revenue, returns, COGS, expense categories, gross profit and net profit/loss.

RELIQ V2.0.2+201
- Tagline: Reliable Intelligent Solutions
- Persistent cached analytics with background refresh for large databases
- Migration CSV reliability pass (strict individual schemas, robust ZIP detection, UTF-16/BOM/delimiter support)
- Borderless RELIQ branding assets
- Sales History profit/margin and Profit & Loss reporting retained from V1.9.3
- Database schema target 23


V2.0.2 WORKFLOW UPDATE
----------------------
- Sales POS customer selector: type name, phone or email.
- Purchases / Purchase Orders supplier selector: type name, phone or email.
- Sales and Purchase History open on Today with Yesterday, This month and Custom range shortcuts.
- History text search also matches party phone/email.
- Database schema remains 23.
