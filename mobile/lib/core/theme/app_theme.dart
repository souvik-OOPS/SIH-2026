import 'package:flutter/material.dart';

import '../../assistant/models/assistant_context.dart' show RiskLevel;
import '../safety/safety_assessment.dart' show SensorTrustState;
import '../telemetry/signal_quality.dart' show SignalQualityLevel;

/// Semantic colours that Material's [ColorScheme] has no slot for.
///
/// Signal quality, risk level and sensor trust are all "how much should you
/// believe this" scales, and none of them map onto primary/secondary/tertiary.
/// They live here as one extension rather than as a `switch` inside every
/// widget, so a level only ever picks a colour in one place.
///
/// The palette is deliberately small — five roles, not eighteen. Each enum
/// resolves onto a role, which keeps a fourteen-value scale from turning into
/// fourteen unrelated hues on a projector.
@immutable
class SignalColors extends ThemeExtension<SignalColors> {
  const SignalColors({
    required this.ok,
    required this.info,
    required this.warn,
    required this.crit,
    required this.neutral,
    required this.okSurface,
    required this.warnSurface,
    required this.critSurface,
  });

  final Color ok;
  final Color info;
  final Color warn;
  final Color crit;

  /// For states that carry no judgement — "not computed" is not "fine".
  final Color neutral;

  /// Low-alpha grounds for pills and banners.
  final Color okSurface;
  final Color warnSurface;
  final Color critSurface;

  static const dark = SignalColors(
    ok: Color(0xFF49D6C7),
    info: Color(0xFF9CC9FF),
    warn: Color(0xFFF6C859),
    crit: Color(0xFFFF7482),
    neutral: Color(0xFF91AAB5),
    okSurface: Color(0x2249D6C7),
    warnSurface: Color(0x22F6C859),
    critSurface: Color(0x22FF7482),
  );

  /// Darker hues than the dark theme uses: the same mint on white drops to
  /// about 1.8:1 and would be unreadable.
  static const light = SignalColors(
    ok: Color(0xFF0B8375),
    info: Color(0xFF1C6AAE),
    warn: Color(0xFF9A6300),
    crit: Color(0xFFC0293C),
    neutral: Color(0xFF5B7482),
    okSurface: Color(0x1A0B8375),
    warnSurface: Color(0x1A9A6300),
    critSurface: Color(0x1AC0293C),
  );

  /// Signal quality. `invalid` is critical, not neutral — a reading the app
  /// does not trust is a thing to act on, not a thing to shrug at.
  Color forSignal(SignalQualityLevel level) => switch (level) {
        SignalQualityLevel.excellent => ok,
        SignalQualityLevel.good => ok,
        SignalQualityLevel.fair => warn,
        SignalQualityLevel.poor => crit,
        SignalQualityLevel.invalid => crit,
      };

  /// Risk. `notComputed` is neutral on purpose: no assessment must never be
  /// coloured like an all-clear.
  Color forRisk(RiskLevel level) => switch (level) {
        RiskLevel.notComputed => neutral,
        RiskLevel.normal => ok,
        RiskLevel.watch => info,
        RiskLevel.warning => warn,
        RiskLevel.critical => crit,
      };

  Color forTrust(SensorTrustState state) => switch (state) {
        SensorTrustState.reliable => ok,
        SensorTrustState.degraded => warn,
        SensorTrustState.reacquiring => info,
        SensorTrustState.stale => warn,
      };

  @override
  SignalColors copyWith({
    Color? ok,
    Color? info,
    Color? warn,
    Color? crit,
    Color? neutral,
    Color? okSurface,
    Color? warnSurface,
    Color? critSurface,
  }) {
    return SignalColors(
      ok: ok ?? this.ok,
      info: info ?? this.info,
      warn: warn ?? this.warn,
      crit: crit ?? this.crit,
      neutral: neutral ?? this.neutral,
      okSurface: okSurface ?? this.okSurface,
      warnSurface: warnSurface ?? this.warnSurface,
      critSurface: critSurface ?? this.critSurface,
    );
  }

  @override
  SignalColors lerp(ThemeExtension<SignalColors>? other, double t) {
    if (other is! SignalColors) return this;
    return SignalColors(
      ok: Color.lerp(ok, other.ok, t)!,
      info: Color.lerp(info, other.info, t)!,
      warn: Color.lerp(warn, other.warn, t)!,
      crit: Color.lerp(crit, other.crit, t)!,
      neutral: Color.lerp(neutral, other.neutral, t)!,
      okSurface: Color.lerp(okSurface, other.okSurface, t)!,
      warnSurface: Color.lerp(warnSurface, other.warnSurface, t)!,
      critSurface: Color.lerp(critSurface, other.critSurface, t)!,
    );
  }
}

/// Shorthand so widgets read `context.signal.crit` rather than the full
/// `Theme.of(context).extension<SignalColors>()!` every time.
extension SignalColorsX on BuildContext {
  SignalColors get signal =>
      Theme.of(this).extension<SignalColors>() ?? SignalColors.dark;
  TextTheme get text => Theme.of(this).textTheme;
  ColorScheme get colors => Theme.of(this).colorScheme;
}

/// The app's type ramp.
///
/// Sized for a projected demo read from roughly three metres, which is a
/// different problem from a phone in the hand. Two rules follow from that:
/// the live vital leads at 64, and nothing is smaller than 12 — the previous
/// 9 and 10 px labels were illegible at that distance.
TextTheme _textTheme(Color primary, Color secondary, Color muted) {
  return TextTheme(
    // The live vital. Deliberately the largest thing on the screen.
    displayLarge: TextStyle(
      fontSize: 64,
      height: 1.0,
      fontWeight: FontWeight.w700,
      letterSpacing: -1.5,
      color: primary,
    ),
    // Secondary vitals (SpO2, ambient).
    headlineMedium: TextStyle(
      fontSize: 30,
      height: 1.1,
      fontWeight: FontWeight.w700,
      color: primary,
    ),
    titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: primary),
    titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: primary),
    bodyLarge: TextStyle(fontSize: 16, height: 1.4, color: secondary),
    bodyMedium: TextStyle(fontSize: 14, height: 1.4, color: secondary),
    // Section headers and unit labels.
    labelLarge: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      letterSpacing: 1.0,
      color: muted,
    ),
    labelMedium: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: muted),
    // The floor. Nothing in the app should be smaller than this.
    labelSmall: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      letterSpacing: 1.2,
      color: muted,
    ),
  );
}

abstract final class AppTheme {
  static const _darkBg = Color(0xFF081923);
  static const _darkSurface = Color(0xFF102833);
  static const _darkPrimaryText = Color(0xFFE6F1F4);
  static const _darkSecondaryText = Color(0xFFC2D7DA);
  static const _darkMutedText = Color(0xFF91AAB5);

  static const _lightBg = Color(0xFFF2F6F8);
  static const _lightSurface = Color(0xFFFFFFFF);
  static const _lightPrimaryText = Color(0xFF08202B);
  static const _lightSecondaryText = Color(0xFF31505D);
  static const _lightMutedText = Color(0xFF5B7482);

  static ThemeData get dark {
    final scheme = ColorScheme.fromSeed(
      seedColor: SignalColors.dark.ok,
      brightness: Brightness.dark,
      surface: _darkSurface,
      onSurface: _darkPrimaryText,
      primary: SignalColors.dark.ok,
      error: SignalColors.dark.crit,
    );
    return _base(scheme, _darkBg, _darkPrimaryText, _darkSecondaryText, _darkMutedText,
        SignalColors.dark);
  }

  /// Offered because a dark UI loses contrast punch on a projector in a lit
  /// room — the black level rises and the whole image goes muddy.
  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(
      seedColor: SignalColors.light.ok,
      brightness: Brightness.light,
      surface: _lightSurface,
      onSurface: _lightPrimaryText,
      primary: SignalColors.light.ok,
      error: SignalColors.light.crit,
    );
    return _base(scheme, _lightBg, _lightPrimaryText, _lightSecondaryText, _lightMutedText,
        SignalColors.light);
  }

  static ThemeData _base(
    ColorScheme scheme,
    Color background,
    Color primaryText,
    Color secondaryText,
    Color mutedText,
    SignalColors signal,
  ) {
    final text = _textTheme(primaryText, secondaryText, mutedText);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      textTheme: text,
      extensions: <ThemeExtension<dynamic>>[signal],
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: primaryText,
        titleTextStyle: text.titleLarge,
      ),
      cardTheme: CardThemeData(
        color: scheme.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      dividerColor: mutedText.withValues(alpha: 0.18),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          textStyle: text.titleMedium,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
    );
  }
}
