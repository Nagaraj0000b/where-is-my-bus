// Reusable OpenStreetMap Map Widget for routes and journey visualization.
//
// WHAT THIS DOES
//
// Uses flutter_map + OpenStreetMap tiles to render:
//   - Route linestrings (polylines) across Delhi
//   - Origin (green) and Destination (red) pins
//   - Intermediate stop markers with tap labels
//   - Live crowdsourced vehicles with confidence badges and pulse indicator
//
// 100% free and open: requires zero Google Maps API keys or billing accounts.
// Degrades gracefully offline: polylines and markers render even if tile network lags.

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'api_client.dart';
import 'theme.dart';

/// Reusable map widget displaying route geometries, stop markers, and active vehicles.
class RouteMapWidget extends StatefulWidget {
  /// The ordered points forming the route polyline.
  final List<LatLng> polylinePoints;

  /// Optional start/origin stop pin.
  final LatLng? origin;
  final String? originLabel;

  /// Optional destination stop pin.
  final LatLng? destination;
  final String? destinationLabel;

  /// Optional intermediate stops.
  final List<RouteStop>? stops;

  /// Optional active crowdsourced vehicles to display on the map.
  final List<CrowdsourcedVehicleClient>? crowdsourcedVehicles;

  /// Height of the map widget.
  final double height;

  /// If true, displays interactive zoom and re-center controls.
  final bool showControls;

  /// Whether to fetch network map tiles (disabled in offline widget tests).
  final bool enableTiles;

  const RouteMapWidget({
    super.key,
    required this.polylinePoints,
    this.origin,
    this.originLabel,
    this.destination,
    this.destinationLabel,
    this.stops,
    this.crowdsourcedVehicles,
    this.height = 240,
    this.showControls = true,
    this.enableTiles = true,
  });

  @override
  State<RouteMapWidget> createState() => _RouteMapWidgetState();
}

class _RouteMapWidgetState extends State<RouteMapWidget> {
  late final MapController _mapController;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  /// Calculates the bounding box to fit all relevant coordinates.
  LatLngBounds? _computeBounds() {
    final allPoints = <LatLng>[...widget.polylinePoints];
    if (widget.origin != null) allPoints.add(widget.origin!);
    if (widget.destination != null) allPoints.add(widget.destination!);
    if (widget.stops != null) {
      for (final s in widget.stops!) {
        if (s.lat != null && s.lon != null) {
          allPoints.add(LatLng(s.lat!, s.lon!));
        }
      }
    }
    if (widget.crowdsourcedVehicles != null) {
      for (final v in widget.crowdsourcedVehicles!) {
        allPoints.add(LatLng(v.lat, v.lon));
      }
    }

    if (allPoints.isEmpty) return null;

    var minLat = allPoints.first.latitude;
    var maxLat = allPoints.first.latitude;
    var minLon = allPoints.first.longitude;
    var maxLon = allPoints.first.longitude;

    for (final p in allPoints) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
    }

    // Add slight padding to prevent pins touching the edges
    const pad = 0.005;
    return LatLngBounds(
      LatLng(minLat - pad, minLon - pad),
      LatLng(maxLat + pad, maxLon + pad),
    );
  }

  void _zoomIn() {
    final current = _mapController.camera.zoom;
    _mapController.move(_mapController.camera.center, current + 1);
  }

  void _zoomOut() {
    final current = _mapController.camera.zoom;
    _mapController.move(_mapController.camera.center, current - 1);
  }

  void _fitBounds() {
    final bounds = _computeBounds();
    if (bounds != null) {
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: bounds,
          padding: const EdgeInsets.all(24),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bounds = _computeBounds();
    // Default to central Delhi (Connaught Place) if empty
    final initialCenter = bounds?.center ?? const LatLng(28.6323, 77.2165);

    // Build stop markers
    final markers = <Marker>[];

    // Intermediate stops (small dots)
    if (widget.stops != null) {
      for (final s in widget.stops!) {
        if (s.lat != null && s.lon != null) {
          markers.add(
            Marker(
              point: LatLng(s.lat!, s.lon!),
              width: 14,
              height: 14,
              child: GestureDetector(
                onTap: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      duration: const Duration(seconds: 2),
                      content: Text('${s.stopSequence}. ${s.stopName}'),
                    ),
                  );
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: WimbColors.cardCream,
                    shape: BoxShape.circle,
                    border: Border.all(color: WimbColors.dtcRed, width: 2),
                  ),
                ),
              ),
            ),
          );
        }
      }
    }

    // Origin Pin
    if (widget.origin != null) {
      markers.add(
        Marker(
          point: widget.origin!,
          width: 32,
          height: 32,
          child: Tooltip(
            message: widget.originLabel ?? 'Start',
            child: const Icon(
              Icons.trip_origin,
              color: WimbColors.delhiGreen,
              size: 26,
            ),
          ),
        ),
      );
    }

    // Destination Pin
    if (widget.destination != null) {
      markers.add(
        Marker(
          point: widget.destination!,
          width: 32,
          height: 32,
          child: Tooltip(
            message: widget.destinationLabel ?? 'Destination',
            child: const Icon(
              Icons.place,
              color: WimbColors.dtcRed,
              size: 32,
            ),
          ),
        ),
      );
    }

    // Active crowdsourced vehicles
    if (widget.crowdsourcedVehicles != null) {
      for (final v in widget.crowdsourcedVehicles!) {
        final isHigh = v.confidence == 'high';
        markers.add(
          Marker(
            point: LatLng(v.lat, v.lon),
            width: 44,
            height: 44,
            child: GestureDetector(
              onTap: () {
                showModalBottomSheet(
                  context: context,
                  builder: (ctx) => Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: isHigh ? WimbColors.delhiGreen : WimbColors.trustMedium,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                isHigh ? 'VERIFIED BY CROWD' : 'PASSENGER REPORTED',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const Spacer(),
                            Text(
                              '${v.speedKmh} km/h',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Route ${v.routeId}',
                          style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          v.description,
                          style: Theme.of(ctx).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Provenance: Crowdsourced Passenger Telemetry',
                          style: TextStyle(
                            fontSize: 11,
                            color: WimbColors.inkMuted,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: (isHigh ? WimbColors.delhiGreen : WimbColors.trustMedium).withValues(alpha: 0.25),
                    ),
                  ),
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isHigh ? WimbColors.delhiGreen : WimbColors.trustMedium,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: const Icon(
                      Icons.directions_bus,
                      color: Colors.white,
                      size: 15,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }
    }

    return Container(
      height: widget.height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(WimbRadius.card),
        border: Border.all(color: WimbColors.hairline),
        boxShadow: const [
          BoxShadow(
            color: WimbColors.shadow,
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: initialCenter,
              initialZoom: 12.5,
              onMapReady: () {
                if (bounds != null) {
                  _fitBounds();
                }
              },
            ),
            children: [
              // OpenStreetMap tile layer (free, no API key)
              if (widget.enableTiles)
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.wimb.delhi',
                ),
              // Route geometry polyline
              if (widget.polylinePoints.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: widget.polylinePoints,
                      strokeWidth: 4.5,
                      color: WimbColors.dtcRed,
                    ),
                  ],
                ),
              // Stop & Vehicle Markers
              MarkerLayer(markers: markers),
            ],
          ),
          // OpenStreetMap's tile policy asks for visible attribution.
          // A small quiet chip, bottom-left, where a map app puts it.
          if (widget.enableTiles)
            Positioned(
              left: 8,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.82),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  '© OpenStreetMap',
                  style: TextStyle(fontSize: 9, color: WimbColors.inkMuted),
                ),
              ),
            ),
          if (widget.showControls)
            Positioned(
              right: 8,
              bottom: 8,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _MapControl(
                    heroTag: 'map_fit_${widget.key.hashCode}',
                    icon: Icons.crop_free,
                    tooltip: 'Fit route',
                    onPressed: _fitBounds,
                  ),
                  const SizedBox(height: 6),
                  _MapControl(
                    heroTag: 'map_zoom_in_${widget.key.hashCode}',
                    icon: Icons.add,
                    tooltip: 'Zoom in',
                    onPressed: _zoomIn,
                  ),
                  const SizedBox(height: 6),
                  _MapControl(
                    heroTag: 'map_zoom_out_${widget.key.hashCode}',
                    icon: Icons.remove,
                    tooltip: 'Zoom out',
                    onPressed: _zoomOut,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// One map control: a small white circle with a soft edge, so the controls
/// read as belonging to the map instead of floating Material buttons on
/// top of it.
class _MapControl extends StatelessWidget {
  final String heroTag;
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _MapControl({
    required this.heroTag,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      shape: const CircleBorder(),
      elevation: 0,
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: Tooltip(
          message: tooltip,
          child: SizedBox(
            width: 34,
            height: 34,
            child: Icon(icon, size: 18, color: WimbColors.ink),
          ),
        ),
      ),
    );
  }
}
