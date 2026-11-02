// Browse routes by number and see their stop sequence.
//
// AGENTS.md priority #5 ("route and schedule information"). This is the
// honest complement to the journey planner: journey_screen.dart answers
// "how do I get from A to B", this answers "where does bus 764 actually
// go" - useful on its own, and it's also how someone would find their own
// stop's position number for /eta, once that's wired into the app.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';
import 'arrival_alarm_service.dart';
import 'error_card.dart';
import 'popular_routes.dart';
import 'route_map_widget.dart';
import 'theme.dart';
import 'package:latlong2/latlong.dart';

/// Fetches the stop list for whatever route is currently open. `.family`
/// keys the cache by routeId; `.autoDispose` drops it once the detail
/// screen is closed, same reasoning as journey_screen.dart's provider.
final routeStopsProvider = FutureProvider.autoDispose
    .family<List<RouteStop>, String>((ref, routeId) => fetchRouteStops(routeId));

class RoutesScreen extends StatefulWidget {
  const RoutesScreen({super.key});

  @override
  State<RoutesScreen> createState() => _RoutesScreenState();
}

class _RoutesScreenState extends State<RoutesScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<RouteSuggestion> _results = [];
  bool _searching = false;
  // Distinguishes "haven't searched yet" from "searched, found nothing" -
  // the two need different empty-state messages.
  bool _hasSearched = false;

  @override
  void dispose() {
    _controller.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    if (text.trim().isEmpty) {
      setState(() {
        _results = [];
        _hasSearched = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      setState(() => _searching = true);
      final results = await searchRoutes(text);
      if (!mounted) return;
      setState(() {
        _results = results;
        _searching = false;
        _hasSearched = true;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Routes')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(WimbSpace.screen, 0, WimbSpace.screen, 14),
            child: TextField(
              controller: _controller,
              // hintText, NOT labelText. A floating label on a filled box
              // rises out of the field and sits above it in accent red,
              // which is what made this look broken in the screenshot.
              decoration: InputDecoration(
                hintText: 'Route number, e.g. 764',
                prefixIcon: const Icon(Icons.search, color: WimbColors.inkMuted, size: 21),
                suffixIcon: _searching
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: SizedBox(
                          width: 17,
                          height: 17,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : null,
              ),
              onChanged: _onChanged,
            ),
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (!_hasSearched) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(WimbSpace.screen, 4, WimbSpace.screen, 28),
        children: [
          const SectionLabel('Popular transit routes'),
          ...popularRoutes.map(_routeCard),
        ],
      );
    }
    if (_results.isEmpty) {
      return const EmptyState(
        icon: Icons.search_off,
        title: 'No route matches that number',
        body: 'Route numbers often carry a letter, like 764B or 764STL. '
            'Try just the digits.',
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(WimbSpace.screen, 4, WimbSpace.screen, 28),
      itemCount: _results.length,
      separatorBuilder: (_, _) => const SizedBox(height: WimbSpace.card),
      itemBuilder: (context, i) => _routeCard(_results[i]),
    );
  }

  /// One route in a list. The board sits on its own line rather than beside
  /// the description: side by side it was squeezed into about a third of
  /// the width and every route came out truncated, which defeats the point
  /// of showing the number at all.
  Widget _routeCard(RouteSuggestion route) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => RouteStopsScreen(route: route)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: RouteBoard(routeName: route.routeShortName),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      route.routeDesc.isEmpty
                          ? 'Route ${route.routeShortName}'
                          : route.routeDesc,
                      // Delhi's route descriptions run long. Two lines is
                      // enough to tell two routes apart.
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13.5, height: 1.35),
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 4, left: 8),
                child: Icon(Icons.chevron_right, size: 22, color: WimbColors.inkFaint),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Which two stops on a route an ETA is being asked about - "from" is where
/// the bus is assumed to be right now, "to" is where the rider is waiting.
/// Both are stop_sequence positions, not stop_ids (see [fetchEta]).
class _EtaQuery {
  final String routeId;
  final int from;
  final int to;
  final String? routeName;
  final String? toStopName;

  const _EtaQuery({
    required this.routeId,
    required this.from,
    required this.to,
    this.routeName,
    this.toStopName,
  });

  @override
  bool operator ==(Object other) =>
      other is _EtaQuery &&
      other.routeId == routeId &&
      other.from == from &&
      other.to == to;

  @override
  int get hashCode => Object.hash(routeId, from, to);
}

final _etaResultProvider =
    FutureProvider.autoDispose.family<EtaResult, _EtaQuery>((ref, query) {
  return fetchEta(routeId: query.routeId, from: query.from, to: query.to);
});

/// The ordered stop list for one route, once someone taps it from search.
/// Also where AGENTS.md priority #1 ("buses arriving at this stop, with
/// ETA") actually happens: tap the stop the bus is at, then the stop
/// you're waiting at, and /eta answers with a range, never a bare number.
class RouteStopsScreen extends ConsumerStatefulWidget {
  final RouteSuggestion route;
  const RouteStopsScreen({super.key, required this.route});

  @override
  ConsumerState<RouteStopsScreen> createState() => _RouteStopsScreenState();
}

class _RouteStopsScreenState extends ConsumerState<RouteStopsScreen> {
  // Both null: nothing picked yet. Only _fromSeq set: waiting for the
  // second tap. Both set: an ETA is being shown for this pair.
  int? _fromSeq;
  int? _toSeq;

  bool _showMap = true;
  bool _imOnThisBus = false;
  int _simStep = 0;
  Timer? _pollTimer;
  Timer? _beaconTimer;
  List<CrowdsourcedVehicleClient> _crowdsourcedVehicles = [];

  @override
  void initState() {
    super.initState();
    _refreshCrowdsourced();
    _pollTimer = Timer.periodic(const Duration(seconds: 10), (_) => _refreshCrowdsourced());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _beaconTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshCrowdsourced() async {
    final vehicles = await fetchCrowdsourcedVehicles(widget.route.routeId);
    if (mounted) {
      setState(() => _crowdsourcedVehicles = vehicles);
    }
  }

  void _toggleImOnThisBus(bool val, List<RouteStop> stops) {
    setState(() => _imOnThisBus = val);
    _beaconTimer?.cancel();
    if (val) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("I'm On This Bus enabled: Broadcasting anonymous transit telemetry."),
          duration: Duration(seconds: 3),
        ),
      );
      _broadcastBeacon(stops);
      _beaconTimer = Timer.periodic(const Duration(seconds: 8), (_) => _broadcastBeacon(stops));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Stopped broadcasting telemetry."),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _broadcastBeacon(List<RouteStop> stops) async {
    if (stops.isEmpty) return;
    final validStops = stops.where((s) => s.lat != null && s.lon != null).toList();
    if (validStops.isEmpty) return;

    final stop = validStops[_simStep % validStops.length];
    _simStep++;
    final lat = stop.lat!;
    final lon = stop.lon!;

    final ok = await sendPassengerBeacon(
      routeId: widget.route.routeId,
      lat: lat,
      lon: lon,
      speedKmh: 22.0,
      deviceId: 'mobile-rider',
    );
    if (ok) {
      await _refreshCrowdsourced();
    }
  }

  void _handleTap(RouteStop stop) {
    setState(() {
      if (_fromSeq == null) {
        _fromSeq = stop.stopSequence;
      } else if (_toSeq == null) {
        if (stop.stopSequence == _fromSeq) {
          // Tapped the same stop again - treat it as "never mind".
          _fromSeq = null;
        } else if (stop.stopSequence < _fromSeq!) {
          // A bus only moves forward along its route, so if the second
          // tap is earlier than the first, the rider picked them
          // backwards - swap rather than send /eta a pair it will refuse.
          _toSeq = _fromSeq;
          _fromSeq = stop.stopSequence;
        } else {
          _toSeq = stop.stopSequence;
        }
      } else {
        // Both already picked - a fresh tap starts a new estimate.
        _fromSeq = stop.stopSequence;
        _toSeq = null;
      }
    });
  }

  void _clear() => setState(() {
        _fromSeq = null;
        _toSeq = null;
      });

  String get _instruction {
    if (_fromSeq == null) return 'Tap the stop the bus is at right now.';
    if (_toSeq == null) return "Now tap the stop where you're waiting.";
    return 'Tap any stop to start a new estimate.';
  }

  @override
  Widget build(BuildContext context) {
    final stops = ref.watch(routeStopsProvider(widget.route.routeId));

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.route.routeShortName.toUpperCase()),
        actions: [
          if (_fromSeq != null)
            IconButton(
              onPressed: _clear,
              icon: const Icon(Icons.close),
              tooltip: 'Clear selection',
            ),
        ],
      ),
      // ONE scroll for the whole page.
      //
      // This used to be a Column with the board, the prompt and the
      // estimate pinned at the top and only the stop list scrolling
      // underneath them. On a long route that left very little of the
      // screen actually moving, and once an estimate appeared it ate a
      // third of the display and would not go away. As slivers, everything
      // scrolls together - the estimate scrolls off as you move down the
      // stops, and comes back when you scroll up.
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The route's own destination board, on the canvas rather
                // than on a slab of red.
                Padding(
                  padding: const EdgeInsets.fromLTRB(WimbSpace.screen, 0, WimbSpace.screen, 16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: RouteBoard(
                      routeName: widget.route.routeShortName,
                      destination: widget.route.routeDesc,
                    ),
                  ),
                ),

                // Tap two stops prompt
                Padding(
                  padding: const EdgeInsets.fromLTRB(WimbSpace.screen, 0, WimbSpace.screen, 12),
                  child: InfoBanner(
                    icon: _fromSeq == null ? Icons.touch_app : Icons.timer_outlined,
                    text: _instruction,
                  ),
                ),

                if (_fromSeq != null && _toSeq != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(WimbSpace.screen, 0, WimbSpace.screen, 12),
                    child: _EtaCard(
                      query: _EtaQuery(
                        routeId: widget.route.routeId,
                        routeName: widget.route.routeShortName,
                        from: _fromSeq!,
                        to: _toSeq!,
                        toStopName: stops.valueOrNull
                            ?.firstWhere(
                              (s) => s.stopSequence == _toSeq,
                              orElse: () => RouteStop(
                                stopSequence: _toSeq!,
                                stopName: 'Stop #$_toSeq',
                                metresAlongRoute: 0,
                                hasTiming: true,
                              ),
                            )
                            .stopName,
                      ),
                    ),
                  ),

                // Map & Crowdsourcing Controls
                if (stops.hasValue) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(WimbSpace.screen, 2, WimbSpace.screen, 2),
                    child: Row(
                      children: [
                        TextButton.icon(
                          onPressed: () => setState(() => _showMap = !_showMap),
                          icon: Icon(_showMap ? Icons.map_outlined : Icons.map, size: 17),
                          label: Text(_showMap ? 'Hide Map' : 'Show Route Map'),
                          style: TextButton.styleFrom(
                            foregroundColor: WimbColors.ink,
                            minimumSize: Size.zero,
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                        const Spacer(),
                        if (_crowdsourcedVehicles.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                            decoration: BoxDecoration(
                              color: WimbColors.delhiGreenLight,
                              borderRadius: BorderRadius.circular(WimbRadius.pill),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.wifi_tethering, size: 14, color: WimbColors.delhiGreen),
                                const SizedBox(width: 5),
                                Text(
                                  '${_crowdsourcedVehicles.length} active beacon(s)',
                                  style: const TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                    color: WimbColors.delhiGreen,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (_showMap)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(WimbSpace.screen, 8, WimbSpace.screen, 12),
                      child: RouteMapWidget(
                        height: 220,
                        stops: stops.value,
                        crowdsourcedVehicles: _crowdsourcedVehicles,
                        polylinePoints: (stops.value ?? [])
                            .where((s) => s.lat != null && s.lon != null)
                            .map((s) => LatLng(s.lat!, s.lon!))
                            .toList(),
                      ),
                    ),
                  // "I'm On This Bus" passenger crowdsourcing card.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(WimbSpace.screen, 2, WimbSpace.screen, 12),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                        child: Row(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: WimbColors.delhiGreenLight,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(
                                Icons.airline_seat_recline_normal,
                                color: WimbColors.delhiGreen,
                                size: 21,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    "I'm on this bus",
                                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _imOnThisBus
                                        ? 'Broadcasting GPS beacons (anonymous, low battery)'
                                        : 'Help waiting commuters track this bus',
                                    style: const TextStyle(fontSize: 11.5, color: WimbColors.inkMuted),
                                  ),
                                ],
                              ),
                            ),
                            Switch.adaptive(
                              value: _imOnThisBus,
                              activeThumbColor: WimbColors.delhiGreen,
                              activeTrackColor: WimbColors.delhiGreenLight,
                              onChanged: (val) => _toggleImOnThisBus(val, stops.value ?? []),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
              ],
            ),
          ),

          stops.when(
            loading: () => const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            ),
            // A route the search just returned failing to load its stops
            // is a real request failure (server unreachable, or it fell
            // out of the feed snapshot between search and tap) - unlike
            // an honest "no route found", trying again can genuinely
            // help, so it's always offered here.
            error: (err, _) => SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ErrorCard(
                  message: err.toString(),
                  onRetry: () => ref.invalidate(routeStopsProvider(widget.route.routeId)),
                ),
              ),
            ),
            data: (stopList) => SliverList.builder(
              itemCount: stopList.length,
              itemBuilder: (context, i) => _StopRow(
                stop: stopList[i],
                isFirst: i == 0,
                isLast: i == stopList.length - 1,
                isFrom: stopList[i].stopSequence == _fromSeq,
                isTo: stopList[i].stopSequence == _toSeq,
                // Between the two picked stops - the stretch the
                // estimate actually covers, shown so the answer and the
                // list agree with each other visually.
                isBetween: _fromSeq != null &&
                    _toSeq != null &&
                    stopList[i].stopSequence > _fromSeq! &&
                    stopList[i].stopSequence < _toSeq!,
                onTap: () => _handleTap(stopList[i]),
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 28)),
        ],
      ),
    );
  }
}

/// One stop, drawn as a station on a route line.
///
/// The vertical line with a dot on it is the standard way transit maps
/// show a sequence of stops, and it makes the order obvious in a way a
/// plain list of names does not - particularly once two stops are picked
/// and the stretch between them is highlighted.
class _StopRow extends StatelessWidget {
  final RouteStop stop;
  final bool isFirst;
  final bool isLast;
  final bool isFrom;
  final bool isTo;
  final bool isBetween;
  final VoidCallback onTap;

  const _StopRow({
    required this.stop,
    required this.isFirst,
    required this.isLast,
    required this.isFrom,
    required this.isTo,
    required this.isBetween,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final highlighted = isFrom || isTo;
    // The line is drawn thicker and in full colour along the stretch the
    // estimate covers, and faint everywhere else.
    final onEstimatedStretch = isFrom || isTo || isBetween;
    final lineColor = onEstimatedStretch ? WimbColors.dtcRed : WimbColors.hairline;

    return InkWell(
      onTap: onTap,
      child: Container(
        color: highlighted ? WimbColors.delhiGreenLight : null,
        padding: const EdgeInsets.symmetric(horizontal: WimbSpace.screen),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The route line and this stop's dot on it.
              SizedBox(
                width: 28,
                child: Column(
                  children: [
                    // No line above the first stop or below the last -
                    // the route starts and ends, it does not run off the
                    // top and bottom of the screen.
                    Expanded(
                      child: Container(
                        width: onEstimatedStretch ? 3 : 2,
                        color: isFirst ? Colors.transparent : lineColor,
                      ),
                    ),
                    _dot(),
                    Expanded(
                      child: Container(
                        width: onEstimatedStretch ? 3 : 2,
                        color: isLast ? Colors.transparent : lineColor,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        stop.stopName,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: highlighted ? FontWeight.w700 : FontWeight.w500,
                          // Dimmed when no bus was ever recorded arriving
                          // here, so the gap is visible before it becomes
                          // a refusal.
                          color: stop.hasTiming
                              ? WimbColors.ink
                              : WimbColors.inkMuted.withValues(alpha: 0.75),
                        ),
                      ),
                      if (isFrom || isTo)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            isFrom ? 'Bus is here' : "You're waiting here",
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: WimbColors.delhiGreen,
                            ),
                          ),
                        )
                      else if (!stop.hasTiming)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            'no recorded timing',
                            style: TextStyle(
                              fontSize: 11,
                              fontStyle: FontStyle.italic,
                              color: WimbColors.inkMuted.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  '${(stop.metresAlongRoute / 1000).toStringAsFixed(1)} km',
                  style: const TextStyle(
                    fontFeatures: WimbFonts.tabular,
                    fontSize: 12,
                    color: WimbColors.inkMuted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The dot on the line: a bus icon where the bus is, a person where the
  /// rider is, and a plain numbered circle everywhere else.
  Widget _dot() {
    if (isFrom || isTo) {
      return Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isFrom ? WimbColors.delhiGreen : WimbColors.dtcRed,
          border: Border.all(color: WimbColors.cream, width: 2.5),
        ),
        child: Icon(
          isFrom ? Icons.directions_bus : Icons.person_pin_circle,
          size: 13,
          color: Colors.white,
        ),
      );
    }
    return Container(
      width: 17,
      height: 17,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: WimbColors.cream,
        border: Border.all(
          color: isBetween ? WimbColors.dtcRed : WimbColors.hairline,
          width: 2,
        ),
      ),
      child: Text(
        '${stop.stopSequence}',
        style: const TextStyle(fontSize: 8, color: WimbColors.inkMuted, height: 1),
      ),
    );
  }
}

/// The ETA answer for one (from, to) pair - a range and a confidence label,
/// never a bare number, same honesty rule as journey_screen.dart.
class _EtaCard extends ConsumerWidget {
  final _EtaQuery query;
  const _EtaCard({required this.query});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(_etaResultProvider(query));

    return result.when(
      loading: () => const Card(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 26),
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (err, _) => ErrorCard(
        message: err.toString(),
        onRetry: () => ref.invalidate(_etaResultProvider(query)),
      ),
      data: (eta) {
        if (!eta.available) {
          // Honest refusal (e.g. these two legs have never been observed
          // together), not a request failure - no retry button, same
          // pattern as the "no route found" branches elsewhere in the app.
          return ErrorCard(
            message: eta.unavailableReason ?? 'No estimate available for this pair of stops.',
          );
        }

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SectionLabel('Journey time'),
                          // The range, big. Deliberately the range and not
                          // the single estimate - showing one number here
                          // would be exactly the dishonesty this project
                          // exists to correct.
                          Text(
                            eta.range.text,
                            style: const TextStyle(
                              fontFamily: WimbFonts.condensed,
                              fontFamilyFallback: WimbFonts.fallback,
                              fontSize: 36,
                              fontWeight: FontWeight.w700,
                              height: 1.0,
                              color: WimbColors.ink,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${eta.stopsAway} stop${eta.stopsAway == 1 ? '' : 's'} along the route',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: WimbColors.dtcRed.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(Icons.directions_bus_filled, size: 25, color: WimbColors.dtcRed),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                TrustDots(level: eta.confidence.level),
                const SizedBox(height: 6),
                Text(eta.confidence.because, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 14),
                const Divider(),
                const SizedBox(height: 12),
                ...eta.caveats.map((c) => CaveatLine(c)),
                const SizedBox(height: 12),
                _buildAlarmButton(context, ref, eta),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAlarmButton(BuildContext context, WidgetRef ref, EtaResult eta) {
    final alarm = ref.watch(arrivalAlarmProvider);
    final isAlarmActive = alarm.isActive &&
        alarm.routeId == query.routeId &&
        alarm.targetStopSequence == query.to;

    // Auto-evaluate when alarm is active for this route/stop
    if (isAlarmActive && !alarm.isTriggered && !alarm.isSnoozed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(arrivalAlarmProvider.notifier).evaluateProgress(
              currentStopSequence: query.from,
              stopsRemaining: eta.stopsAway,
              estimatedSecondsRemaining: eta.range.latestSeconds,
            );
      });
    }

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
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(WimbRadius.field),
          ),
        ),
        onPressed: () {
          if (isAlarmActive) {
            ref.read(arrivalAlarmProvider.notifier).dismiss();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Arrival alarm cancelled.'),
                duration: Duration(seconds: 2),
              ),
            );
          } else {
            ref.read(arrivalAlarmProvider.notifier).setAlarm(
                  routeId: query.routeId,
                  routeName: query.routeName ?? query.routeId,
                  targetStopName: query.toStopName ?? 'Stop #${query.to}',
                  targetStopSequence: query.to,
                  stopThreshold: 1,
                  minuteThreshold: 5,
                );
            ref.read(arrivalAlarmProvider.notifier).evaluateProgress(
                  currentStopSequence: query.from,
                  stopsRemaining: eta.stopsAway,
                  estimatedSecondsRemaining: eta.range.latestSeconds,
                );
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Arrival alarm set for ${query.toStopName ?? "destination"}. You will be alerted 1 stop before!',
                ),
                duration: const Duration(seconds: 3),
              ),
            );
          }
        },
        icon: Icon(
          isAlarmActive ? Icons.alarm_on : Icons.notification_add_outlined,
          size: 18,
        ),
        label: Text(
          isAlarmActive ? 'Alarm Active (Alerts 1 stop before)' : 'Set Arrival Alarm for Destination',
          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}
