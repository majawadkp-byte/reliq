import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:window_manager/window_manager.dart';

import 'config/brand.dart';
import 'data/app_database.dart';
import 'screens/app_shell.dart';
import 'screens/login_screen.dart';
import 'services/auth_service.dart';
import 'services/sync_service.dart';
import 'services/update_manager.dart';
import 'ui/v3_style.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final desktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  if (desktop) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await windowManager.ensureInitialized();
  }
  try {
    await AppDatabase.instance.open();
  } catch (e) {
    final rollbackLaunched = await UpdateManager.instance.launchRollbackAfterFailedUpdate(e.toString());
    if (rollbackLaunched) {
      await Future<void>.delayed(const Duration(milliseconds: 350));
      exit(0);
    }
    rethrow;
  }
  try { await UpdateManager.instance.markStartupComplete(); } catch (_) {}
  SyncService.instance.startPeriodic();
  final startupSettings = await AppDatabase.instance.settings();
  final initialTheme = (startupSettings['theme_mode'] ?? 'Light') == 'Dark' ? ThemeMode.dark : ThemeMode.light;
  if (desktop) {
    const options = WindowOptions(
      size: Size(1280, 820),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
    );
    unawaited(windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.maximize();
      await windowManager.show();
      await windowManager.focus();
    }));
  }
  runApp(V4App(initialTheme: initialTheme));
  // Expensive housekeeping must never compete with first paint or POS startup.
  // Queue it at idle priority so the window becomes interactive first.
  unawaited(Future<void>.delayed(const Duration(seconds: 4), () async {
    await SchedulerBinding.instance.scheduleTask<void>(
      () => AppDatabase.instance.warmAnalyticsSnapshots(),
      Priority.idle,
      debugLabel: 'RELIQ analytics warm-up',
    );
  }));
  unawaited(Future<void>.delayed(const Duration(seconds: 8), () async {
    await SchedulerBinding.instance.scheduleTask<void>(() async {
      try { await AppDatabase.instance.maybeAutomaticBackup(); } catch (_) {}
    }, Priority.idle, debugLabel: 'RELIQ automatic backup');
  }));
}

class V4App extends StatefulWidget {
  final ThemeMode initialTheme;
  const V4App({super.key, required this.initialTheme});

  @override
  State<V4App> createState() => _V4AppState();
}

class _V4AppState extends State<V4App> {
  late ThemeMode mode;
  AuthUser? currentUser;
  Timer? _idleTimer;
  int _idleMinutes = 30;

  @override
  void initState() {
    super.initState();
    mode = widget.initialTheme;
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) _activity();
    return false;
  }


  ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final primaryText = dark ? const Color(0xFFF5F8F7) : const Color(0xFF1C2D30);
    final secondaryText = dark ? const Color(0xFFB8C9C8) : const Color(0xFF66777A);
    final mutedText = dark ? const Color(0xFF829A99) : const Color(0xFF66777A);
    final surface = dark ? const Color(0xD9162B2E) : const Color(0xE8FFFFFF);
    final surfaceStrong = dark ? const Color(0xF20B2024) : const Color(0xF7FFFFFF);
    final border = dark ? const Color(0x2EFFFFFF) : const Color(0xFFDDE5E6);
    final inputFill = dark ? const Color(0xA60A1E22) : const Color(0xD9FFFFFF);
    // Lime is the brand/action colour, but it is not a readable generic UI
    // foreground on white. Material's semantic primary therefore switches to
    // RELIQ teal in light mode; dark mode uses RELIQ Lime for interactive emphasis.
    final semanticPrimary = dark ? V3Style.lime : const Color(0xFF11908C);
    final onSemanticPrimary = dark ? V3Style.brandDark : Colors.white;

    final scheme = ColorScheme(
      brightness: brightness,
      primary: semanticPrimary,
      onPrimary: onSemanticPrimary,
      primaryContainer: dark ? const Color(0xFF35430A) : const Color(0xFFDDEDE8),
      onPrimaryContainer: dark ? const Color(0xFFF0FFC2) : const Color(0xFF173B36),
      secondary: const Color(0xFF11908C),
      onSecondary: dark ? Colors.white : const Color(0xFF092421),
      secondaryContainer: dark ? const Color(0xFF173B39) : const Color(0xFFD9EFEB),
      onSecondaryContainer: dark ? const Color(0xFFD9EFEB) : const Color(0xFF102C2A),
      error: V3Style.danger,
      onError: Colors.white,
      errorContainer: dark ? const Color(0xFF4B1E24) : const Color(0xFFF9DADD),
      onErrorContainer: dark ? const Color(0xFFFFDADD) : const Color(0xFF4B1E24),
      surface: surface,
      onSurface: primaryText,
      surfaceContainerHighest: dark ? const Color(0xFF20373A) : const Color(0xFFE1EAE7),
      onSurfaceVariant: secondaryText,
      outline: border,
      outlineVariant: border.withValues(alpha: .72),
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: dark ? const Color(0xFFF3F7F5) : const Color(0xFF1C2D30),
      onInverseSurface: dark ? const Color(0xFF1C2D30) : Colors.white,
      inversePrimary: V3Style.lime,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: Colors.transparent,
      canvasColor: surfaceStrong,
      dividerColor: border,
      splashFactory: InkRipple.splashFactory,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: surface,
        surfaceTintColor: Colors.transparent,
        shadowColor: dark ? Colors.black38 : const Color(0x220A2929),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(V3Style.radiusLg), side: BorderSide(color: border)),
      ),
      appBarTheme: AppBarTheme(elevation: 0, backgroundColor: surfaceStrong, foregroundColor: primaryText, surfaceTintColor: Colors.transparent),
      dialogTheme: DialogThemeData(
        elevation: 24,
        backgroundColor: surfaceStrong,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.black45,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: BorderSide(color: border)),
        titleTextStyle: TextStyle(color: primaryText, fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -.2),
        contentTextStyle: TextStyle(color: primaryText, fontSize: 13, height: 1.4),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: inputFill,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        labelStyle: TextStyle(color: secondaryText, fontSize: 12),
        floatingLabelStyle: TextStyle(color: dark ? V3Style.lime : const Color(0xFF11908C), fontWeight: FontWeight.w800),
        hintStyle: TextStyle(color: mutedText, fontSize: 12),
        prefixIconColor: secondaryText,
        suffixIconColor: secondaryText,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: border)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: dark ? V3Style.lime : const Color(0xFF11908C), width: 1.7)),
        errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: V3Style.danger)),
        focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: V3Style.danger, width: 1.5)),
      ),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
        backgroundColor: semanticPrimary,
        foregroundColor: onSemanticPrimary,
        disabledBackgroundColor: dark ? const Color(0xFF43504B) : const Color(0xFFDDE4DE),
        disabledForegroundColor: dark ? const Color(0xFF94A29D) : const Color(0xFF87918C),
        minimumSize: const Size(0, 42),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
      )),
      outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 42),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        foregroundColor: primaryText,
        backgroundColor: dark ? const Color(0x20FFFFFF) : const Color(0x8AFFFFFF),
        side: BorderSide(color: border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
      )),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(
        foregroundColor: dark ? V3Style.lime : const Color(0xFF11908C),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      )),
      iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(
        foregroundColor: primaryText,
        minimumSize: const Size(38, 38), iconSize: 19,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
      )),
      chipTheme: ChipThemeData(
        backgroundColor: dark ? const Color(0x661D3638) : const Color(0xBDF5F8F6),
        selectedColor: semanticPrimary.withValues(alpha: dark ? .20 : .14),
        labelStyle: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: primaryText),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)), side: BorderSide(color: border),
      ),
      listTileTheme: ListTileThemeData(
        textColor: primaryText, iconColor: secondaryText, dense: true, minTileHeight: 48,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
      ),
      dataTableTheme: DataTableThemeData(
        headingRowHeight: 44, dataRowMinHeight: 50, dataRowMaxHeight: 62, horizontalMargin: 14, columnSpacing: 18,
        headingRowColor: WidgetStatePropertyAll(dark ? const Color(0xB81A3335) : const Color(0xDCF1F5F2)),
        headingTextStyle: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: .45, color: secondaryText),
        dataTextStyle: TextStyle(fontSize: 12, color: primaryText), dividerThickness: .7,
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        textStyle: TextStyle(color: primaryText, fontSize: 13),
        inputDecorationTheme: InputDecorationTheme(
          filled: true, fillColor: inputFill,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: border)),
        ),
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(surfaceStrong), surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(16),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: border))),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surfaceStrong, surfaceTintColor: Colors.transparent, textStyle: TextStyle(color: primaryText, fontSize: 13), elevation: 16,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: border)),
      ),
      menuTheme: MenuThemeData(style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(surfaceStrong),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent), elevation: const WidgetStatePropertyAll(16),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: border))),
      )),
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? semanticPrimary.withValues(alpha: .55) : border),
        thumbColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? semanticPrimary : (dark ? const Color(0xFFD3E0E9) : Colors.white)),
      ),
      checkboxTheme: CheckboxThemeData(fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? semanticPrimary : null), checkColor: WidgetStatePropertyAll(onSemanticPrimary), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)), side: BorderSide(color: secondaryText)),
      radioTheme: RadioThemeData(fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? semanticPrimary : secondaryText)),
      tabBarTheme: TabBarThemeData(
        labelColor: dark ? V3Style.lime : const Color(0xFF11908C), unselectedLabelColor: secondaryText,
        labelStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800), unselectedLabelStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
        indicatorColor: dark ? V3Style.lime : const Color(0xFF11908C), dividerColor: border,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating, backgroundColor: dark ? const Color(0xF21A3335) : const Color(0xF510282B),
        contentTextStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), insetPadding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(color: dark ? const Color(0xFFF0F5F3) : const Color(0xFF1C2D30), borderRadius: BorderRadius.circular(8)),
        textStyle: TextStyle(color: dark ? const Color(0xFF1C2D30) : Colors.white, fontSize: 11, fontWeight: FontWeight.w600), waitDuration: const Duration(milliseconds: 450),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: semanticPrimary),
      dividerTheme: DividerThemeData(color: border, thickness: .7, space: 1),
      scrollbarTheme: ScrollbarThemeData(
        thumbVisibility: const WidgetStatePropertyAll(false), thickness: const WidgetStatePropertyAll(7), radius: const Radius.circular(99),
        thumbColor: WidgetStateProperty.resolveWith((states) => (states.contains(WidgetState.hovered) ? V3Style.lime : secondaryText).withValues(alpha: .46)),
      ),
      textSelectionTheme: TextSelectionThemeData(cursorColor: semanticPrimary, selectionColor: semanticPrimary.withValues(alpha: .22), selectionHandleColor: semanticPrimary),
      textTheme: ThemeData(brightness: brightness).textTheme.apply(bodyColor: primaryText, displayColor: primaryText).copyWith(
        headlineSmall: TextStyle(fontSize: 23, fontWeight: FontWeight.w800, letterSpacing: -.35, color: primaryText),
        titleLarge: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -.2, color: primaryText),
        titleMedium: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: primaryText),
        bodyMedium: TextStyle(fontSize: 13, height: 1.35, color: primaryText),
        bodySmall: TextStyle(fontSize: 11.5, height: 1.32, color: secondaryText),
        labelLarge: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: primaryText),
      ),
    );
  }

  Future<void> _onAuthenticated(AuthUser user) async {
    final values = await AppDatabase.instance.settings();
    _idleMinutes = (int.tryParse(values['session_timeout_minutes'] ?? '30') ?? 30).clamp(0, 1440).toInt();
    if (!mounted) return;
    setState(() => currentUser = user);
    _armIdleTimer();
  }

  void _armIdleTimer() {
    _idleTimer?.cancel();
    if (currentUser == null || _idleMinutes <= 0) return;
    _idleTimer = Timer(Duration(minutes: _idleMinutes), _lockForIdle);
  }

  void _activity() {
    if (currentUser != null) _armIdleTimer();
  }

  void _lockForIdle() {
    if (!mounted || currentUser == null) return;
    setState(() => currentUser = null);
  }

  void _logout() {
    _idleTimer?.cancel();
    setState(() => currentUser = null);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _idleTimer?.cancel();
    super.dispose();
  }

  void toggleTheme() {
    setState(() => mode = mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark);
    AppDatabase.instance.saveSettings({'theme_mode': mode == ThemeMode.dark ? 'Dark' : 'Light'});
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: Brand.name,
      themeMode: mode,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: currentUser == null
          ? LoginScreen(onAuthenticated: _onAuthenticated)
          : Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) => _activity(),
              onPointerMove: (_) => _activity(),
              child: AppShell(
                darkMode: mode == ThemeMode.dark,
                onToggleTheme: toggleTheme,
                currentUser: currentUser!,
                onLogout: _logout,
              ),
            ),
    );
  }
}
