// The look of the app, in one place.
//
// THE DIRECTION
//
// Minimal, search-first. The app is a utility someone opens at a bus stop,
// so the first screen is one question - "Where is your bus?" - and one
// large search field. No branded banner competes with it, and the canvas
// stays a soft off-white so the content is the only thing with weight.
//
// The palette keeps the red and green the project already measured
// against, but uses them as accents rather than surfaces. The destination
// board is still the signature detail: a route number should read as a
// real bus, not a string in a list.
//
// LAYOUT REFERENCES (lookap)
//
//   Home search anchor: "Expanding Search Interaction" by sucodee
//   (@sucodeee, https://x.com/sucodeee/status/2106690154429841524) - a soft
//   off-white canvas with one large pill search field and generous space
//   around it.
//
//   Journey summary: "Flight Status Card Microinteraction" by Michael Nowak
//   (@mnowakdesign, https://x.com/mnowakdesign/status/2110430533876658614) -
//   origin and destination at the two ends, a thin route line with the
//   vehicle in the middle, quiet times underneath.
//
// Only the arrangement of information is borrowed. Every colour, typeface,
// size and pixel here is this project's own.

import 'package:flutter/material.dart';

/// Every colour the app uses. Nothing outside this class should invent one.
class WimbColors {
  WimbColors._(); // never instantiated - this is a namespace, not an object

  /// DTC bus red. The single strongest brand signal in the app.
  static const dtcRed = Color(0xFFC1272D);
  static const dtcRedDark = Color(0xFF9A1F24);

  /// Cluster-bus green. Doubles as the "you can trust this" colour.
  static const delhiGreen = Color(0xFF0B6B3A);
  static const delhiGreenLight = Color(0xFFE7F2EB);

  /// The app canvas: a soft off-white, so a white card or a search field
  /// sits just above it without needing a heavy border.
  static const cream = Color(0xFFF6F6F3);
  static const cardCream = Color(0xFFFFFFFF);

  /// A second surface for search fields, chips and unselected segments.
  static const surfaceMuted = Color(0xFFEFEFEC);

  /// Text. Near-black with no colour cast.
  static const ink = Color(0xFF111111);
  static const inkMuted = Color(0xFF6B6B6B);
  static const inkFaint = Color(0xFF9B9B9B);

  /// The destination board above a bus windscreen: near-black, with warm
  /// off-white lettering the colour of an old bulb-lit sign.
  static const board = Color(0xFF14110F);
  static const boardText = Color(0xFFF5E6C8);

  /// Confidence levels. Green / amber / clay rather than green / orange /
  /// red, because a pure red would read as "error" when it actually means
  /// "this number is rough".
  static const trustHigh = delhiGreen;
  static const trustMedium = Color(0xFFE39A2E);
  static const trustLow = Color(0xFFB5502A);

  /// Faint cool border, used on cards and dividers.
  static const hairline = Color(0xFFE7E7E2);

  /// The one shadow colour in the system. Low opacity, wide blur, shifted
  /// down - a surface lifted off the page, not a drop shadow from a box.
  static const shadow = Color(0x0A000000);
}

/// The app's two typefaces, bundled with the app (see pubspec.yaml).
///
/// These are real font files, not system family names. Asking for a system
/// family by name does not work: a phone with a custom system font
/// substitutes its own, which on the OnePlus this was tested on rendered
/// the entire app in a serif no matter what was requested here.
class WimbFonts {
  WimbFonts._();

  /// Condensed, for destination boards, headings and the wordmark.
  static const condensed = 'BarlowCondensed';

  /// Ordinary body text.
  static const body = 'Barlow';

  /// Kept as a name for the few places that want digits to line up in a
  /// column. Barlow has no monospace cut, so those places use [tabular]
  /// instead - same effect for numbers, without a third font file.
  static const mono = 'Barlow';

  /// Makes every digit the same width, so a column of times or distances
  /// lines up instead of jittering as the numbers change.
  static const tabular = <FontFeature>[FontFeature.tabularFigures()];

  /// Empty on purpose. The fonts are bundled, so there is nothing to fall
  /// back TO - and leaving a system name here would let the substitution
  /// problem above creep back in.
  static const fallback = <String>[];
}

/// The spacing rhythm. Screens use these instead of inventing paddings, so
/// every screen breathes the same way.
class WimbSpace {
  WimbSpace._();

  /// Standard screen gutter. 20 instead of the old 16: on a 360dp phone the
  /// extra 4dp is the difference between a designed margin and a default.
  static const screen = 20.0;

  /// Between two major blocks on a screen.
  static const section = 24.0;

  /// Between a label and the thing it labels.
  static const label = 8.0;

  /// Between cards in a list.
  static const card = 12.0;
}

/// The corner radius family. Three values only; anything else is a mistake
/// waiting to look out of place.
class WimbRadius {
  WimbRadius._();

  /// Outer cards and sheets.
  static const card = 20.0;

  /// Inner surfaces: fields, time pills, small panels.
  static const field = 14.0;

  /// Fully rounded pills and chips.
  static const pill = 999.0;
}

/// Turns the API's confidence word into the colour that represents it.
Color trustColor(String level) {
  switch (level) {
    case 'high':
      return WimbColors.trustHigh;
    case 'medium':
      return WimbColors.trustMedium;
    case 'low':
      return WimbColors.trustLow;
    default:
      return WimbColors.inkMuted;
  }
}

/// The plain-English name for a confidence level, for showing next to the
/// trust dots. Kept beside trustColor so the two stay in step.
String trustLabel(String level) {
  switch (level) {
    case 'high':
      return 'high trust';
    case 'medium':
      return 'medium trust';
    case 'low':
      return 'rough estimate';
    default:
      return 'unknown';
  }
}

/// The app's one ThemeData. Everything component-level is set here rather
/// than on individual widgets, so a screen that just drops in a Card or a
/// FilledButton already looks right without styling it by hand.
ThemeData buildWimbTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: WimbColors.dtcRed,
    primary: WimbColors.dtcRed,
    secondary: WimbColors.delhiGreen,
    surface: WimbColors.cardCream,
    brightness: Brightness.light,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: WimbColors.cream,
    fontFamily: WimbFonts.body,
    fontFamilyFallback: WimbFonts.fallback,

    // Type is deliberately larger than the first version. That version was
    // cut to fit five route rows on a 359dp test phone, which made every
    // label feel like fine print. A modern phone screen can afford 15dp
    // body text; the long lists are handled by scrolling, not by shrinking.
    textTheme: const TextTheme(
      displaySmall: TextStyle(
        fontFamily: WimbFonts.condensed,
        fontFamilyFallback: WimbFonts.fallback,
        fontSize: 32,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
        height: 1.05,
        color: WimbColors.ink,
      ),
      headlineMedium: TextStyle(
        fontFamily: WimbFonts.condensed,
        fontFamilyFallback: WimbFonts.fallback,
        fontSize: 26,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
        height: 1.1,
        color: WimbColors.ink,
      ),
      titleLarge: TextStyle(
        fontFamily: WimbFonts.condensed,
        fontFamilyFallback: WimbFonts.fallback,
        fontSize: 20,
        fontWeight: FontWeight.w700,
        height: 1.15,
        color: WimbColors.ink,
      ),
      titleMedium: TextStyle(
        fontSize: 15.5,
        fontWeight: FontWeight.w600,
        height: 1.25,
        color: WimbColors.ink,
      ),
      // A small all-caps label used above each section. The wide letter
      // spacing is what makes it read as a label rather than as a heading.
      labelSmall: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.1,
        color: WimbColors.inkMuted,
      ),
      bodyLarge: TextStyle(fontSize: 15, color: WimbColors.ink, height: 1.45),
      bodyMedium: TextStyle(fontSize: 14, color: WimbColors.ink, height: 1.45),
      bodySmall: TextStyle(fontSize: 12.5, color: WimbColors.inkMuted, height: 1.4),
    ),

    // A plain canvas bar with a dark title. Red is the accent, not the
    // surface - except on the home hero, where it IS the content.
    appBarTheme: const AppBarTheme(
      backgroundColor: WimbColors.cream,
      foregroundColor: WimbColors.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      toolbarHeight: 60,
      titleSpacing: WimbScreenTitle.spacing,
      titleTextStyle: TextStyle(
        fontFamily: WimbFonts.condensed,
        fontFamilyFallback: WimbFonts.fallback,
        fontSize: 24,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.1,
        color: WimbColors.ink,
      ),
    ),

    // White cards on the light canvas, lifted by one soft shadow rather
    // than outlined. The hairline is kept at a very low contrast so it only
    // shows on bright screens, where the shadow alone disappears.
    cardTheme: CardThemeData(
      color: WimbColors.cardCream,
      elevation: 0,
      margin: EdgeInsets.zero,
      shadowColor: WimbColors.shadow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(WimbRadius.card),
        side: const BorderSide(color: WimbColors.hairline, width: 0.8),
      ),
    ),

    // Filled, not outlined. An outlined box with a floating label is the
    // single most web-looking thing a Flutter app can put on screen.
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: WimbColors.surfaceMuted,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(WimbRadius.field),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(WimbRadius.field),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(WimbRadius.field),
        borderSide: const BorderSide(color: WimbColors.dtcRed, width: 1.5),
      ),
      hintStyle: const TextStyle(color: WimbColors.inkFaint, fontSize: 15),
      labelStyle: const TextStyle(color: WimbColors.inkMuted),
      floatingLabelStyle: const TextStyle(color: WimbColors.dtcRed, fontWeight: FontWeight.w600),
    ),

    // 54dp tall and 16dp corners: comfortably past the thumb-target
    // minimum, and rounded like a modern app button rather than a capsule.
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: WimbColors.dtcRed,
        foregroundColor: Colors.white,
        disabledBackgroundColor: WimbColors.dtcRed.withValues(alpha: 0.28),
        disabledForegroundColor: Colors.white.withValues(alpha: 0.9),
        minimumSize: const Size.fromHeight(54),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(WimbRadius.field),
        ),
        textStyle: const TextStyle(
          fontFamily: WimbFonts.body,
          fontSize: 15.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.1,
        ),
      ),
    ),

    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: WimbColors.ink,
        minimumSize: const Size(0, 48),
        side: const BorderSide(color: WimbColors.hairline),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(WimbRadius.field),
        ),
        textStyle: const TextStyle(
          fontFamily: WimbFonts.body,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),

    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: WimbColors.dtcRed,
        minimumSize: const Size(0, 44),
        textStyle: const TextStyle(
          fontFamily: WimbFonts.body,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),

    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: WimbColors.cardCream,
      indicatorColor: WimbColors.dtcRed.withValues(alpha: 0.10),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: 72,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 11.5,
          fontWeight: states.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
          color: states.contains(WidgetState.selected) ? WimbColors.dtcRed : WimbColors.inkMuted,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 24,
          color: states.contains(WidgetState.selected) ? WimbColors.dtcRed : WimbColors.inkMuted,
        ),
      ),
    ),

    chipTheme: ChipThemeData(
      backgroundColor: WimbColors.cardCream,
      selectedColor: WimbColors.dtcRed.withValues(alpha: 0.10),
      side: const BorderSide(color: WimbColors.hairline),
      labelStyle: const TextStyle(
        fontFamily: WimbFonts.body,
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        color: WimbColors.ink,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(WimbRadius.pill),
      ),
      showCheckmark: false,
    ),

    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontFamily: WimbFonts.body, fontSize: 14.5, fontWeight: FontWeight.w600),
        ),
        side: const WidgetStatePropertyAll(BorderSide.none),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(WimbRadius.field)),
        ),
      ),
    ),

    dividerTheme: const DividerThemeData(
      color: WimbColors.hairline,
      thickness: 1,
      space: 1,
    ),

    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: WimbColors.cardCream,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: WimbColors.hairline,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),

    snackBarTheme: SnackBarThemeData(
      backgroundColor: WimbColors.board,
      contentTextStyle: const TextStyle(
        fontFamily: WimbFonts.body,
        color: WimbColors.boardText,
        fontSize: 14,
      ),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(WimbRadius.field)),
    ),

    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: WimbColors.dtcRed,
      linearTrackColor: WimbColors.surfaceMuted,
    ),

    listTileTheme: const ListTileThemeData(
      iconColor: WimbColors.inkMuted,
      textColor: WimbColors.ink,
    ),
  );
}

/// App bar title spacing, named so the theme and the screens cannot drift.
class WimbScreenTitle {
  WimbScreenTitle._();
  static const spacing = 20.0;
}

// ---------------------------------------------------------------------------
// Shared pieces of the look, used on more than one screen.
// ---------------------------------------------------------------------------

/// A route number drawn as the destination board above a bus windscreen.
///
/// This is the app's signature detail. A real Delhi bus carries a black
/// board with the route number and its destination in condensed capitals,
/// and copying that makes a route in a list read as an actual bus rather
/// than as a row of text.
///
/// [destination] is optional because the board is used in two ways: on its
/// own as a small badge in a tight row, and full-width with the destination
/// underneath when there is room to show where the bus is heading.
class RouteBoard extends StatelessWidget {
  final String routeName;
  final String? destination;

  /// Shrinks the whole board for use inside a dense list row.
  final bool compact;

  const RouteBoard({
    super.key,
    required this.routeName,
    this.destination,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 9 : 12,
        vertical: compact ? 5 : 8,
      ),
      decoration: BoxDecoration(
        color: WimbColors.board,
        borderRadius: BorderRadius.circular(compact ? 8 : 10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            routeName.toUpperCase(),
            // Delhi route numbers are not always short - "764BSTLDOWN" is
            // a real one - and the wide letter spacing that sells the
            // destination-board look makes long ones wider still. Without
            // a limit this can outgrow whatever row it sits in; capping it
            // here means the board itself can never be the cause of an
            // overflow, whichever screen embeds it.
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: WimbFonts.condensed,
              fontFamilyFallback: WimbFonts.fallback,
              color: WimbColors.boardText,
              fontSize: compact ? 14 : 17,
              fontWeight: FontWeight.w700,
              // Wide spacing is what sells the destination-board look -
              // real boards space their letters out to fill the width.
              letterSpacing: 1.3,
              height: 1.1,
            ),
          ),
          if (destination != null && destination!.isNotEmpty && !compact) ...[
            const SizedBox(height: 3),
            Text(
              destination!.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: WimbFonts.condensed,
                fontFamilyFallback: WimbFonts.fallback,
                // Dimmer than the route number, so the eye reads the
                // number first - same as looking at a real bus.
                color: WimbColors.boardText.withValues(alpha: 0.72),
                fontSize: 12,
                letterSpacing: 0.9,
                height: 1.1,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The trust indicator, as a row of five dots.
///
/// The user is told how much to trust a number, not just given the number.
/// Dots rather than a single coloured blob because a count is glanceable -
/// five filled versus two filled reads instantly, and it still works for
/// someone who cannot easily tell green from amber.
class TrustDots extends StatelessWidget {
  final String level; // 'high' | 'medium' | 'low'
  final bool showLabel;

  const TrustDots({super.key, required this.level, this.showLabel = true});

  /// How many of the five dots are filled in.
  int get _filled {
    switch (level) {
      case 'high':
        return 5;
      case 'medium':
        return 3;
      case 'low':
        return 1;
      default:
        return 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = trustColor(level);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < 5; i++)
          Padding(
            padding: const EdgeInsets.only(right: 3.5),
            child: Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < _filled ? color : color.withValues(alpha: 0.16),
              ),
            ),
          ),
        if (showLabel) ...[
          const SizedBox(width: 7),
          Text(
            trustLabel(level),
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ],
    );
  }
}

/// A small all-caps label that sits above a group of things, e.g. "BY THE
/// HOUR". Used instead of a heading where the group needs naming but does
/// not deserve the visual weight of a real title.
class SectionLabel extends StatelessWidget {
  final String text;
  final Widget? trailing;

  const SectionLabel(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    final label = Text(text.toUpperCase(), style: Theme.of(context).textTheme.labelSmall);
    if (trailing == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: WimbSpace.label),
        child: label,
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: WimbSpace.label),
      child: Row(
        children: [
          Expanded(child: label),
          trailing!,
        ],
      ),
    );
  }
}

/// A compact status pill. One widget so "Direct", "FASTEST", "Live" and
/// "Verified by crowd" all share a shape and a text size.
class StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  final bool filled;

  const StatusPill({
    super.key,
    required this.label,
    required this.color,
    this.filled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: filled ? color : color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(WimbRadius.pill),
      ),
      child: Text(
        label,
        maxLines: 1,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
          color: filled ? Colors.white : color,
        ),
      ),
    );
  }
}

/// A quiet full-width note with an icon, used for instructions and advice.
/// Replaces the several hand-built green/red boxes that had drifted apart.
class InfoBanner extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;

  const InfoBanner({
    super.key,
    required this.icon,
    required this.text,
    this.color = WimbColors.delhiGreen,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(WimbRadius.field),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                height: 1.35,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The empty-state block used by every screen before a search is made.
/// One shape, so the app stops asking the same question in four fonts.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 34, 24, 20),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(
              color: WimbColors.surfaceMuted,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 30, color: WimbColors.inkFaint),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 6),
          Text(
            body,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// The app's wordmark: "WHERE IS MY BUS", on one line.
///
/// The old version carried "दिल्ली · DELHI" underneath. The data behind the
/// app is still Delhi's, but the logo no longer brands the product to one
/// city - the app is simply Where Is My Bus.
class WimbWordmark extends StatelessWidget {
  final Color color;
  const WimbWordmark({super.key, this.color = Colors.white});

  @override
  Widget build(BuildContext context) {
    return Text(
      'WHERE IS MY BUS',
      style: TextStyle(
        fontFamily: WimbFonts.condensed,
        fontFamilyFallback: WimbFonts.fallback,
        color: color,
        fontSize: 20,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.8,
        height: 1.0,
      ),
    );
  }
}

/// A caveat line - one of the honest "here is what this number does not
/// know" notes the API returns with every answer.
///
/// Given its own widget because these appear on every result screen and
/// must look consistent: quiet enough not to shout, clear enough to read.
class CaveatLine extends StatelessWidget {
  final String text;
  const CaveatLine(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 8),
            child: Icon(
              Icons.info_outline,
              size: 14,
              color: WimbColors.inkFaint,
            ),
          ),
          Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
        ],
      ),
    );
  }
}
