# Reliq V2.3.1 desktop hotfix — 2026-10-08

This hotfix addresses the two defects reported during macOS testing.

## 1. Black window on another Mac

The archived V2.3.1 database migration created analytics triggers before some later-version tables existed. On an upgraded customer database SQLite could fail with `no such table: main.business_action_state` before Flutter reached `runApp`, which presents as a black native window.

Changes:
- `lib/data/app_database.dart` checks that each target table exists before creating analytics triggers.
- The v27 migration calls analytics infrastructure again after `business_action_state` is created, so the trigger is added later.
- `lib/main.dart` now shows a visible startup diagnostic page if any database/startup error remains instead of leaving an unexplained black window.

## 2. Migration Center picker flow

Changes:
- CSV/ZIP pickers open before the page is marked busy.
- The `Reading and validating...` banner begins only after a file has actually been selected.
- Native picker filtering is explicit (`.csv` for individual imports, `.zip` for full migration).
- Full Migration's button is renamed to `Choose Migration ZIP & Validate`, matching what it actually does.
- macOS continues to request picker-owned bytes while security-scoped access is active.

## Apply to the current working Flutter project

Back up these files first, then copy the hotfix replacements:

- `lib/data/app_database.dart`
- `lib/main.dart`
- `lib/screens/migration_center_screen.dart`
- `lib/services/migration_center_service.dart`

Also run `tools/enable_macos_file_access.py` from the project root and rebuild.

Do not delete or replace the customer's database to solve a startup migration problem.
