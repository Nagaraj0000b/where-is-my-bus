// Choosing a place, the way a phone should do it.
//
// WHAT WAS WRONG BEFORE
//
// This used to be a text box with a floating label and a little dropdown
// of suggestions underneath - a web form, put on a phone. It had all the
// problems web forms have on a phone: the keyboard covered the
// suggestions, the tap targets were small, the label tore a gap through
// the border when it floated, and the whole screen sat there looking like
// something to fill in rather than something to use.
//
// WHAT IT DOES NOW
//
// The same pattern every map app on a phone uses: a big tappable ROW that
// says where you are going, and tapping it opens a FULL SCREEN search with
// the keyboard already up and the results filling everything below it.
// Nothing competes for space, the targets are large, and picking a result
// closes the page and hands the answer back.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';
import 'offline_transit_pack.dart';
import 'theme.dart';

/// Waits this long after the last keystroke before asking the backend, so
/// typing a whole word does not fire one request per letter.
const _debounceDelay = Duration(milliseconds: 300);

/// One tappable row in a "from here, to there" block.
///
/// Shows the chosen place, or a prompt when nothing is chosen yet. It is
/// not a text field at all - it only opens [PlaceSearchPage] and reports
/// back what came out of it.
class PlacePickerRow extends StatelessWidget {
  /// 'From' or 'To'. Used for the prompt and the search page's title.
  final String label;

  /// The place currently chosen, or null.
  final PlaceSuggestion? place;

  final ValueChanged<PlaceSuggestion> onPicked;

  /// Drawn to the left. A dot for the start, a pin for the destination.
  final IconData icon;
  final Color iconColor;

  /// When non-null, restricts search and recommendations strictly to valid
  /// destinations directly connected to this starting stop by bus.
  final String? directFromStop;

  /// Optional custom tap action (e.g. to guide user when From stop is not yet picked).
  final VoidCallback? onCustomTap;

  /// Optional subtitle hint displayed below the stop name.
  final String? subtitle;

  const PlacePickerRow({
    super.key,
    required this.label,
    required this.place,
    required this.onPicked,
    required this.icon,
    required this.iconColor,
    this.directFromStop,
    this.onCustomTap,
    this.subtitle,
  });

  Future<void> _openSearch(BuildContext context) async {
    if (onCustomTap != null) {
      onCustomTap!();
      return;
    }
    final picked = await Navigator.of(context).push<PlaceSuggestion>(
      MaterialPageRoute(
        builder: (_) => PlaceSearchPage(
          title: label,
          directFromStop: directFromStop,
        ),
      ),
    );
    if (picked != null) onPicked(picked);
  }

  @override
  Widget build(BuildContext context) {
    final chosen = place != null;

    return InkWell(
      onTap: () => _openSearch(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            // A tinted square behind the icon, rather than a bare glyph:
            // on a white card this is what tells the eye the whole row is
            // one control.
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(icon, size: 19, color: iconColor),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text(
                        label,
                        style: const TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1,
                          color: WimbColors.inkMuted,
                        ),
                      ),
                      if (directFromStop != null) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: WimbColors.delhiGreen.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(WimbRadius.pill),
                          ),
                          child: const Text(
                            'DIRECT ONLY',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                              color: WimbColors.delhiGreen,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    chosen ? place!.stopName : (subtitle ?? 'Choose a place'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: chosen ? FontWeight.w600 : FontWeight.w400,
                      color: chosen ? WimbColors.ink : WimbColors.inkFaint,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A full-screen place search. Opens with the keyboard up, results fill
/// the rest of the screen, and picking one pops the page returning it.
class PlaceSearchPage extends ConsumerStatefulWidget {
  /// 'From' or 'To' - only used to title the page.
  final String title;

  /// When non-null, restricts search and recommendations strictly to valid
  /// destinations directly connected to this starting stop by bus.
  final String? directFromStop;

  const PlaceSearchPage({
    super.key,
    required this.title,
    this.directFromStop,
  });

  @override
  ConsumerState<PlaceSearchPage> createState() => _PlaceSearchPageState();
}

class _PlaceSearchPageState extends ConsumerState<PlaceSearchPage> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<PlaceSuggestion> _results = [];
  List<DirectDestinationSuggestion> _directDestinations = [];
  bool _searching = false;
  bool _hasTyped = false;

  @override
  void initState() {
    super.initState();
    if (widget.directFromStop != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadDirectDestinations('');
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _loadDirectDestinations(String query) async {
    if (!mounted) return;
    setState(() => _searching = true);

    try {
      final pack = ref.read(offlineTransitPackProvider);
      final dests = await pack.findDirectDestinations(
        widget.directFromStop!,
        query: query,
        limit: 60,
      );
      if (mounted) {
        setState(() {
          _directDestinations = dests;
          _searching = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _onChanged(String text) {
    _debounce?.cancel();

    if (widget.directFromStop != null) {
      setState(() {
        _hasTyped = text.trim().isNotEmpty;
      });
      _debounce = Timer(_debounceDelay, () {
        _loadDirectDestinations(text.trim());
      });
      return;
    }

    if (text.trim().length < 2) {
      setState(() {
        _results = [];
        _hasTyped = text.trim().isNotEmpty;
        _searching = false;
      });
      return;
    }

    setState(() {
      _searching = true;
      _hasTyped = true;
    });

    _debounce = Timer(_debounceDelay, () async {
      final found = await searchPlaces(text);
      if (!mounted) return;
      setState(() {
        _results = found;
        _searching = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDirectMode = widget.directFromStop != null;

    return Scaffold(
      backgroundColor: WimbColors.cream,
      appBar: AppBar(
        title: Text(isDirectMode ? 'Direct Destinations' : widget.title),
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(isDirectMode ? 104 : 70),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(WimbSpace.screen, 0, WimbSpace.screen, 12),
                child: TextField(
                  controller: _controller,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  onChanged: _onChanged,
                  style: const TextStyle(fontSize: 16),
                  decoration: InputDecoration(
                    hintText: isDirectMode
                        ? 'Filter direct destinations...'
                        : 'Search stops and places',
                    prefixIcon: const Icon(Icons.search, color: WimbColors.inkMuted, size: 22),
                    suffixIcon: _clearOrSpinner(),
                  ),
                ),
              ),
              if (isDirectMode)
                Padding(
                  padding: const EdgeInsets.fromLTRB(WimbSpace.screen, 0, WimbSpace.screen, 10),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle_outline, size: 15, color: WimbColors.delhiGreen),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Showing valid stops reachable from ${widget.directFromStop}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: WimbColors.delhiGreen,
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
      body: _body(),
    );
  }

  Widget? _clearOrSpinner() {
    if (_searching) {
      return const Padding(
        padding: EdgeInsets.all(13),
        child: SizedBox(
          width: 17,
          height: 17,
          child: CircularProgressIndicator(strokeWidth: 2.2),
        ),
      );
    }
    if (_controller.text.isEmpty) return null;
    return IconButton(
      icon: const Icon(Icons.close, size: 19, color: WimbColors.inkMuted),
      onPressed: () {
        _controller.clear();
        _onChanged('');
      },
    );
  }

  static const _popularPlaces = [
    PlaceSuggestion(
      stopName: 'Shivaji Stadium Terminal',
      lat: 28.6315,
      lon: 77.2167,
    ),
    PlaceSuggestion(
      stopName: 'AIIMS Ring Road',
      lat: 28.5684,
      lon: 77.2084,
    ),
    PlaceSuggestion(
      stopName: 'Nehru Place Terminal',
      lat: 28.5521,
      lon: 77.2415,
    ),
    PlaceSuggestion(
      stopName: 'ISBT Kashmiri Gate',
      lat: 28.6675,
      lon: 77.2312,
    ),
    PlaceSuggestion(
      stopName: 'ISBT Anand Vihar Terminal',
      lat: 28.6475,
      lon: 77.3158,
    ),
    PlaceSuggestion(
      stopName: 'Dhaula Kuan',
      lat: 28.5925,
      lon: 77.1633,
    ),
    PlaceSuggestion(
      stopName: 'New Delhi Railway Station Gate 2',
      lat: 28.6430,
      lon: 77.2195,
    ),
    PlaceSuggestion(
      stopName: 'Mayur Vihar Phase-1',
      lat: 28.6083,
      lon: 77.2947,
    ),
    PlaceSuggestion(
      stopName: 'Saket Metro Station / Max Hospital',
      lat: 28.5204,
      lon: 77.2014,
    ),
    PlaceSuggestion(
      stopName: 'Dwarka Sector 10 Metro Station',
      lat: 28.5812,
      lon: 77.0583,
    ),
  ];

  Widget _body() {
    if (widget.directFromStop != null) {
      return _directDestinationsBody();
    }
    return _standardPlaceSearchBody();
  }

  Widget _directDestinationsBody() {
    if (_directDestinations.isEmpty && !_searching) {
      final query = _controller.text.trim();
      return EmptyState(
        icon: Icons.alt_route,
        title: query.isEmpty ? 'No direct destinations found' : 'No direct bus to "$query"',
        body: query.isEmpty
            ? 'No direct bus routes originate from ${widget.directFromStop}.'
            : 'There is no direct single-bus route connecting ${widget.directFromStop} to "$query". '
                'Use the Journey Planner to view 1-change connecting trips.',
      );
    }

    return ListView.separated(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.only(top: 6, bottom: 28),
      itemCount: _directDestinations.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 78, endIndent: WimbSpace.screen),
      itemBuilder: (context, i) {
        final dest = _directDestinations[i];
        final sampleRoutes = dest.routeNames.take(3).join(', ');
        final hasMore = dest.routeNames.length > 3;

        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: WimbSpace.screen, vertical: 8),
          leading: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: WimbColors.delhiGreen.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.directions_bus, size: 21, color: WimbColors.delhiGreen),
          ),
          title: Text(
            dest.stopName,
            style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              '${dest.directRoutesCount} direct ${dest.directRoutesCount == 1 ? 'route' : 'routes'} ($sampleRoutes${hasMore ? '...' : ''})',
              style: const TextStyle(fontSize: 12.5, color: WimbColors.inkMuted),
            ),
          ),
          trailing: const Icon(Icons.chevron_right, size: 20, color: WimbColors.inkFaint),
          onTap: () => Navigator.of(context).pop(dest.toPlaceSuggestion()),
        );
      },
    );
  }

  Widget _standardPlaceSearchBody() {
    if (!_hasTyped) {
      return ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.only(bottom: 28),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(WimbSpace.screen, 14, WimbSpace.screen, 6),
            child: SectionLabel('Popular transit hubs'),
          ),
          ..._popularPlaces.map((place) => ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: WimbSpace.screen, vertical: 6),
                leading: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: WimbColors.delhiGreen.withValues(alpha: 0.09),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.star_outline, size: 21, color: WimbColors.delhiGreen),
                ),
                title: Text(
                  place.stopName,
                  style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600),
                ),
                subtitle: const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Text(
                    'Major transit hub',
                    style: TextStyle(fontSize: 12.5, color: WimbColors.inkMuted),
                  ),
                ),
                trailing: const Icon(Icons.chevron_right, size: 20, color: WimbColors.inkFaint),
                onTap: () => Navigator.of(context).pop(place),
              )),
        ],
      );
    }
    if (_controller.text.trim().length < 2) {
      return _hint('Keep typing - at least two letters.');
    }
    if (_results.isEmpty && !_searching) {
      return _hint('Nothing matches "${_controller.text.trim()}".');
    }

    return ListView.separated(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.only(top: 6, bottom: 28),
      itemCount: _results.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 78, endIndent: WimbSpace.screen),
      itemBuilder: (context, i) {
        final place = _results[i];
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: WimbSpace.screen, vertical: 8),
          leading: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: WimbColors.dtcRed.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.place_outlined, size: 21, color: WimbColors.dtcRed),
          ),
          title: Text(
            place.stopName,
            style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w500),
          ),
          trailing: const Icon(Icons.chevron_right, size: 20, color: WimbColors.inkFaint),
          onTap: () => Navigator.of(context).pop(place),
        );
      },
    );
  }

  Widget _hint(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 44, 36, 0),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: WimbColors.inkMuted),
      ),
    );
  }
}
