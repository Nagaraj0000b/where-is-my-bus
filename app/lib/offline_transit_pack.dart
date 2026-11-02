// Offline Transit Pack (On-Device SQLite Database)
//
// In Delhi transit, commuters frequently experience dead zones, congested
// cellular towers, or underground metro interchanges with zero cellular reception.
//
// Following the core principle of Where Is My Train ("Offline-First"):
//   - Route searches, stop search, ordered stop listings, and direct bus
//     lookups run 100% locally on-device via a pre-bundled SQLite database.
//   - When the backend API is unreachable, the app seamlessly steps down
//     across the Graceful Degradation hierarchy to Tier 4: Static Timetable.
//   - Zero network requests, sub-millisecond query responses, and zero data billing.

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'api_client.dart';

/// Direct bus option running between two specific stops, found offline.
class DirectBusOption {
  final String routeId;
  final String routeShortName;
  final String routeDesc;
  final int fromSequence;
  final int toSequence;
  final int stopsBetween;

  const DirectBusOption({
    required this.routeId,
    required this.routeShortName,
    required this.routeDesc,
    required this.fromSequence,
    required this.toSequence,
    required this.stopsBetween,
  });
}

/// Represents a destination stop directly reachable from a starting stop via bus.
class DirectDestinationSuggestion {
  /// The official name of the destination stop.
  final String stopName;

  /// Latitude coordinate of the destination stop.
  final double lat;

  /// Longitude coordinate of the destination stop.
  final double lon;

  /// Number of distinct direct bus routes serving this connection.
  final int directRoutesCount;

  /// Sample list of route numbers connecting directly (e.g. ['871UP', '893UP']).
  final List<String> routeNames;

  const DirectDestinationSuggestion({
    required this.stopName,
    required this.lat,
    required this.lon,
    required this.directRoutesCount,
    required this.routeNames,
  });

  /// Converts this suggestion into a standard [PlaceSuggestion].
  PlaceSuggestion toPlaceSuggestion() => PlaceSuggestion(
        stopName: stopName,
        lat: lat,
        lon: lon,
      );
}

/// Service managing the local SQLite database lifecycle and offline transit queries.
class OfflineTransitPack {
  static const String assetDbPath = 'assets/data/wimb_offline.db';
  Database? _db;

  /// Initializes the SQLite engine and loads the offline database asset.
  ///
  /// On desktop and non-Android/iOS testing environments, `sqfliteFfiInit` is
  /// used to route calls through the desktop C SQLite library.
  Future<void> initialize({String? overrideDbPath}) async {
    if (_db != null && _db!.isOpen) return;

    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    if (overrideDbPath != null) {
      _db = await openDatabase(overrideDbPath, readOnly: true);
      return;
    }

    final dbDir = await getDatabasesPath();
    final dbPath = '$dbDir/wimb_offline.db';

    // Copy bundled asset to local application databases directory if not already copied
    final file = File(dbPath);
    if (!await file.exists()) {
      try {
        final data = await rootBundle.load(assetDbPath);
        final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
      } catch (err) {
        // Fallback for direct testing from repo root
        final localFile = File('assets/data/wimb_offline.db');
        if (await localFile.exists()) {
          _db = await openDatabase(localFile.path, readOnly: true);
          return;
        }
      }
    }

    if (await file.exists()) {
      _db = await openDatabase(dbPath, readOnly: true);
    }
  }

  /// Searches stops and places by name using local indexed SQLite lookups.
  ///
  /// Parameters:
  /// - [query]: The user's typed search text (minimum 2 characters).
  /// - [limit]: Maximum results to return (capped at 25).
  Future<List<PlaceSuggestion>> searchPlaces(String query, {int limit = 10}) async {
    final cleanQuery = query.trim();
    if (cleanQuery.length < 2) return [];
    if (_db == null || !_db!.isOpen) await initialize();
    if (_db == null || !_db!.isOpen) return [];

    final cappedLimit = limit.clamp(1, 25);

    // Matches with prefix prioritized first
    final rows = await _db!.rawQuery(
      '''
      SELECT place_id, stop_name, lat, lon
      FROM stops
      WHERE stop_name LIKE ?
      ORDER BY (stop_name LIKE ?) DESC, stop_name ASC
      LIMIT ?
      ''',
      ['%$cleanQuery%', '$cleanQuery%', cappedLimit],
    );

    return rows.map((r) {
      return PlaceSuggestion(
        stopName: r['stop_name'] as String,
        lat: (r['lat'] as num?)?.toDouble() ?? 0.0,
        lon: (r['lon'] as num?)?.toDouble() ?? 0.0,
      );
    }).toList();
  }

  /// Searches bus routes by number using local indexed SQLite lookups.
  ///
  /// Parameters:
  /// - [query]: Route number or prefix (e.g. "764", "534").
  /// - [limit]: Maximum routes to return (capped at 20).
  Future<List<RouteSuggestion>> searchRoutes(String query, {int limit = 15}) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) return [];
    if (_db == null || !_db!.isOpen) await initialize();
    if (_db == null || !_db!.isOpen) return [];

    final cappedLimit = limit.clamp(1, 25);

    final rows = await _db!.rawQuery(
      '''
      SELECT route_id, route_short_name, route_desc
      FROM routes
      WHERE route_short_name LIKE ?
      ORDER BY
        CASE
          WHEN route_short_name LIKE ? OR route_short_name LIKE ? THEN 0
          WHEN route_short_name LIKE ? THEN 1
          ELSE 2
        END,
        route_short_name ASC
      LIMIT ?
      ''',
      [
        '%$cleanQuery%',
        '${cleanQuery}UP',
        '${cleanQuery}DOWN',
        '$cleanQuery%',
        cappedLimit,
      ],
    );

    return rows.map((r) {
      return RouteSuggestion(
        routeId: r['route_id'] as String,
        routeShortName: r['route_short_name'] as String,
        routeDesc: (r['route_desc'] as String?) ?? '',
      );
    }).toList();
  }

  /// Fetches ordered stop sequence for a route from local SQLite database.
  Future<List<RouteStop>> fetchRouteStops(String routeId) async {
    if (_db == null || !_db!.isOpen) await initialize();
    if (_db == null || !_db!.isOpen) return [];

    final rows = await _db!.rawQuery(
      '''
      SELECT stop_sequence, stop_name, metres_along_route, lat, lon
      FROM route_stops
      WHERE route_id = ?
      ORDER BY stop_sequence ASC
      ''',
      [routeId],
    );

    return rows.map((r) {
      return RouteStop(
        stopSequence: r['stop_sequence'] as int,
        stopName: r['stop_name'] as String,
        metresAlongRoute: (r['metres_along_route'] as num?)?.toDouble() ?? 0.0,
        hasTiming: true,
        lat: (r['lat'] as num?)?.toDouble(),
        lon: (r['lon'] as num?)?.toDouble(),
      );
    }).toList();
  }

  /// Finds all destination stops that can be reached directly from [fromStopName].
  ///
  /// Solves the commuter frustration of selecting a destination only to be told
  /// "no direct buses between these stops". By querying the underlying transit graph,
  /// this method returns ONLY valid, directly reachable stops downstream on the
  /// same bus routes.
  ///
  /// Parameters:
  /// - [fromStopName]: The starting stop name (e.g., 'Shivaji Stadium Terminal').
  /// - [query]: Optional filter string if the user types in the search bar.
  /// - [limit]: Maximum number of suggestions to return (capped at 60).
  ///
  /// Returns:
  /// A list of [DirectDestinationSuggestion] sorted by route frequency.
  Future<List<DirectDestinationSuggestion>> findDirectDestinations(
    String fromStopName, {
    String query = '',
    int limit = 60,
  }) async {
    if (_db == null || !_db!.isOpen) await initialize();
    if (_db == null || !_db!.isOpen) return [];

    // Clean any parenthetical annotations such as ' (Connaught Place)'
    final cleanedFrom = fromStopName.replaceAll(RegExp(r'\s*\(.*?\)'), '').trim();
    final cleanQuery = query.trim();
    final cappedLimit = limit.clamp(1, 100);

    final whereClause = cleanQuery.isEmpty
        ? 'WHERE (s1.stop_name = ? OR s1.stop_name LIKE ?) AND s2.stop_name != s1.stop_name'
        : 'WHERE (s1.stop_name = ? OR s1.stop_name LIKE ?) AND s2.stop_name != s1.stop_name AND s2.stop_name LIKE ?';

    final args = cleanQuery.isEmpty
        ? [cleanedFrom, '%$cleanedFrom%']
        : [cleanedFrom, '%$cleanedFrom%', '%$cleanQuery%'];

    final rows = await _db!.rawQuery(
      '''
      SELECT s2.stop_name, s2.lat, s2.lon, COUNT(DISTINCT s1.route_id) as direct_routes_count,
             GROUP_CONCAT(DISTINCT r.route_short_name) as route_names
      FROM route_stops s1
      JOIN route_stops s2 ON s1.route_id = s2.route_id AND s1.stop_sequence < s2.stop_sequence
      JOIN routes r ON r.route_id = s1.route_id
      $whereClause
      GROUP BY s2.stop_name
      ORDER BY direct_routes_count DESC, s2.stop_name ASC
      LIMIT $cappedLimit
      ''',
      args,
    );

    return rows.map((r) {
      final rawNames = (r['route_names'] as String?) ?? '';
      final namesList = rawNames.split(',').where((s) => s.isNotEmpty).toList();
      return DirectDestinationSuggestion(
        stopName: r['stop_name'] as String,
        lat: (r['lat'] as num?)?.toDouble() ?? 0.0,
        lon: (r['lon'] as num?)?.toDouble() ?? 0.0,
        directRoutesCount: (r['direct_routes_count'] as num?)?.toInt() ?? 1,
        routeNames: namesList,
      );
    }).toList();
  }

  /// Finds all direct bus routes connecting two named stops.
  Future<List<DirectBusOption>> findDirectBuses(String fromStopName, String toStopName) async {
    if (_db == null || !_db!.isOpen) await initialize();
    if (_db == null || !_db!.isOpen) return [];

    // Clean parentheticals in both names if they contain them
    final cleanFrom = fromStopName.replaceAll(RegExp(r'\s*\(.*?\)'), '').trim();
    final cleanTo = toStopName.replaceAll(RegExp(r'\s*\(.*?\)'), '').trim();

    final rows = await _db!.rawQuery(
      '''
      SELECT DISTINCT r.route_id, r.route_short_name, r.route_desc,
                      s1.stop_sequence AS from_seq, s2.stop_sequence AS to_seq
      FROM route_stops s1
      JOIN route_stops s2 ON s1.route_id = s2.route_id AND s1.stop_sequence < s2.stop_sequence
      JOIN routes r ON r.route_id = s1.route_id
      WHERE (s1.stop_name = ? OR s1.stop_name LIKE ?)
        AND (s2.stop_name = ? OR s2.stop_name LIKE ?)
      LIMIT 15
      ''',
      [cleanFrom, '%$cleanFrom%', cleanTo, '%$cleanTo%'],
    );

    return rows.map((r) {
      final fromSeq = r['from_seq'] as int;
      final toSeq = r['to_seq'] as int;
      return DirectBusOption(
        routeId: r['route_id'] as String,
        routeShortName: r['route_short_name'] as String,
        routeDesc: (r['route_desc'] as String?) ?? '',
        fromSequence: fromSeq,
        toSequence: toSeq,
        stopsBetween: toSeq - fromSeq,
      );
    }).toList();
  }

  /// Finds all routes serving a specific stop by name.
  Future<List<RouteSuggestion>> findRoutesAtStop(String stopName) async {
    if (_db == null || !_db!.isOpen) await initialize();
    if (_db == null || !_db!.isOpen) return [];

    final rows = await _db!.rawQuery(
      '''
      SELECT DISTINCT r.route_id, r.route_short_name, r.route_desc
      FROM route_stops rs
      JOIN routes r ON r.route_id = rs.route_id
      WHERE rs.stop_name LIKE ?
      ORDER BY r.route_short_name ASC
      LIMIT 20
      ''',
      ['%$stopName%'],
    );

    return rows.map((r) {
      return RouteSuggestion(
        routeId: r['route_id'] as String,
        routeShortName: r['route_short_name'] as String,
        routeDesc: (r['route_desc'] as String?) ?? '',
      );
    }).toList();
  }

  /// Closes database connection when disposing.
  Future<void> close() async {
    if (_db != null && _db!.isOpen) {
      await _db!.close();
      _db = null;
    }
  }
}

/// Global Riverpod provider for the offline transit repository.
final offlineTransitPackProvider = Provider<OfflineTransitPack>((ref) {
  final pack = OfflineTransitPack();
  ref.onDispose(() => pack.close());
  return pack;
});
