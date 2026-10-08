Reliq V2.3.1 FULL ARCHIVED SOURCE + MIGRATION CENTER PATCH

This ZIP includes the complete archived V2.3.1 source tree as stored in the project library, with the two Migration Center Dart files patched and the analytics startup trigger missing-table guard added in lib/data/app_database.dart.

IMPORTANT: The archived baseline does NOT contain generated Flutter macOS and Windows runner directories. This is not a turnkey cross-platform build or the user's latest locally branded working project.

Safest approach: make a backup of your working local project and copy ONLY these 3 files into it:
  lib/screens/migration_center_screen.dart
  lib/services/migration_center_service.dart
  lib/data/app_database.dart

CAUTION: If you have modified these files locally since V2.3.1, review diffs first rather than overwrite.

macOS file access: tools/enable_macos_file_access.py may be needed; inspect and apply to the working project.

Run dart format on changed Dart files, flutter analyze, and flutter build macos --release. Test on a COPY of a customer database.

This patch is NOT yet verified end-to-end; historical stock adjustments, duplicate allocations, and reconciliation still need tests. Do not import real financial history or deploy to customers until validated.
