# Reliq V2.3.1 — Migration Center source patch (archived baseline)

This is a **source-code patch**, not a compiled DMG or Windows installer. It was prepared against the archived `RELIQ_Solutions_V2.3.1_PRODUCTION_FULL_SOURCE.zip` found in the user's project files. The archive contains `lib/` but **not** the generated macOS and Windows runner projects. The patch does not touch `app_database.dart` or undo the separate analytics startup fix.

## Confirmed defects in the archived code

- A canceled CSV/ZIP picker leaves the previous "Reading and validating..." status on screen.
- The generated CSV templates include **fictional example business transactions**. Importing untouched templates can create fake records; the customers sample also does not match its full header set.
- A per-row database error is swallowed, and the rest of a financial migration can be committed with skipped records. This patch fails the transaction so it rolls back instead.
- File picker reads selected files by reopening their paths, which can fail under a macOS sandbox. The patch requests picker-owned bytes on macOS and prefers them over paths.
- An empty or unrecognized full-migration ZIP gives poor feedback; header-only templates need to be ignored during ZIP import.

## Apply to the **working** Mac project

Do not replace the entire project, app bundle, or database. Keep your working custom icon and platform runner files.

1. Extract this patch ZIP to `~/Desktop/RELIQ_MIGRATION_PATCH`.
2. In Terminal:

```bash
cd ~/Desktop/RELIQ_V2.3.1_MAC_BUILD
mkdir -p ~/Desktop/RELIQ_MIGRATION_BACKUP
cp lib/screens/migration_center_screen.dart ~/Desktop/RELIQ_MIGRATION_BACKUP/
cp lib/services/migration_center_service.dart ~/Desktop/RELIQ_MIGRATION_BACKUP/

git apply --check ~/Desktop/RELIQ_MIGRATION_PATCH/RELIQ_V2.3.1_Migration_Center.patch
git apply ~/Desktop/RELIQ_MIGRATION_PATCH/RELIQ_V2.3.1_Migration_Center.patch

python3 ~/Desktop/RELIQ_MIGRATION_PATCH/tools/enable_macos_file_access.py

dart format lib/screens/migration_center_screen.dart lib/services/migration_center_service.dart
flutter analyze
flutter build macos --release
```

**Stop if `git apply --check` fails.** Your local Migration Center may differ from the archived source. Do not overwrite local files with the included replacement Dart files unless their differences have been reviewed. The updated Dart files are included for reference.

## Functional acceptance tests (use a copy of the database)

1. Open each of the 17 template dialogs and save a template. Check that it has column headings only.
2. Open Import CSV and cancel. The status banner should disappear.
3. Import a valid product CSV; confirm the preview, counts and product record.
4. Import a CSV with an invalid row; confirm that **none** of its rows are committed.
5. Upload a ZIP with only header-only templates; it should show a clear error, not "success".
6. Upload a ZIP with valid products/customers/suppliers and a sales invoice with items. Verify references, row counts and reconciliation.
7. Reimport the same test ZIP and check for duplicate transactions.
8. Verify receipt/payment allocations and returns separately; do not import real customer financial history until these checks pass.

## Important limitation

This is not yet an end-to-end verified migration release. The archived code still requires separate QA for historical stock adjustments (they currently change live stock), duplicate allocation handling, and accounting reconciliation. In particular, **do not include `stock_adjustments.csv` in a Full Migration ZIP until the historical-versus-current-stock behavior is corrected**. The macOS entitlement change is also a probable platform fix, not proof that the native picker works on every Mac; test the rebuilt app.

Do not reset or delete customer databases. Do not push this to production before testing with a database backup.
