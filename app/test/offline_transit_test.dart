// Unit and functional tests for the Offline Transit Pack.

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wimb_app/offline_transit_pack.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late OfflineTransitPack pack;

  setUpAll(() async {
    pack = OfflineTransitPack();
    // Resolve database path from test working directory
    final dbFile = File('assets/data/wimb_offline.db');
    if (await dbFile.exists()) {
      await pack.initialize(overrideDbPath: dbFile.absolute.path);
    } else {
      // Check parent directory if run from another CWD
      final parentFile = File('../app/assets/data/wimb_offline.db');
      if (await parentFile.exists()) {
        await pack.initialize(overrideDbPath: parentFile.absolute.path);
      }
    }
  });

  tearDownAll(() async {
    await pack.close();
  });

  group('OfflineTransitPack Functional Tests', () {
    test('searchPlaces finds matching stops offline with coordinates', () async {
      final results = await pack.searchPlaces('Nehru Place', limit: 5);

      expect(results, isNotEmpty);
      expect(results.any((s) => s.stopName.contains('Nehru Place')), isTrue);
      final first = results.first;
      expect(first.lat, greaterThan(28.0));
      expect(first.lon, greaterThan(76.0));
    });

    test('searchPlaces rejects short queries (< 2 chars)', () async {
      final results = await pack.searchPlaces('A');
      expect(results, isEmpty);
    });

    test('searchRoutes surfaces matching bus numbers with directions', () async {
      final routes = await pack.searchRoutes('764', limit: 10);

      expect(routes, isNotEmpty);
      expect(routes.any((r) => r.routeShortName.contains('764')), isTrue);
      final route = routes.first;
      expect(route.routeId, isNotEmpty);
      expect(route.routeShortName, isNotEmpty);
      expect(route.routeDesc, isNotEmpty);
    });

    test('searchRoutes rejects empty query', () async {
      final routes = await pack.searchRoutes('');
      expect(routes, isEmpty);
    });

    test('fetchRouteStops returns ordered stop sequences offline', () async {
      final routes = await pack.searchRoutes('764');
      expect(routes, isNotEmpty);

      final routeId = routes.first.routeId;
      final stops = await pack.fetchRouteStops(routeId);

      expect(stops, isNotEmpty);
      expect(stops.first.stopSequence, equals(0));
      // Stops must be in strictly ascending sequence order
      for (var i = 1; i < stops.length; i++) {
        expect(stops[i].stopSequence, greaterThan(stops[i - 1].stopSequence));
      }
    });

    test('findDirectBuses identifies routes connecting two stops', () async {
      final directBuses = await pack.findDirectBuses('AIIMS', 'Nehru Place');

      expect(directBuses, isNotEmpty);
      final bus = directBuses.first;
      expect(bus.fromSequence, lessThan(bus.toSequence));
      expect(bus.stopsBetween, greaterThan(0));
      expect(bus.routeShortName, isNotEmpty);
    });

    test('findDirectDestinations returns valid reachable stops with route counts', () async {
      final dests = await pack.findDirectDestinations('Shivaji Stadium Terminal', limit: 10);

      expect(dests, isNotEmpty);
      final first = dests.first;
      expect(first.stopName, isNotEmpty);
      expect(first.directRoutesCount, greaterThan(0));
      expect(first.routeNames, isNotEmpty);
      expect(first.toPlaceSuggestion().stopName, equals(first.stopName));
    });
  });
}
