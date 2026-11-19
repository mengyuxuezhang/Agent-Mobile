import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import '../state/app_info.dart';
import '../ui/shell/brand_mark.dart';

class ManagedAuthLayout extends StatelessWidget {
  const ManagedAuthLayout({
    super.key,
    required this.title,
    required this.subtitle,
    required this.children,
    this.footer,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color.alphaBlend(colors.primary.withValues(alpha: .1), colors.surface), colors.surface],
            stops: const [0, .72],
          ),
        ),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Align(
                alignment: AlignmentDirectional.centerStart,
                child: Padding(padding: EdgeInsetsDirectional.only(start: 10), child: BackButton()),
              ),
              Expanded(
                child: ListView(
                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.fromLTRB(24, 10, 24, 24),
                  children: [
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 410),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Row(
                              children: [
                                BrandMark(size: 35, tile: true),
                                SizedBox(width: 10),
                                Expanded(
                                  child: Text(AppInfo.name, style: TextStyle(fontWeight: FontWeight.w700)),
                                ),
                              ],
                            ),
                            const SizedBox(height: 22),
                            Text(title, style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
                            const SizedBox(height: 8),
                            Text(subtitle, style: theme.textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant)),
                            const SizedBox(height: 22),
                            DecoratedBox(
                              decoration: BoxDecoration(
                                color: colors.surfaceContainerLowest,
                                borderRadius: BorderRadius.circular(24),
                                border: Border.all(color: colors.outlineVariant),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: AutofillGroup(
                                  onDisposeAction: AutofillContextAction.cancel,
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
                                ),
                              ),
                            ),
                            if (footer != null) ...[const SizedBox(height: 12), footer!],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

InputDecoration managedAuthInput(BuildContext context, String label, IconData icon, {Widget? suffix}) {
  final colors = Theme.of(context).colorScheme;
  return InputDecoration(
    labelText: label,
    prefixIcon: Icon(icon, size: 21),
    suffixIcon: suffix,
    filled: true,
    fillColor: colors.surfaceContainerLow,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
    counterText: '',
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: colors.primary, width: 1.4),
    ),
  );
}

class ManagedPasswordField extends StatefulWidget {
  const ManagedPasswordField({
    super.key,
    required this.controller,
    required this.enabled,
    required this.autofillHint,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final bool enabled;
  final String autofillHint;
  final ValueChanged<String>? onSubmitted;

  @override
  State<ManagedPasswordField> createState() => _ManagedPasswordFieldState();
}

class _ManagedPasswordFieldState extends State<ManagedPasswordField> {
  bool _obscured = true;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      enabled: widget.enabled,
      obscureText: _obscured,
      autocorrect: false,
      enableSuggestions: false,
      autofillHints: [widget.autofillHint],
      inputFormatters: [LengthLimitingTextInputFormatter(1024)],
      textInputAction: widget.onSubmitted == null ? TextInputAction.next : TextInputAction.done,
      onSubmitted: widget.onSubmitted,
      decoration: managedAuthInput(
        context,
        context.l10n.managedPassword,
        Icons.lock_outline,
        suffix: IconButton(
          tooltip: _obscured ? context.l10n.managedShowPassword : context.l10n.managedHidePassword,
          icon: Icon(_obscured ? Icons.visibility_outlined : Icons.visibility_off_outlined),
          onPressed: () => setState(() => _obscured = !_obscured),
        ),
      ),
    );
  }
}

class ManagedAuthMessage extends StatelessWidget {
  const ManagedAuthMessage(this.message, {super.key, this.error = true});

  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Text(message, style: TextStyle(color: error ? colors.error : colors.primary)),
      ),
    );
  }
}
