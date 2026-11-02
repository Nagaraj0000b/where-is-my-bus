// "When should I travel?" - the same journey costed for every service
// hour, so someone can see whether leaving now or later is actually
// faster. See api/src/server.ts on /journey/by-hour for why this needs
// OBSERVED frequency and can't come from a published timetable - no other
// Delhi bus app answers this question.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';
import 'error_card.dart';
import 'place_picker.dart';
import 'theme.dart';

/// The two points and the day type being compared. Day type is part of the
/// query (not a separate toggle after the fact) because weekday and
/// weekend traffic genuinely differ - see the weekend caveat this endpoint
/// always returns.
class ByHourQuery {
  final double fromLat;
  final double fromLon;
  final double toLat;
  final double toLon;
  final String dayType; // 'weekday' | 'weekend'
  final String fromName;
  final String toName;

  const ByHourQuery({
    required this.fromLat,
    required this.fromLon,
    required this.toLat,
    required this.toLon,
    required this.dayType,
    required this.fromName,
    required this.toName,
  });

  @override
  bool operator ==(Object other) =>
      other is ByHourQuery &&
      other.fromLat == fromLat &&
      other.fromLon == fromLon &&
      other.toLat == toLat &&
      other.toLon == toLon &&
      other.dayType == dayType;

  @override
  int get hashCode => Object.hash(fromLat, fromLon, toLat, toLon, dayType);
}

final byHourQueryProvider = StateProvider<ByHourQuery?>((ref) => null);

final byHourResultProvider = FutureProvider.autoDispose
    .family<ByHourResult, ByHourQuery>((ref, query) {
  return fetchJourneyByHour(
    fromLat: query.fromLat,
    fromLon: query.fromLon,
    toLat: query.toLat,
    toLon: query.toLon,
    dayType: query.dayType,
  );
});

class ByHourScreen extends ConsumerStatefulWidget {
  final PlaceSuggestion? initialFrom;
  final PlaceSuggestion? initialTo;

  const ByHourScreen({super.key, this.initialFrom, this.initialTo});

  @override
  ConsumerState<ByHourScreen> createState() => _ByHourScreenState();
}

class _ByHourScreenState extends ConsumerState<ByHourScreen> {
  PlaceSuggestion? _fromPlace;
  PlaceSuggestion? _toPlace;
  String _dayType = 'weekday';

  @override
  void initState() {
    super.initState();
    _fromPlace = widget.initialFrom;
    _toPlace = widget.initialTo;
    if (_fromPlace != null && _toPlace != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _compare());
    }
  }

  void _compare() {
    // The button is disabled until both are chosen, so this is just belt
    // and braces.
    if (_fromPlace == null || _toPlace == null) return;

    final query = ByHourQuery(
      fromLat: _fromPlace!.lat,
      fromLon: _fromPlace!.lon,
      toLat: _toPlace!.lat,
      toLon: _toPlace!.lon,
      dayType: _dayType,
      fromName: _fromPlace!.stopName,
      toName: _toPlace!.stopName,
    );
    ref.read(byHourQueryProvider.notifier).state = query;
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(byHourQueryProvider);

    final canCompare = _fromPlace != null && _toPlace != null;

    return Scaffold(
      appBar: AppBar(title: const Text('When should I travel?')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(WimbSpace.screen, 4, WimbSpace.screen, 32),
        children: [
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                PlacePickerRow(
                  label: 'FROM',
                  place: _fromPlace,
                  icon: Icons.trip_origin,
                  iconColor: WimbColors.delhiGreen,
                  onPicked: (place) => setState(() => _fromPlace = place),
                ),
                const Divider(height: 1, indent: 52),
                PlacePickerRow(
                  label: 'TO',
                  place: _toPlace,
                  icon: Icons.place,
                  iconColor: WimbColors.dtcRed,
                  onPicked: (place) => setState(() => _toPlace = place),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // A pill pair, sized to the thumb. It is the only choice on the
          // screen, so it gets its own full row.
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'weekday', label: Text('Weekday')),
              ButtonSegment(value: 'weekend', label: Text('Weekend')),
            ],
            selected: {_dayType},
            showSelectedIcon: false,
            onSelectionChanged: (selection) => setState(() => _dayType = selection.first),
            style: ButtonStyle(
              backgroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? WimbColors.dtcRed
                    : WimbColors.surfaceMuted,
              ),
              foregroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? Colors.white
                    : WimbColors.inkMuted,
              ),
              side: const WidgetStatePropertyAll(BorderSide.none),
              padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 15)),
            ),
          ),

          const SizedBox(height: 20),
          FilledButton(
            onPressed: canCompare ? _compare : null,
            child: const Text('Compare hours'),
          ),
          const SizedBox(height: 24),
          if (query == null) _emptyState(context) else _ResultsArea(query: query),
        ],
      ),
    );
  }

  /// Explains what this screen is for before anything has been compared -
  /// and why no other bus app can answer it.
  Widget _emptyState(BuildContext context) {
    return const EmptyState(
      icon: Icons.schedule,
      title: 'Is it faster to leave later?',
      body: 'The same trip is costed for every hour buses run, using how '
          'often they were actually observed - not a published timetable, '
          'which could never tell you this.',
    );
  }
}

class _ResultsArea extends ConsumerWidget {
  final ByHourQuery query;
  const _ResultsArea({required this.query});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(byHourResultProvider(query));

    return result.when(
      loading: () => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(),
        ),
      ),
      // See journey_screen.dart's identical split: this branch means the
      // request itself failed (unlike an honest "no route found" below),
      // so retrying the same query is worth offering.
      error: (err, _) => ErrorCard(
        message: err.toString(),
        onRetry: () => ref.invalidate(byHourResultProvider(query)),
      ),
      data: (byHour) {
        if (!byHour.available) {
          return ErrorCard(message: byHour.unavailableReason ?? 'No route found.');
        }
        // The bars are drawn relative to the slowest costed hour, so the
        // longest bar fills the row and every other hour is read against
        // it. Worked out once here rather than inside every row.
        final slowest = byHour.hours
            .map((h) => h.totalMinutes ?? 0)
            .fold<double>(0, (a, b) => a > b ? a : b);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: WimbColors.surfaceMuted,
                borderRadius: BorderRadius.circular(WimbRadius.field),
              ),
              child: Row(
                children: [
                  const Icon(Icons.trip_origin, size: 17, color: WimbColors.delhiGreen),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${query.fromName}  to  ${query.toName}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: WimbColors.ink,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // The headline answer, before the detail.
            Card(
              color: WimbColors.delhiGreenLight,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(WimbRadius.card),
                side: BorderSide.none,
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: const BoxDecoration(
                        color: WimbColors.cardCream,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.lightbulb_outline, color: WimbColors.delhiGreen, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        byHour.advice,
                        style: const TextStyle(
                          fontSize: 14.5,
                          height: 1.4,
                          fontWeight: FontWeight.w600,
                          color: WimbColors.ink,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 22),
            const SectionLabel('Hour by hour'),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                child: Column(
                  children: [
                    for (final hour in byHour.hours)
                      _HourRow(
                        hour: hour,
                        slowestMinutes: slowest,
                        isBest: byHour.best != null && hour.hourOfDay == byHour.best!.hourOfDay,
                        isWorst: byHour.worst != null && hour.hourOfDay == byHour.worst!.hourOfDay,
                      ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),
            ...byHour.caveats.map((c) => CaveatLine(c)),
          ],
        );
      },
    );
  }
}

/// One hour, drawn as a bar.
///
/// A bar rather than a column of numbers because the question this screen
/// answers is comparative - "is 08:00 better than 16:00" - and comparing
/// eighteen numbers by reading them is work the picture can do instead.
/// The number stays alongside for anyone who wants the exact figure.
class _HourRow extends StatelessWidget {
  final HourlyJourney hour;

  /// The longest journey of the day, which the bars are scaled against.
  final double slowestMinutes;
  final bool isBest;
  final bool isWorst;

  const _HourRow({
    required this.hour,
    required this.slowestMinutes,
    required this.isBest,
    required this.isWorst,
  });

  /// Best is green, worst is the alarm colour, everything between is a
  /// neutral red-brown. Only the two extremes are coloured, because
  /// colouring all eighteen would leave nothing standing out.
  Color get _barColor {
    if (isBest) return WimbColors.delhiGreen;
    if (isWorst) return WimbColors.trustLow;
    return WimbColors.dtcRed.withValues(alpha: 0.35);
  }

  @override
  Widget build(BuildContext context) {
    final noData = hour.totalMinutes == null;
    final label = '${hour.hourOfDay.toString().padLeft(2, '0')}:00';
    final emphasised = isBest || isWorst;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            // Wide enough for "05:00" without wrapping.
            width: 54,
            child: Text(
              label,
              maxLines: 1,
              style: TextStyle(
                // Tabular figures so every hour is the same width and the
                // bars all start on one clean vertical line.
                fontFeatures: WimbFonts.tabular,
                fontSize: 13.5,
                fontWeight: emphasised ? FontWeight.w700 : FontWeight.w500,
                color: emphasised ? WimbColors.ink : WimbColors.inkMuted,
              ),
            ),
          ),
          Expanded(
            child: noData
                ? Text(
                    'no data for this hour',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontStyle: FontStyle.italic,
                          color: WimbColors.inkMuted.withValues(alpha: 0.65),
                        ),
                  )
                : _bar(context),
          ),
        ],
      ),
    );
  }

  Widget _bar(BuildContext context) {
    final minutes = hour.totalMinutes!;
    // Guard against a divide-by-zero if every hour somehow costed 0.
    final fraction = slowestMinutes > 0 ? (minutes / slowestMinutes).clamp(0.05, 1.0) : 1.0;

    return Row(
      children: [
        Expanded(
          child: Stack(
            children: [
              // The track behind the bar, so short bars still read as
              // "short compared to the day" rather than floating in space.
              Container(
                height: 22,
                decoration: BoxDecoration(
                  color: WimbColors.surfaceMuted,
                  borderRadius: BorderRadius.circular(7),
                ),
              ),
              FractionallySizedBox(
                widthFactor: fraction,
                child: Container(
                  height: 22,
                  decoration: BoxDecoration(
                    color: _barColor,
                    borderRadius: BorderRadius.circular(7),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 50,
          child: Text(
            '${minutes.round()}m',
            textAlign: TextAlign.right,
            style: TextStyle(
              fontFeatures: WimbFonts.tabular,
              fontSize: 13.5,
              fontWeight: isBest || isWorst ? FontWeight.w700 : FontWeight.w500,
              color: isBest
                  ? WimbColors.delhiGreen
                  : isWorst
                      ? WimbColors.trustLow
                      : WimbColors.ink,
            ),
          ),
        ),
        // The confidence dot stays small - the bar is what carries the
        // comparison, and five full trust dots on every row would drown it.
        const SizedBox(width: 8),
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: trustColor(hour.confidenceLevel ?? ''),
          ),
        ),
      ],
    );
  }
}
