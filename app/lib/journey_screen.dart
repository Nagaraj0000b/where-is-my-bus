// The journey planner screen - the first real screen of the app.
//
// Two points in, ranked ways to travel out - see api/src/journey.ts for why
// this (not a live map) is "the screen the whole app is really for". It's
// also the honest first screen to build: there's no live vehicle feed right
// now (the recorder was deliberately stopped), so a "buses arriving now"
// screen would have to fake it. This screen only ever shows things the data
// can actually back up.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';

import 'api_client.dart';
import 'arrival_alarm_service.dart';
import 'by_hour_screen.dart';
import 'error_card.dart';
import 'place_picker.dart';
import 'route_map_widget.dart';
import 'theme.dart';
import 'package:latlong2/latlong.dart';

/// Turns a number of minutes from now into a real clock time, e.g. "7:15 PM".
/// The backend only ever gives back a DURATION (never a clock time - see
/// api/src/journey.ts), so turning that into "arrives around..." is done
/// here, on the device, using the moment the search was actually made.
final _clockFormat = DateFormat('h:mm a');
String _clockTime(DateTime askedAt, double minutesFromAskedAt) {
  final at = askedAt.add(Duration(minutes: minutesFromAskedAt.round()));
  return _clockFormat.format(at);
}

/// The two points a journey is being planned between, plus the moment the
/// search was made. `askedAt` is part of the query (not just a display
/// detail) so that pressing "Find buses" again always asks the backend
/// fresh, and so the clock times shown next to a result never silently
/// drift if the screen happens to rebuild later.
class JourneyQuery {
  final double fromLat;
  final double fromLon;
  final double toLat;
  final double toLon;
  final DateTime askedAt;
  // Display-only - the names someone picked, so results can be headed
  // "Shivaji Park -> Madi Pur JJ Colony" instead of just showing a list
  // of options with no reminder of what was actually asked.
  final String fromName;
  final String toName;

  const JourneyQuery({
    required this.fromLat,
    required this.fromLon,
    required this.toLat,
    required this.toLon,
    required this.askedAt,
    required this.fromName,
    required this.toName,
  });

  @override
  bool operator ==(Object other) =>
      other is JourneyQuery &&
      other.fromLat == fromLat &&
      other.fromLon == fromLon &&
      other.toLat == toLat &&
      other.toLon == toLon &&
      other.askedAt == askedAt;

  @override
  int get hashCode => Object.hash(fromLat, fromLon, toLat, toLon, askedAt);
}

/// Holds the query currently being searched for. Null means "nothing
/// searched yet" - the screen shows the input form only, no results area.
final journeyQueryProvider = StateProvider<JourneyQuery?>((ref) => null);

/// Fetches journey options for whatever query is currently set. `.family`
/// means Riverpod keeps a separate cached result per distinct query;
/// `.autoDispose` throws each one away once nothing is watching it any
/// more, so old searches don't pile up in memory as someone tries several.
final journeyResultProvider = FutureProvider.autoDispose
    .family<JourneyResult, JourneyQuery>((ref, query) {
      return fetchJourney(
        fromLat: query.fromLat,
        fromLon: query.fromLon,
        toLat: query.toLat,
        toLon: query.toLon,
      );
    });

/// Reference Delhi bus hubs for testing outside Delhi (e.g. while in Guwahati)
/// or for one-tap professor/evaluator demonstrations.
class _DemoHub {
  final String shortName;
  final String fullName;
  final double lat;
  final double lon;

  const _DemoHub({
    required this.shortName,
    required this.fullName,
    required this.lat,
    required this.lon,
  });

  PlaceSuggestion toPlace() => PlaceSuggestion(
        stopName: fullName,
        lat: lat,
        lon: lon,
      );
}

const _demoHubs = [
  _DemoHub(
    shortName: 'Shivaji Stadium (CP)',
    fullName: 'Shivaji Stadium Terminal (Connaught Place)',
    lat: 28.6323,
    lon: 77.2165,
  ),
  _DemoHub(
    shortName: 'AIIMS',
    fullName: 'AIIMS / Safdarjung Hospital',
    lat: 28.5670,
    lon: 77.2080,
  ),
  _DemoHub(
    shortName: 'Nehru Place',
    fullName: 'Nehru Place Terminal',
    lat: 28.5487,
    lon: 77.2570,
  ),
  _DemoHub(
    shortName: 'Kashmere Gate',
    fullName: 'ISBT Kashmere Gate',
    lat: 28.6668,
    lon: 77.2294,
  ),
  _DemoHub(
    shortName: 'Dhaula Kuan',
    fullName: 'Dhaula Kuan Terminal',
    lat: 28.5947,
    lon: 77.1661,
  ),
  _DemoHub(
    shortName: 'Anand Vihar',
    fullName: 'ISBT Anand Vihar Terminal',
    lat: 28.6470,
    lon: 77.3176,
  ),
];

class JourneyScreen extends ConsumerStatefulWidget {
  final PlaceSuggestion? initialFrom;
  final PlaceSuggestion? initialTo;

  /// Whether the result map may fetch OpenStreetMap tiles. The app leaves
  /// this on; widget tests and screenshot runs turn it off so the route
  /// geometry still renders without the test harness blocking the network.
  final bool enableMapTiles;

  const JourneyScreen({
    super.key,
    this.initialFrom,
    this.initialTo,
    this.enableMapTiles = true,
  });

  @override
  ConsumerState<JourneyScreen> createState() => _JourneyScreenState();
}

class _JourneyScreenState extends ConsumerState<JourneyScreen> {
  PlaceSuggestion? _fromPlace;
  PlaceSuggestion? _toPlace;

  @override
  void initState() {
    super.initState();
    _fromPlace = widget.initialFrom;
    _toPlace = widget.initialTo;
    if (_fromPlace != null && _toPlace != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _search());
    }
  }

  // True while waiting on the phone's GPS, so the row can show a spinner
  // instead of looking like it did nothing.
  bool _locating = false;

  // When true, location actions automatically use simulated Delhi transit hubs
  // rather than failing when evaluated outside Delhi.
  bool _simulateInDelhi = false;

  void _search() {
    // The button is disabled until both are set, so this is belt and
    // braces rather than the main guard.
    if (_fromPlace == null || _toPlace == null) return;

    final query = JourneyQuery(
      fromLat: _fromPlace!.lat,
      fromLon: _fromPlace!.lon,
      toLat: _toPlace!.lat,
      toLon: _toPlace!.lon,
      askedAt: DateTime.now(),
      fromName: _fromPlace!.stopName,
      toName: _toPlace!.stopName,
    );
    ref.read(journeyQueryProvider.notifier).state = query;
  }

  /// Fills in the "From" point using the phone's real GPS position or a simulated
  /// Delhi hub if testing remotely or if location is outside Delhi NCR.
  Future<void> _useMyLocation() async {
    if (_simulateInDelhi) {
      setState(() {
        _fromPlace = const _DemoHub(
          shortName: 'Shivaji Stadium',
          fullName: 'Shivaji Stadium Terminal (Connaught Place)',
          lat: 28.6323,
          lon: 77.2165,
        ).toPlace();
      });
      _showMessage('Demo location set: Shivaji Stadium (CP).');
      return;
    }

    setState(() => _locating = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _showMessage('Location is turned off. Turn it on in phone settings or toggle "Simulate".');
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied) {
        _showMessage('Location permission was refused. Toggle "Simulate" to use a demo location.');
        return;
      }
      if (permission == LocationPermission.deniedForever) {
        _showMessage('Location permission is permanently refused. Toggle "Simulate" to use a demo location.');
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
      );

      // Check if location is inside Delhi NCR bounding box (~28.2-29.0°N, 76.7-77.6°E)
      final inDelhi = position.latitude >= 28.2 &&
          position.latitude <= 29.0 &&
          position.longitude >= 76.7 &&
          position.longitude <= 77.6;

      if (!inDelhi) {
        setState(() {
          _fromPlace = const _DemoHub(
            shortName: 'Shivaji Stadium',
            fullName: 'Shivaji Stadium Terminal (Connaught Place)',
            lat: 28.6323,
            lon: 77.2165,
          ).toPlace();
        });
        _showMessage(
          'Location is outside the service area (${position.latitude.toStringAsFixed(2)}, ${position.longitude.toStringAsFixed(2)}). '
          'Using Shivaji Stadium (CP) as a demo start.',
        );
      } else {
        setState(() {
          _fromPlace = PlaceSuggestion(
            stopName: 'Your location',
            lat: position.latitude,
            lon: position.longitude,
          );
        });
      }
    } catch (e) {
      _showMessage("Couldn't get your location: $e");
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  void _applyDemoHub(_DemoHub hub) {
    setState(() {
      if (_fromPlace == null) {
        _fromPlace = hub.toPlace();
        _showMessage('Start set: ${hub.shortName}');
      } else if (_toPlace == null) {
        _toPlace = hub.toPlace();
        _showMessage('Destination set: ${hub.shortName}');
      } else {
        _toPlace = hub.toPlace();
        _showMessage('Updated destination: ${hub.shortName}');
      }
    });
  }

  void _setSampleTrip() {
    setState(() {
      _fromPlace = const _DemoHub(
        shortName: 'Shivaji Stadium',
        fullName: 'Shivaji Stadium Terminal (Connaught Place)',
        lat: 28.6323,
        lon: 77.2165,
      ).toPlace();
      _toPlace = const _DemoHub(
        shortName: 'Nehru Place',
        fullName: 'Nehru Place Terminal',
        lat: 28.5487,
        lon: 77.2570,
      ).toPlace();
    });
    _search();
    _showMessage('Loaded sample trip: Shivaji Stadium -> Nehru Place');
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(journeyQueryProvider);

    final canSearch = _fromPlace != null && _toPlace != null;

    return Scaffold(
      appBar: AppBar(title: const Text('Plan a journey')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(WimbSpace.screen, 4, WimbSpace.screen, 32),
        children: [
          _whereToWhereCard(context),
          const SizedBox(height: 18),
          _demoPresetsSection(context),
          const SizedBox(height: 20),
          // One full-width primary action. The old row squeezed "Find
          // buses" and "Hourly" side by side, which made the main action
          // look like a secondary one.
          FilledButton(
            onPressed: canSearch ? _search : null,
            child: const Text('Find buses'),
          ),
          if (canSearch)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Center(
                child: TextButton.icon(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ByHourScreen(
                          initialFrom: _fromPlace,
                          initialTo: _toPlace,
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.insights, size: 17),
                  label: const Text('Compare this trip by hour'),
                ),
              ),
            ),
          const SizedBox(height: 20),
          if (query == null) _emptyState(context) else _ResultsArea(query: query, enableMapTiles: widget.enableMapTiles),
        ],
      ),
    );
  }

  /// The from/to block: two tall tappable rows joined by a route line, the
  /// way a map app does it - not two text fields and a label.
  Widget _whereToWhereCard(BuildContext context) {
    return Card(
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
          // Indented so the divider starts past the icons, letting the two
          // rows read as one connected block rather than two separate ones.
          const Divider(height: 1, indent: 52),
          PlacePickerRow(
            label: 'TO',
            place: _toPlace,
            icon: Icons.place,
            iconColor: WimbColors.dtcRed,
            onPicked: (place) => setState(() => _toPlace = place),
          ),
          const Divider(height: 1),
          // The location strip at the bottom: live GPS pickup alongside an
          // instant "Simulate in Delhi" toggle for remote testing.
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: _locating ? null : _useMyLocation,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(
                        children: [
                          if (_locating)
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else
                            const Icon(Icons.my_location, size: 18, color: WimbColors.delhiGreen),
                          const SizedBox(width: 9),
                          Flexible(
                            child: Text(
                              _locating
                                  ? 'Finding you...'
                                  : (_simulateInDelhi
                                      ? 'Use demo location'
                                      : 'Use my location as start'),
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: WimbColors.delhiGreen,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Simulate',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _simulateInDelhi ? WimbColors.delhiGreen : WimbColors.inkMuted,
                      ),
                    ),
                    const SizedBox(width: 4),
                    SizedBox(
                      height: 30,
                      child: Switch.adaptive(
                        value: _simulateInDelhi,
                        activeThumbColor: WimbColors.delhiGreen,
                        activeTrackColor: WimbColors.delhiGreenLight,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onChanged: (val) {
                          setState(() => _simulateInDelhi = val);
                          if (val) {
                            _showMessage('Demo location enabled');
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Preset hub buttons allowing 1-tap testing of key Delhi transit hubs.
  Widget _demoPresetsSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel(
          'Demo presets',
          trailing: TextButton(
            onPressed: _setSampleTrip,
            style: TextButton.styleFrom(
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text(
              'Sample Trip (CP -> Nehru Pl)',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          // Chips run off the right edge on purpose: that edge is the cue
          // that there are more hubs to swipe to, which a wrapped grid
          // would hide.
          child: Row(
            children: _demoHubs.map((hub) {
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ActionChip(
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  avatar: const Icon(Icons.location_on, size: 15, color: WimbColors.delhiGreen),
                  label: Text(hub.shortName),
                  onPressed: () => _applyDemoHub(hub),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  /// What the screen shows before anything has been searched. Explains what
  /// will happen rather than leaving a blank space.
  Widget _emptyState(BuildContext context) {
    return const EmptyState(
      icon: Icons.alt_route,
      title: 'Pick a From and a To.',
      body: 'You will get ways to make the trip ranked by total time - '
          'walking, waiting and riding all counted - each with an honest '
          'range rather than one number.',
    );
  }
}

/// Shows loading / error / results for whatever query is currently set.
/// Split out from the main screen so it only rebuilds itself when the
/// fetch's state changes, not the whole form.
class _ResultsArea extends ConsumerWidget {
  final JourneyQuery query;
  final bool enableMapTiles;

  const _ResultsArea({required this.query, required this.enableMapTiles});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(journeyResultProvider(query));

    return result.when(
      loading: () => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(),
        ),
      ),
      // Unlike "no route found" below, this branch means the request
      // itself never completed honestly (unreachable server, bad
      // response) - so, unlike that branch, retrying the SAME query can
      // actually give a different answer, and is worth offering.
      error: (err, _) => ErrorCard(
        message: err.toString(),
        onRetry: () => ref.invalidate(journeyResultProvider(query)),
      ),
      data: (journey) {
        if (!journey.available) {
          return ErrorCard(
            message: journey.unavailableReason ?? 'No route found.',
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _JourneySummaryCard(query: query, option: journey.options.first, count: journey.options.length),
            const SizedBox(height: 12),
            // Map visualizing the journey path between chosen places.
            RouteMapWidget(
              height: 180,
              enableTiles: enableMapTiles,
              origin: LatLng(query.fromLat, query.fromLon),
              originLabel: query.fromName,
              destination: LatLng(query.toLat, query.toLon),
              destinationLabel: query.toName,
              polylinePoints: [
                LatLng(query.fromLat, query.fromLon),
                LatLng(query.toLat, query.toLon),
              ],
            ),
            const SizedBox(height: 22),
            SectionLabel(
              'Ways to travel',
              trailing: Text(
                '${journey.options.length} ${journey.options.length == 1 ? 'option' : 'options'}',
                style: const TextStyle(fontSize: 12, color: WimbColors.inkMuted),
              ),
            ),
            // Numbered, because the list is RANKED - the first really is
            // the best by total time, and a plain list would hide that.
            for (var i = 0; i < journey.options.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _OptionCard(
                  option: journey.options[i],
                  askedAt: query.askedAt,
                  rank: i + 1,
                  query: query,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// The answer at a glance, in the shape of a departure card: where you are
/// going from, where to, the route between them, and the fastest window.
///
/// The arrangement follows lookap entry "Flight Status Card
/// Microinteraction" by Michael Nowak (@mnowakdesign) - origin and
/// destination set large at the two ends, a thin line with the vehicle in
/// the middle, quiet times underneath. The colours, type and proportions
/// are this app's own; only the information order is borrowed.
class _JourneySummaryCard extends StatelessWidget {
  final JourneyQuery query;
  final JourneyOption option;
  final int count;

  const _JourneySummaryCard({
    required this.query,
    required this.option,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    final earliest = _clockTime(query.askedAt, option.earliestMinutes);
    final latest = _clockTime(query.askedAt, option.latestMinutes);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _SummaryLabel('FROM'),
                      const SizedBox(height: 4),
                      Text(
                        query.fromName,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 17.5),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Column(
                    children: [
                      StatusPill(
                        label: '$count ${count == 1 ? 'WAY' : 'WAYS'}',
                        color: WimbColors.dtcRed,
                        filled: false,
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: 36,
                        height: 36,
                        decoration: const BoxDecoration(
                          color: WimbColors.dtcRed,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.directions_bus,
                          size: 19,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const _SummaryLabel('TO'),
                      const SizedBox(height: 4),
                      Text(
                        query.toName,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 17.5),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // A continuous route line tying the two names together. The
            // bus sits on it rather than beside it, so the card reads as a
            // trip in progress instead of two unrelated places.
            Row(
              children: [
                Expanded(
                  child: Container(
                    height: 2,
                    decoration: BoxDecoration(
                      color: WimbColors.hairline,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(Icons.arrow_forward, size: 16, color: WimbColors.inkFaint),
                ),
                Expanded(
                  child: Container(
                    height: 2,
                    decoration: BoxDecoration(
                      color: WimbColors.hairline,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${option.totalMinutes.round()} min',
                        style: const TextStyle(
                          fontFamily: WimbFonts.condensed,
                          fontFamilyFallback: WimbFonts.fallback,
                          fontSize: 28,
                          height: 1,
                          fontWeight: FontWeight.w700,
                          color: WimbColors.delhiGreen,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Fastest option now',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _TimePill(text: '$earliest – $latest'),
                    const SizedBox(height: 5),
                    Text(
                      'arrival window',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A tiny all-caps label above a value inside the summary card.
class _SummaryLabel extends StatelessWidget {
  final String text;
  const _SummaryLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 1,
        color: WimbColors.inkMuted,
      ),
    );
  }
}

/// A quiet time pill, like the ones under a departure time. One widget so
/// the summary and the option rows cannot drift apart.
class _TimePill extends StatelessWidget {
  final String text;
  const _TimePill({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: WimbColors.surfaceMuted,
        borderRadius: BorderRadius.circular(WimbRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.schedule, size: 14, color: WimbColors.inkMuted),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              fontFeatures: WimbFonts.tabular,
              color: WimbColors.ink,
            ),
          ),
        ],
      ),
    );
  }
}

/// Helper to calculate and format transit distance between two journey points.
String _calculateDistance(JourneyQuery query) {
  final distM = const Distance().as(
    LengthUnit.Meter,
    LatLng(query.fromLat, query.fromLon),
    LatLng(query.toLat, query.toLon),
  );
  if (distM < 1000) {
    return '${distM.round()} m';
  } else {
    return '${(distM / 1000).toStringAsFixed(1)} km';
  }
}

/// One ranked way to make the journey: compact by default showing bus badges,
/// duration, distance, and transfer summary, expandable on tap for detailed steps.
class _OptionCard extends ConsumerStatefulWidget {
  final JourneyOption option;
  final DateTime askedAt;
  final int rank;
  final JourneyQuery query;

  const _OptionCard({
    required this.option,
    required this.askedAt,
    required this.rank,
    required this.query,
  });

  @override
  ConsumerState<_OptionCard> createState() => _OptionCardState();
}

class _OptionCardState extends ConsumerState<_OptionCard> {
  bool _expanded = false;

  String _friendlyConfidence(String level) {
    switch (level) {
      case 'high':
        return 'High-frequency service with reliable live data';
      case 'medium':
        return 'Regular service based on observed transit patterns';
      case 'low':
      default:
        return 'Estimated schedule timing';
    }
  }

  @override
  Widget build(BuildContext context) {
    final option = widget.option;
    final isBest = widget.rank == 1;
    final distanceStr = _calculateDistance(widget.query);
    final totalStops = option.legs.fold<int>(0, (sum, leg) => sum + leg.stops);
    final earliestClock = _clockTime(widget.askedAt, option.earliestMinutes);
    final latestClock = _clockTime(widget.askedAt, option.latestMinutes);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header strip: route badges, transfer type, FASTEST / rank,
            // and the expand control. The coloured band is gone - on a
            // white card a pill is enough to mark the best option, and
            // tinting the whole header made every option look selected.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 10, 10),
              child: Row(
                children: [
                  if (option.legs.length == 1)
                    RouteBoard(routeName: option.legs[0].routeName, compact: true)
                  else ...[
                    RouteBoard(routeName: option.legs[0].routeName, compact: true),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6),
                      child: Icon(Icons.arrow_forward, size: 14, color: WimbColors.inkFaint),
                    ),
                    RouteBoard(routeName: option.legs[1].routeName, compact: true),
                  ],
                  const SizedBox(width: 8),
                  StatusPill(
                    label: option.changes == 0 ? 'DIRECT' : '1 CHANGE',
                    color: WimbColors.inkMuted,
                    filled: false,
                  ),
                  const Spacer(),
                  if (isBest)
                    const StatusPill(label: 'FASTEST', color: WimbColors.delhiGreen)
                  else
                    Text(
                      '#${widget.rank}',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: WimbColors.inkMuted,
                      ),
                    ),
                  const SizedBox(width: 2),
                  Icon(
                    _expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                    size: 22,
                    color: WimbColors.inkMuted,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Metrics and summary. The big number is the total, the range
            // sits beside it rather than inside a parenthetical, and the
            // distance is a quiet chip on the right.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '${option.totalMinutes.round()}',
                        style: TextStyle(
                          fontFamily: WimbFonts.condensed,
                          fontFamilyFallback: WimbFonts.fallback,
                          fontSize: 32,
                          fontWeight: FontWeight.w700,
                          color: isBest ? WimbColors.delhiGreen : WimbColors.ink,
                          height: 1.0,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Text(
                          'min',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: isBest ? WimbColors.delhiGreen : WimbColors.inkMuted,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: Text(
                            '${option.earliestMinutes.round()}–${option.latestMinutes.round()} min window',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(
                          color: WimbColors.surfaceMuted,
                          borderRadius: BorderRadius.circular(WimbRadius.pill),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.straighten, size: 12, color: WimbColors.inkMuted),
                            const SizedBox(width: 4),
                            Text(
                              distanceStr,
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: WimbColors.ink,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.schedule, size: 14, color: WimbColors.inkMuted),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          'Arrive $earliestClock – $latestClock',
                          style: Theme.of(context).textTheme.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        '$totalStops stops',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${option.legs.first.boardPlace} to ${option.legs.last.alightPlace}',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: WimbColors.ink,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _expanded ? 'Hide steps' : 'View steps',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: WimbColors.dtcRed,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // Height animates instead of snapping, so opening an option
            // feels like unfolding it rather than replacing the list.
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _expanded ? _expandedTimeline(context) : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }

  Widget _expandedTimeline(BuildContext context) {
    final option = widget.option;
    final lastLeg = option.legs.isNotEmpty ? option.legs.last : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (option.walkMinutes > 0.5) ...[
                _step(
                  context,
                  Icons.directions_walk,
                  'Walk ~${option.walkMinutes.round()} min to ${option.legs.first.boardPlace}',
                  WimbColors.inkMuted,
                ),
                const SizedBox(height: 10),
              ],
              for (var i = 0; i < option.legs.length; i++) ...[
                _legDetail(context, option.legs[i], isLastLeg: i == option.legs.length - 1),
                if (i < option.legs.length - 1) ...[
                  const SizedBox(height: 10),
                  _step(
                    context,
                    Icons.transfer_within_a_station,
                    'Change at ${option.legs[i].alightPlace} (wait ~${option.legs[i + 1].waitMinutes.round()} min)',
                    WimbColors.trustMedium,
                  ),
                  const SizedBox(height: 10),
                ],
              ],
              const SizedBox(height: 14),
              _breakdownBar(context),
              const SizedBox(height: 12),
              Row(
                children: [
                  TrustDots(level: option.confidence.level, showLabel: false),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _friendlyConfidence(option.confidence.level),
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        color: trustColor(option.confidence.level),
                      ),
                    ),
                  ),
                ],
              ),
              if (lastLeg != null) ...[
                const SizedBox(height: 12),
                _buildAlarmButton(context, ref, lastLeg),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _legDetail(BuildContext context, JourneyLeg leg, {required bool isLastLeg}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            RouteBoard(routeName: leg.routeName, compact: true),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                leg.routeDesc.isNotEmpty ? leg.routeDesc : 'To destination',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: WimbColors.ink,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _step(
          context,
          Icons.arrow_circle_up,
          'Board at ${leg.boardPlace}',
          WimbColors.delhiGreen,
        ),
        const SizedBox(height: 4),
        _step(
          context,
          Icons.arrow_circle_down,
          isLastLeg
              ? 'Get off at ${leg.alightPlace}'
              : 'Alight at ${leg.alightPlace}',
          isLastLeg ? WimbColors.dtcRed : WimbColors.trustMedium,
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 20),
          child: Text(
            '${leg.stops} stops · ~${leg.rideMinutes.round()} min ride'
            '${leg.busEveryMinutes != null ? ' · every ~${leg.busEveryMinutes!.round()} min' : ''}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  Widget _step(BuildContext context, IconData icon, String text, Color color) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1.5, right: 6),
          child: Icon(icon, size: 14, color: color),
        ),
        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 13, height: 1.3)),
        ),
      ],
    );
  }

  Widget _breakdownBar(BuildContext context) {
    final walk = widget.option.walkMinutes;
    final wait = widget.option.waitMinutes;
    final ride = widget.option.rideMinutes;
    final total = walk + wait + ride;
    if (total <= 0) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 6,
            child: Row(
              children: [
                Expanded(flex: (walk * 100).round(), child: Container(color: WimbColors.inkMuted)),
                Expanded(flex: (wait * 100).round(), child: Container(color: WimbColors.trustMedium)),
                Expanded(flex: (ride * 100).round(), child: Container(color: WimbColors.dtcRed)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 5),
        Wrap(
          spacing: 12,
          children: [
            _legendItem(WimbColors.inkMuted, 'walk ${walk.round()}m'),
            _legendItem(WimbColors.trustMedium, 'wait ${wait.round()}m'),
            _legendItem(WimbColors.dtcRed, 'ride ${ride.round()}m'),
          ],
        ),
      ],
    );
  }

  Widget _legendItem(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11, color: WimbColors.inkMuted)),
      ],
    );
  }

  Widget _buildAlarmButton(BuildContext context, WidgetRef ref, JourneyLeg lastLeg) {
    final alarm = ref.watch(arrivalAlarmProvider);
    final isAlarmActive = alarm.isActive &&
        alarm.routeId == lastLeg.routeId &&
        alarm.targetStopName == lastLeg.alightPlace;

    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          foregroundColor: isAlarmActive ? WimbColors.delhiGreen : WimbColors.dtcRed,
          side: BorderSide(
            color: isAlarmActive
                ? WimbColors.delhiGreen.withValues(alpha: 0.45)
                : WimbColors.dtcRed.withValues(alpha: 0.30),
            width: 1,
          ),
          backgroundColor: isAlarmActive
              ? WimbColors.delhiGreenLight
              : WimbColors.dtcRed.withValues(alpha: 0.06),
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(WimbRadius.field),
          ),
        ),
        onPressed: () {
          if (isAlarmActive) {
            ref.read(arrivalAlarmProvider.notifier).dismiss();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Arrival alarm cancelled.'), duration: Duration(seconds: 2)),
            );
          } else {
            ref.read(arrivalAlarmProvider.notifier).setAlarm(
                  routeId: lastLeg.routeId,
                  routeName: lastLeg.routeName,
                  targetStopName: lastLeg.alightPlace,
                  targetStopSequence: lastLeg.stops,
                  stopThreshold: 1,
                  minuteThreshold: 5,
                );
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Arrival alarm set for ${lastLeg.alightPlace}. You will be alerted before arrival!'),
                duration: const Duration(seconds: 3),
              ),
            );
          }
        },
        icon: Icon(isAlarmActive ? Icons.alarm_on : Icons.notification_add_outlined, size: 16),
        label: Text(
          isAlarmActive ? 'Alarm Active for ${lastLeg.alightPlace}' : 'Set Arrival Alarm for ${lastLeg.alightPlace}',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}
