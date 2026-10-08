import 'dart:ui';

import 'package:flutter/material.dart';

import '../config/brand.dart';
import '../services/auth_service.dart';
import '../ui/reliq_surface.dart';
import '../ui/v3_style.dart';

class LoginScreen extends StatefulWidget {
  final ValueChanged<AuthUser> onAuthenticated;
  const LoginScreen({super.key, required this.onAuthenticated});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final username = TextEditingController(text: 'owner');
  final password = TextEditingController();
  final confirm = TextEditingController();
  bool loading = true;
  bool setup = false;
  bool obscure = true;
  bool submitting = false;
  String error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final needs = await AuthService.instance.needsOwnerSetup();
    if (!mounted) return;
    setState(() {
      setup = needs;
      loading = false;
    });
  }

  @override
  void dispose() {
    username.dispose();
    password.dispose();
    confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (submitting) return;
    setState(() {
      error = '';
      submitting = true;
    });
    try {
      if (setup) {
        if (password.text != confirm.text)
          throw Exception('Passwords do not match.');
        await AuthService.instance.setupOwnerPassword(password.text);
      }
      final user =
          await AuthService.instance.login(username.text, password.text);
      widget.onAuthenticated(user);
    } catch (e) {
      if (mounted)
        setState(() => error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading)
      return const Scaffold(body: Center(child: CircularProgressIndicator()));

    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= 900;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final primaryText = dark ? Colors.white : const Color(0xFF1C2D30);
    final secondaryText =
        dark ? const Color(0xFFAEBFBE) : const Color(0xFF66777A);

    if (!wide) {
      return Scaffold(
        backgroundColor:
            dark ? const Color(0xFF06171B) : const Color(0xFFF2F7F6),
        body: Stack(fit: StackFit.expand, children: [
          Image.asset(
            dark
                ? 'assets/branding/reliq_background_dark.jpg'
                : 'assets/branding/reliq_background_light.png',
            fit: BoxFit.cover,
            alignment: Alignment.center,
            filterQuality: FilterQuality.high,
          ),
          ColoredBox(
              color: dark ? const Color(0x3A031416) : const Color(0x32FFFFFF)),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(22),
                child: _loginCard(context, primaryText, secondaryText,
                    showBrand: true),
              ),
            ),
          ),
        ]),
      );
    }

    // V2.2.9: preserve the supplied login composition instead of stretching one
    // wallpaper underneath the whole window. At the 1280×800 reference size the
    // split is ~56/44 and the card lands at the same proportions as the mock-up.
    final leftWidth = size.width * 0.56;
    return Scaffold(
      backgroundColor: dark ? const Color(0xFF06171B) : const Color(0xFFF2F7F6),
      body: Row(children: [
        SizedBox(
          width: leftWidth,
          child: _brandPane(context, dark: dark, size: size),
        ),
        Expanded(
          child: _loginPane(
            context,
            dark: dark,
            primaryText: primaryText,
            secondaryText: secondaryText,
          ),
        ),
      ]),
    );
  }

  Widget _brandPane(BuildContext context,
      {required bool dark, required Size size}) {
    final primary = dark ? Colors.white : const Color(0xFF1C2D30);
    final secondary = dark ? const Color(0xFFE0E9E6) : const Color(0xFF1C2D30);
    final left = (size.width * .067).clamp(58.0, 100.0).toDouble();
    final top = (size.height * .105).clamp(54.0, 92.0).toDouble();
    final bottom = (size.height * .095).clamp(56.0, 84.0).toDouble();

    return Stack(fit: StackFit.expand, children: [
      Image.asset(
        dark
            ? 'assets/branding/reliq_background_dark.jpg'
            : 'assets/branding/reliq_background_light.png',
        fit: BoxFit.cover,
        alignment: Alignment.center,
        filterQuality: FilterQuality.high,
      ),
      // Tiny readability treatment only; the actual artwork remains visible and
      // uncropped as the user supplied it.
      IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: dark
                  ? [
                      const Color(0x10000000),
                      Colors.transparent,
                      const Color(0x26000000)
                    ]
                  : [
                      const Color(0x08FFFFFF),
                      Colors.transparent,
                      const Color(0x10000000)
                    ],
            ),
          ),
        ),
      ),
      Positioned(
        left: left,
        top: top,
        child: Image.asset(
          dark
              ? 'assets/branding/reliq_logo_white.png'
              : 'assets/branding/reliq_logo.png',
          height: 74,
          fit: BoxFit.contain,
          alignment: Alignment.centerLeft,
        ),
      ),
      Positioned(
        left: left,
        bottom: bottom,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 470),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              'Fast local POS, inventory intelligence and\nbranch-aware operations.',
              style: TextStyle(
                color: primary,
                fontSize: 18,
                height: 1.35,
                fontWeight: FontWeight.w800,
                shadows: dark
                    ? const [Shadow(color: Colors.black45, blurRadius: 10)]
                    : null,
              ),
            ),
            const SizedBox(height: 12),
            _StoryLine('assets/branding/login_pos.png',
                'Barcode-ready sales and purchasing', secondary),
            _StoryLine('assets/branding/login_inventory.png',
                'Stock, transfers and replenishment', secondary),
            _StoryLine('assets/branding/login_intelligence.png',
                'Reports, ledgers and operational audit trail', secondary),
          ]),
        ),
      ),
    ]);
  }

  Widget _loginPane(
    BuildContext context, {
    required bool dark,
    required Color primaryText,
    required Color secondaryText,
  }) {
    return Stack(fit: StackFit.expand, children: [
      ColoredBox(
          color: dark ? const Color(0xFF06171B) : const Color(0xFFF2F7F6)),
      // The supplied dark reference has a restrained green bloom at the split.
      IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: dark
                  ? [
                      const Color(0x2C6D8819),
                      const Color(0x100B2A25),
                      Colors.transparent
                    ]
                  : [
                      const Color(0x26DDEBB8),
                      const Color(0x12FFFFFF),
                      Colors.transparent
                    ],
              stops: const [0, .28, .72],
            ),
          ),
        ),
      ),
      Align(
        alignment: const Alignment(0, -0.03),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: _loginCard(context, primaryText, secondaryText),
        ),
      ),
    ]);
  }

  Widget _frostedField(BuildContext context, Widget child) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final radius = BorderRadius.circular(13);
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          decoration: BoxDecoration(
            color: dark ? const Color(0x42102124) : const Color(0xA8FFFFFF),
            borderRadius: radius,
            border: Border.all(
                color:
                    dark ? const Color(0x32FFFFFF) : const Color(0xC8DDE5E6)),
            boxShadow: [
              BoxShadow(
                color: dark ? const Color(0x26000000) : const Color(0x120A2929),
                blurRadius: 18,
                offset: const Offset(0, 7),
              ),
            ],
          ),
          child: Stack(fit: StackFit.passthrough, children: [
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: dark
                          ? [
                              const Color(0x18FFFFFF),
                              const Color(0x03FFFFFF),
                              const Color(0x0AE1FF05)
                            ]
                          : [
                              const Color(0x78FFFFFF),
                              const Color(0x10FFFFFF),
                              const Color(0x0811908C)
                            ],
                      stops: const [0, .48, 1],
                    ),
                  ),
                ),
              ),
            ),
            child,
          ]),
        ),
      ),
    );
  }

  Widget _loginCard(
      BuildContext context, Color primaryText, Color secondaryText,
      {bool showBrand = false}) {
    final size = MediaQuery.sizeOf(context);
    final cardHeight = (size.height * .8225).clamp(520.0, 658.0).toDouble();
    return ConstrainedBox(
      constraints: BoxConstraints(
          maxWidth: 530, minHeight: cardHeight, maxHeight: cardHeight),
      child: ReliqGlass(
        strong: true,
        reflective: true,
        reflectionStrength:
            Theme.of(context).brightness == Brightness.dark ? 1.0 : .78,
        blur: 28,
        radius: 28,
        padding: const EdgeInsets.fromLTRB(48, 0, 48, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (showBrand) ...[
              Align(
                  alignment: Alignment.centerLeft,
                  child:
                      ReliqBrandLockup(compact: true, textColor: primaryText)),
              const SizedBox(height: 34),
            ],
            Text(
              setup ? 'Secure your account' : 'Sign in',
              style: TextStyle(
                  color: primaryText,
                  fontSize: 31,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.7),
            ),
            const SizedBox(height: 6),
            Text(Brand.tagline,
                style: TextStyle(
                    color: secondaryText,
                    fontSize: 13,
                    fontWeight: FontWeight.w500)),
            const SizedBox(height: 30),
            _frostedField(
              context,
              TextField(
                controller: username,
                enabled: !setup,
                textInputAction: TextInputAction.next,
                style:
                    TextStyle(color: primaryText, fontWeight: FontWeight.w600),
                decoration: const InputDecoration(
                  labelText: 'Username',
                  prefixIcon: Icon(Icons.person_outline),
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                ),
              ),
            ),
            const SizedBox(height: 16),
            _frostedField(
              context,
              TextField(
                controller: password,
                autofocus: true,
                obscureText: obscure,
                textInputAction:
                    setup ? TextInputAction.next : TextInputAction.done,
                onSubmitted: setup ? null : (_) => _submit(),
                style:
                    TextStyle(color: primaryText, fontWeight: FontWeight.w600),
                decoration: InputDecoration(
                  labelText: setup ? 'Create password / PIN' : 'Password / PIN',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => obscure = !obscure),
                    icon: Icon(obscure
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined),
                  ),
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                ),
              ),
            ),
            if (setup) ...[
              const SizedBox(height: 16),
              _frostedField(
                context,
                TextField(
                  controller: confirm,
                  obscureText: obscure,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                  style: TextStyle(
                      color: primaryText, fontWeight: FontWeight.w600),
                  decoration: const InputDecoration(
                    labelText: 'Confirm password / PIN',
                    prefixIcon: Icon(Icons.verified_user_outlined),
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                  ),
                ),
              ),
            ],
            if (error.isNotEmpty) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: V3Style.softFor(V3Style.danger,
                      dark: Theme.of(context).brightness == Brightness.dark),
                  borderRadius: BorderRadius.circular(12),
                  border:
                      Border.all(color: V3Style.danger.withValues(alpha: .28)),
                ),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.error_outline,
                          color: V3Style.danger, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text(error,
                              style: const TextStyle(
                                  color: V3Style.danger,
                                  fontWeight: FontWeight.w700))),
                    ]),
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              height: 54,
              child: FilledButton.icon(
                onPressed: submitting ? null : _submit,
                icon: submitting
                    ? const SizedBox(
                        width: 17,
                        height: 17,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(setup ? Icons.shield_outlined : Icons.login),
                label: Text(submitting
                    ? 'Signing in…'
                    : (setup ? 'Create Password & Sign In' : 'Sign In')),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Your data remains local on this computer. User actions are attached\nto the active account for auditing.',
              textAlign: TextAlign.center,
              style:
                  TextStyle(color: secondaryText, fontSize: 11, height: 1.45),
            ),
          ],
        ),
      ),
    );
  }
}

class _StoryLine extends StatelessWidget {
  final String iconAsset;
  final String text;
  final Color color;
  const _StoryLine(this.iconAsset, this.text, this.color);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Row(children: [
          Image.asset(iconAsset, width: 17, height: 17, fit: BoxFit.contain),
          const SizedBox(width: 7),
          Flexible(
              child: Text(text,
                  style: TextStyle(
                      color: color,
                      fontSize: 14,
                      fontWeight: FontWeight.w500))),
        ]),
      );
}
