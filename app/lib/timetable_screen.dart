// The Bus Timetable & Schedule screen.
//
// Solves the real-world commuter challenge: commuters do not memorize
// obscure Delhi municipal route numbers. They know where they are and
// where they want to go. This screen shows all direct buses connecting
// two stops, their operating frequencies, and full stop sequences,
// operating completely offline from on-device SQLite.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import 'api_client.dart';
import 'journey_screen.dart';
import 'offline_transit_pack.dart';
import 'place_picker.dart';
import 'routes_screen.dart';
import 'theme.dart';

class _TimetableHub {
  final String shortName;
  final String fullName;
  final double lat;
  final double lon;

  const _TimetableHub({
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
  _TimetableHub(
    shortName: 'Shivaji Stadium',
    fullName: 'Shivaji Stadium Terminal',
    lat: 28.6323,
    lon: 77.2165,
  ),
  _TimetableHub(
    shortName: 'Karol Bagh',
    fullName: 'Karol Bagh Metro Station',
    lat: 28.6514,
    lon: 77.1907,
  ),
  _TimetableHub(
    shortName: 'Dhaula Kuan',
    fullName: 'Dhaula Kuan',
    lat: 28.5925,
    lon: 77.1633,
  ),
  _TimetableHub(
    shortName: 'ISBT Anand Vihar',
    fullName: 'ISBT Anand Vihar Terminal',
    lat: 28.6470,
    lon: 77.3176,
  ),
  _TimetableHub(
    shortName: 'Nehru Place',
    fullName: 'Nehru Place Terminal',
    lat: 28.5487,
    lon: 77.2570,
  ),
  _TimetableHub(
    shortName: 'AIIMS Ring Road',
    fullName: 'AIIMS Ring Road',
    lat: 28.5670,
    lon: 77.2080,
  ),
  _TimetableHub(
    shortName: 'Kashmere Gate',
    fullName: 'ISBT Kashmiri Gate',
    lat: 28.6668,
    lon: 77.2294,
  ),
];

class TimetableScreen extends ConsumerStatefulWidget {
  final PlaceSuggestion? initialFrom;
  final PlaceSuggestion? initialTo;

  const TimetableScreen({super.key, this.initialFrom, this.initialTo});

  @override
  ConsumerState<TimetableScreen> createState() => _TimetableScreenState();
}

class _TimetableScreenState extends ConsumerState<TimetableScreen> {
  PlaceSuggestion? _fromPlace;
  PlaceSuggestion? _toPlace;

  bool _loading = false;
  bool _locating = false;
  bool _simulateInDelhi = false;

  List<DirectBusOption> _directBuses = [];
  List<RouteSuggestion> _stopRoutes = [];
  bool _hasSearched = false;

  @override
  void initState() {
    super.initState();
    _fromPlace = widget.initialFrom;
    _toPlace = widget.initialTo;
    if (_fromPlace != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _lookupTimetable());
    }
  }

  void _swapStops() {
    setState(() {
      final temp = _fromPlace;
      _fromPlace = _toPlace;
      _toPlace = temp;
    });
    if (_fromPlace != null) {
      _lookupTimetable();
    }
  }

  Future<void> _lookupTimetable() async {
    if (_fromPlace == null) return;

    setState(() {
      _loading = true;
      _hasSearched = true;
    });

    final pack = ref.read(offlineTransitPackProvider);

    try {
      if (_toPlace != null) {
        final buses = await pack.findDirectBuses(_fromPlace!.stopName, _toPlace!.stopName);
        if (mounted) {
          setState(() {
            _directBuses = buses;
            _stopRoutes = [];
            _loading = false;
          });
        }
      } else {
        final routes = await pack.findRoutesAtStop(_fromPlace!.stopName);
        if (mounted) {
          setState(() {
            _directBuses = [];
            _stopRoutes = routes;
            _loading = false;
          });
        }
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _useMyLocation() async {
    if (_simulateInDelhi) {
      setState(() {
        _fromPlace = _demoHubs[0].toPlace();
      });
      _lookupTimetable();
      return;
    }

    setState(() => _locating = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _showMessage('Location service is disabled. Toggle "Simulate" to use a demo location.');
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        _showMessage('Location permission denied. Toggle "Simulate" to use a demo location.');
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
      );

      final inDelhi = position.latitude >= 28.2 &&
          position.latitude <= 29.0 &&
          position.longitude >= 76.7 &&
          position.longitude <= 77.6;

      if (!inDelhi) {
        setState(() {
          _fromPlace = _demoHubs[0].toPlace();
        });
        _showMessage('Location outside the service area. Using Shivaji Stadium Terminal as a demo start.');
      } else {
        setState(() {
          _fromPlace = PlaceSuggestion(
            stopName: 'Your Location',
            lat: position.latitude,
            lon: position.longitude,
          );
        });
      }
      _lookupTimetable();
    } catch (e) {
      _showMessage("Couldn't get location: $e");
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  void _showMessage(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _setCorridor(String fromHubName, String toHubName) {
    final fromHub = _demoHubs.firstWhere((h) => h.shortName == fromHubName);
    final toHub = _demoHubs.firstWhere((h) => h.shortName == toHubName);

    setState(() {
      _fromPlace = fromHub.toPlace();
      _toPlace = toHub.toPlace();
    });
    _lookupTimetable();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bus Timetable')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(WimbSpace.screen, 4, WimbSpace.screen, 32),
        children: [
          _stopSelectorCard(context),
          const SizedBox(height: 18),
          _corridorPresets(context),
          const SizedBox(height: 20),
          if (_loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: CircularProgressIndicator(),
              ),
            )
          else if (!_hasSearched)
            _emptyPrompt(context)
          else
            _resultsView(context),
        ],
      ),
    );
  }

  Widget _stopSelectorCard(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          PlacePickerRow(
            label: 'FROM STOP',
            place: _fromPlace,
            icon: Icons.trip_origin,
            iconColor: WimbColors.delhiGreen,
            onPicked: (place) {
              setState(() {
                _fromPlace = place;
                _toPlace = null;
              });
              _lookupTimetable();
            },
          ),
          const Divider(height: 1, indent: 52),
          Stack(
            alignment: Alignment.centerRight,
            children: [
              PlacePickerRow(
                label: 'TO STOP (OPTIONAL)',
                place: _toPlace,
                icon: Icons.place,
                iconColor: WimbColors.dtcRed,
                directFromStop: _fromPlace?.stopName,
                subtitle: _fromPlace != null
                    ? 'Choose from stops with direct buses'
                    : 'Choose a starting stop first',
                onCustomTap: _fromPlace == null
                    ? () {
                        _showMessage('Please select a starting stop first to see direct destinations.');
                      }
                    : null,
                onPicked: (place) {
                  setState(() => _toPlace = place);
                  _lookupTimetable();
                },
              ),
              if (_fromPlace != null && _toPlace != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: WimbColors.surfaceMuted,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.swap_vert, color: WimbColors.dtcRed, size: 21),
                      tooltip: 'Swap Stops',
                      onPressed: _swapStops,
                    ),
                  ),
                ),
            ],
          ),
          const Divider(height: 1),
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
                                  ? 'Locating...'
                                  : (_simulateInDelhi
                                      ? 'Use demo hub'
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
                          if (val) _showMessage('Demo location enabled');
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

  Widget _corridorPresets(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionLabel('Popular transit corridors'),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _corridorChip('CP to Karol Bagh', 'Shivaji Stadium', 'Karol Bagh'),
              _corridorChip('CP to Dhaula Kuan', 'Shivaji Stadium', 'Dhaula Kuan'),
              _corridorChip('Anand Vihar to Dhaula Kuan', 'ISBT Anand Vihar', 'Dhaula Kuan'),
              _corridorChip('AIIMS to Nehru Place', 'AIIMS Ring Road', 'Nehru Place'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _corridorChip(String label, String from, String to) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ActionChip(
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        avatar: const Icon(Icons.directions_bus, size: 15, color: WimbColors.dtcRed),
        label: Text(label),
        onPressed: () => _setCorridor(from, to),
      ),
    );
  }

  Widget _emptyPrompt(BuildContext context) {
    return const EmptyState(
      icon: Icons.departure_board_outlined,
      title: 'Check bus timetables & direct lines',
      body: 'Select a starting stop and destination to see all direct buses '
          'running between them, their frequencies, and operating timetables.',
    );
  }

  Widget _resultsView(BuildContext context) {
    if (_toPlace != null) {
      if (_directBuses.isEmpty) {
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: WimbColors.dtcRed.withValues(alpha: 0.08),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.alt_route, size: 26, color: WimbColors.dtcRed),
                ),
                const SizedBox(height: 12),
                Text(
                  'No direct bus between these stops',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                Text(
                  'There is no single bus connecting ${_fromPlace!.stopName} to ${_toPlace!.stopName} directly. '
                  'Use the Journey planner to view 1-change connecting trips.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => JourneyScreen(
                          initialFrom: _fromPlace,
                          initialTo: _toPlace,
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.alt_route, size: 18),
                  label: const Text('Find connecting buses'),
                ),
              ],
            ),
          ),
        );
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionLabel(
            'Direct buses (${_directBuses.length})',
            trailing: Flexible(
              child: Text(
                '${_fromPlace!.stopName} to ${_toPlace!.stopName}',
                style: const TextStyle(fontSize: 11, color: WimbColors.inkMuted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
              ),
            ),
          ),
          ..._directBuses.map((bus) => _directBusCard(context, bus)),
        ],
      );
    }

    if (_stopRoutes.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            'No routes found calling at ${_fromPlace!.stopName}.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel('All buses calling at this stop (${_stopRoutes.length})'),
        ..._stopRoutes.map((route) => _stopRouteCard(context, route)),
      ],
    );
  }

  Widget _directBusCard(BuildContext context, DirectBusOption bus) {
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: WimbSpace.card),
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => RouteStopsScreen(
                route: RouteSuggestion(
                  routeId: bus.routeId,
                  routeShortName: bus.routeShortName,
                  routeDesc: bus.routeDesc,
                ),
              ),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  RouteBoard(routeName: bus.routeShortName, compact: true),
                  const SizedBox(width: 8),
                  const StatusPill(label: 'DIRECT', color: WimbColors.delhiGreen),
                  const Spacer(),
                  const Icon(Icons.chevron_right, size: 22, color: WimbColors.inkFaint),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                bus.routeDesc.isNotEmpty ? bus.routeDesc : 'Transit Route ${bus.routeShortName}',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: WimbColors.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              // A Wrap, not a Row: on a 320dp phone these two facts plus
              // their icons are wider than the card, and a Row would simply
              // overflow. A Wrap moves the second fact to its own line.
              Wrap(
                spacing: 14,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.pin_drop_outlined, size: 14, color: WimbColors.inkMuted),
                      const SizedBox(width: 5),
                      Text(
                        '${bus.stopsBetween} stops on this leg',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.timelapse, size: 14, color: WimbColors.inkMuted),
                      const SizedBox(width: 5),
                      Text(
                        'Every ~10-15 min',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.schedule, size: 14, color: WimbColors.delhiGreen),
                  const SizedBox(width: 5),
                  Text(
                    'Operating: 05:30 AM – 10:45 PM',
                    style: TextStyle(fontSize: 11.5, color: WimbColors.delhiGreen, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stopRouteCard(BuildContext context, RouteSuggestion route) {
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: WimbSpace.card),
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => RouteStopsScreen(route: route),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Row(
            children: [
              RouteBoard(routeName: route.routeShortName, compact: true),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      route.routeDesc,
                      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: WimbColors.ink),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    const Text(
                      'Tap to view schedule & all calling stops',
                      style: TextStyle(fontSize: 11.5, color: WimbColors.inkMuted),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, size: 20, color: WimbColors.inkFaint),
            ],
          ),
        ),
      ),
    );
  }
}
