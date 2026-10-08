import 'dart:io';

import 'package:file_picker/file_picker.dart';

class DocumentShareService {
  DocumentShareService._();

  static Future<ProcessResult> _openUri(Uri uri) async {
    if (Platform.isMacOS) return Process.run('/usr/bin/open', [uri.toString()]);
    if (Platform.isWindows) {
      return Process.run(
        'cmd',
        ['/c', 'start', '', uri.toString()],
        runInShell: true,
      );
    }
    if (Platform.isLinux) return Process.run('xdg-open', [uri.toString()]);
    throw Exception(
        'Document sharing is currently available on RELIQ desktop.');
  }

  static Future<void> revealFile(File file) async {
    if (!await file.exists()) {
      throw Exception('The PDF attachment could not be created.');
    }
    ProcessResult result;
    if (Platform.isMacOS) {
      result = await Process.run('/usr/bin/open', ['-R', file.path]);
    } else if (Platform.isWindows) {
      result = await Process.run('explorer.exe', ['/select,${file.path}']);
    } else if (Platform.isLinux) {
      result = await Process.run('xdg-open', [file.parent.path]);
    } else {
      throw Exception(
          'PDF file reveal is currently available on RELIQ desktop.');
    }
    if (result.exitCode != 0) {
      throw Exception('RELIQ could not reveal the generated PDF.');
    }
  }

  /// Copies the *file object* to the OS clipboard, rather than copying the
  /// file path as text. This lets compatible desktop apps accept the PDF with
  /// Paste (Cmd+V on macOS / Ctrl+V on Windows).
  ///
  /// Returns false when the current desktop/platform cannot expose a file on
  /// the clipboard. Callers should then reveal the file as a safe fallback.
  static Future<bool> copyFileToClipboard(File file) async {
    if (!await file.exists()) {
      throw Exception('The PDF attachment could not be created.');
    }
    final path = file.absolute.path;

    if (Platform.isMacOS) {
      const script = r'''
on run argv
  set theFile to POSIX file (item 1 of argv)
  set the clipboard to theFile
  return "ok"
end run
''';
      try {
        final result = await Process.run(
          '/usr/bin/osascript',
          ['-e', script, path],
        );
        return result.exitCode == 0;
      } catch (_) {
        return false;
      }
    }

    if (Platform.isWindows) {
      const script = r'''
Add-Type -AssemblyName System.Windows.Forms
$files = New-Object System.Collections.Specialized.StringCollection
[void]$files.Add($args[0])
[System.Windows.Forms.Clipboard]::SetFileDropList($files)
''';
      try {
        final result = await Process.run(
          'powershell.exe',
          ['-NoProfile', '-STA', '-Command', script, path],
        );
        return result.exitCode == 0;
      } catch (_) {
        return false;
      }
    }

    return false;
  }

  static Future<String?> savePdfAs(
    File source, {
    required String suggestedFileName,
  }) async {
    if (!await source.exists())
      throw Exception('The PDF could not be created.');
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Save PDF',
      fileName: suggestedFileName.endsWith('.pdf')
          ? suggestedFileName
          : '$suggestedFileName.pdf',
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
    if (path == null || path.trim().isEmpty) return null;
    final outputPath = path.toLowerCase().endsWith('.pdf') ? path : '$path.pdf';
    final target = File(outputPath);
    if (await target.exists()) await target.delete();
    await source.copy(target.path);
    return target.path;
  }

  /// Opens the user's default email composer and reveals the generated PDF.
  /// Standard mailto links cannot silently attach a local file, so the user
  /// drags the highlighted PDF into the draft before sending.
  static Future<void> openEmailDraftWithAttachment({
    required String recipient,
    required String subject,
    required String body,
    required File attachment,
  }) async {
    final email = recipient.trim();
    if (email.isEmpty) {
      throw Exception('No email address is saved for this contact.');
    }
    final uri = Uri(
      scheme: 'mailto',
      path: email,
      queryParameters: {'subject': subject, 'body': body},
    );
    final result = await _openUri(uri);
    if (result.exitCode != 0) {
      throw Exception('Could not open the default email application.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 350));
    await revealFile(attachment);
  }
}
