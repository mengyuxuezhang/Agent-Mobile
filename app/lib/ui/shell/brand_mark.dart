import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../state/app_info.dart';
import '../theme/theme.dart';

/// Neutral mark used by the Android development build.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 28, this.color, this.tile = false});
  final double size;
  final Color? color;
  final bool tile;
  static const double aspect = 1;
  static const visualCentre = Offset(.5, .5);
  static Offset opticalShift(double size) => Offset.zero;

  @override
  Widget build(BuildContext context) {
    if (color == null && const bool.fromEnvironment('AGENT_BRAND_ICON')) {
      return Image.asset(
        'assets/managed-brand/icon.png',
        width: size,
        height: size,
        fit: BoxFit.contain,
        semanticLabel: AppInfo.name,
      );
    }
    final scheme = Theme.of(context).colorScheme;
    const primaryHex = String.fromEnvironment('AGENT_BRAND_PRIMARY');
    final colorValue = RegExp(r'^#[a-fA-F0-9]{6}$').hasMatch(primaryHex) ? int.parse(primaryHex.substring(1), radix: 16) : null;
    final primary = colorValue == null ? scheme.primary : Color(0xff000000 | colorValue);
    final onPrimary = colorValue == null ? scheme.onPrimary : (ThemeData.estimateBrightnessForColor(primary) == Brightness.dark ? Colors.white : Colors.black);
    final icon = Icon(Icons.auto_awesome, size: tile ? size * .6 : size,
        color: tile ? onPrimary : color ?? primary,
        semanticLabel: AppInfo.wordmark);
    if (!tile) return icon;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: primary,
        borderRadius: BorderRadius.circular(size * .22),
      ),
      child: icon,
    );
  }
}

/// The glyph and a wordmark on one line.
///
/// Everything follows the word's size (0.95 × [height] by default, times the app's
/// text scale):
/// - the glyph is [glyphScale] × the word's size tall;
/// - its visual centre ([BrandMark.visualCentre]) sits on the centre of the word's
///   main band: the x-height for a lowercase word (「dsh-go」), the cap height for
///   capitals (「DSH」);
/// - [gapScale] × the word's size separates the glyph's ink from the word.
class BrandLockup extends StatelessWidget {
  const BrandLockup({
    super.key,
    this.height = 20,
    this.fontSize,
    this.label = AppInfo.wordmark,
    this.color,
    this.glyphColor,
  });

  /// The lockup's size; the word is set at 0.95 × this unless [fontSize] is given.
  final double height;

  /// The word's size, overriding the one derived from [height].
  final double? fontSize;

  final String label;

  /// The word's colour (default: onSurface).
  final Color? color;

  /// A flat glyph tint instead of the colour glyph.
  final Color? glyphColor;

  /// Glyph height / word size.
  static const glyphScale = 1.25;

  /// Gap between the glyph and the word / word size.
  static const gapScale = 0.36;

  /// x-height and cap height of the system sans, in ems (Roboto: 1082 and 1456 of
  /// 2048 units).
  static const xHeight = 0.528;
  static const capHeight = 0.711;

  /// Height above the baseline of the line the glyph centres on, for [label] set at
  /// [size].
  static double centreRise(String label, double size) =>
      (label.contains(RegExp('[a-z]')) ? xHeight : capHeight) * size / 2;

  /// Where the word starts, from the lockup's left edge, for a word drawn at [size]
  /// (after text scaling): glyph width + gap.
  static double wordInset(double size) => size * glyphScale * BrandMark.aspect + size * gapScale;

  double get _size => fontSize ?? height * 0.95;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The word's drawn size: the glyph and the gap scale with the text.
    final drawn = MediaQuery.textScalerOf(context).scale(_size);
    final glyph = drawn * glyphScale;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        _GlyphBaseline(
          // A baseline this far below the glyph's top puts its visual centre on the
          // word's x-height (or cap-height) centre when the row aligns baselines.
          baseline: glyph * BrandMark.visualCentre.dy + centreRise(label, drawn),
          child: BrandMark(size: glyph, color: glyphColor),
        ),
        SizedBox(width: drawn * gapScale),
        Text(
          label,
          style: AppType.wordmark(size: _size, color: color ?? scheme.onSurface),
        ),
      ],
    );
  }
}

/// Reports [baseline] as its child's alphabetic baseline.
class _GlyphBaseline extends SingleChildRenderObjectWidget {
  const _GlyphBaseline({required this.baseline, required super.child});

  final double baseline;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderGlyphBaseline(baseline);

  @override
  void updateRenderObject(BuildContext context, _RenderGlyphBaseline renderObject) {
    renderObject.baseline = baseline;
  }
}

class _RenderGlyphBaseline extends RenderProxyBox {
  _RenderGlyphBaseline(this._baseline);

  double _baseline;

  set baseline(double value) {
    if (value == _baseline) return;
    _baseline = value;
    markNeedsLayout();
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) => _baseline;

  @override
  double? computeDryBaseline(BoxConstraints constraints, TextBaseline baseline) => _baseline;
}
