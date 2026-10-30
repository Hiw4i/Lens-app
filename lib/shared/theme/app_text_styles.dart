import 'package:flutter/material.dart';
import 'package:lens/shared/theme/theme_colors.dart';

class AppTextStyles {
  static const String _headingFont = 'SpaceGrotesk';
  static const String _bodyFont = 'Inter';
  static const String _monoFont = 'JetBrainsMono';

  static TextStyle button(BuildContext context) => body(context).copyWith(
    fontFamily: _headingFont,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.3,
    // Button labels use natural font metrics regardless of their visual variant.
    height: kTextHeightNone,
  );

  /// Compact action-button label: the shared 14/w500 variant every
  /// secondary ghost button uses.
  ///
  /// Deliberately COLORLESS and font-free (a partial style, meant to be
  /// merged over [button] by the button): AppButton resolves the label
  /// color per variant (`style.foregroundColor ?? style.textStyle?.color
  /// ?? foreground`), so a color here would override the variant's
  /// foreground and render primary-button labels invisible against the
  /// primary fill.
  static const TextStyle buttonSmall = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
  );

  static TextStyle headingLarge(BuildContext context) {
    final isDesktop = switch (Theme.of(context).platform) {
      TargetPlatform.windows ||
      TargetPlatform.linux ||
      TargetPlatform.macOS => true,
      _ => false,
    };

    return TextStyle(
      fontFamily: _headingFont,
      fontSize: 30,
      fontWeight: FontWeight.bold,
      color: context.themeColors.primary,
      height: 1.1,
      letterSpacing: isDesktop ? 2.0 : 0.0,
    );
  }

  static TextStyle heading(BuildContext context) => TextStyle(
    fontFamily: _headingFont,
    fontSize: 24,
    fontWeight: FontWeight.bold,
    color: context.themeColors.primary,
    height: 1.2,
  );

  static TextStyle subheading(BuildContext context) => TextStyle(
    fontFamily: _headingFont,
    fontSize: 18,
    fontWeight: FontWeight.bold,
    color: context.themeColors.primary,
    height: 1.2,
  );

  static TextStyle body(BuildContext context) => TextStyle(
    fontFamily: _bodyFont,
    fontSize: 16,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    color: context.themeColors.primary,
    height: 1.3,
  );

  static TextStyle bodyDim(BuildContext context) =>
      body(context).copyWith(color: context.themeColors.secondary);

  static TextStyle small(BuildContext context) =>
      body(context).copyWith(fontSize: 12);

  static TextStyle smallDim(BuildContext context) =>
      small(context).copyWith(color: context.themeColors.secondary);

  /// Monospace for versions and other machine-readable strings.
  static TextStyle monoSmall(BuildContext context) => small(context).copyWith(
    fontFamily: _monoFont,
    color: context.themeColors.primary,
    fontSize: 13,
    fontWeight: FontWeight.w400,
  );
}
