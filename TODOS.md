# Project TODOs — Where Is My Bus (Delhi)

This document tracks immediate, upcoming, and long-term engineering tasks. It is kept up to date as features are designed, tested, and validated.

---

## 1. Immediate: Professor PoC & Live Demonstration

Tasks needed to demonstrate the project end-to-end to professors, reviewers, and examiners while outside Delhi.

- [x] **Delhi Location Simulation in Flutter App**
  - Add quick-select demo locations in `app/lib/journey_screen.dart` (e.g., Connaught Place / Shivaji Stadium, AIIMS, Nehru Place, Kashmiri Gate).
  - Add a "Simulate in Delhi" toggle to the "Use my location" button so testing outside Delhi instantly resolves to a real Delhi bus hub instead of failing the walking distance check.
- [x] **Crowdsourced Telemetry Ingestion Endpoint**
  - Add `POST /crowdsource/ping` in `api/src/server.ts` to accept passenger mobile telemetry (`route_id`, `lat`, `lon`, `speed`, `timestamp`).
  - Add basic validity checks: reject pings > 50m off route, reject pedestrian walking speeds (< 5 km/h) or impossible aircraft speeds (> 80 km/h).
- [x] **Backend Passenger Route Simulator**
  - Create `tools/simulate-passenger.js` that replays GPS pings along a real route geometry (Route 764) stop by stop.
  - Demonstrate live terminal output proving passenger telemetry fills the gap when agency GPS is absent.
- [x] **Interactive Map Integration (`flutter_map` + OpenStreetMap)**
  - Add `flutter_map` and `latlong2` to `app/pubspec.yaml` (pure Flutter, 100% free, zero Google API keys or billing).
  - Create reusable `RouteMapWidget` to render route polylines and stop markers.
  - Integrate map into `JourneyScreen` (shows journey path, boarding pin, destination pin) and `RoutesScreen` (shows full route across Delhi).
  - Add animated marker support to show simulated bus/passenger moving along the route.
- [x] **Academic Defense & Architecture Summary**
  - Prepare a concise 1-page reference summarizing:
    1. Data lineage: AIS-140 GPS -> DIMTS -> OTD Delhi -> Azure Recorder -> PostGIS.
    2. Why agency feed cannot be trusted blindly (44% empty responses, speed always 0, ghost buses).
    3. Why static timetables are discarded (fabricated constant speed).
    4. 7-fold cross-validation results (splitting weekday/weekend cut bias by 83% to 99%).

---

## 2. Mobile App (Flutter & Riverpod)

- [x] **"I'm On This Bus" Mode (Crowdsourcing Client)**
  - Add an optional toggle on the Route view allowing a commuter to broadcast their trip progress.
  - Include transparent battery and privacy consent indicators.
- [x] **Map Visualization (`flutter_map`)**
  - Integrate route polyline rendering for chosen journeys using cached route shape coordinates.
  - Show user location relative to nearby stops on the OpenStreetMap canvas.
- [x] **Pre-packaged Demo Builds**
  - [x] Run `flutter build web` to keep a self-contained offline browser build ready for presentation (`app/build/web`).
  - [x] Generate release Android APK (`flutter build apk`) for on-phone demonstration without requiring a dev laptop (`app/build/app/outputs/flutter-apk/app-release.apk`).

---

## 3. Backend & API Services (Fastify + TypeScript)

- [x] **Crowdsourced Vehicle Cache**
  - Maintain an active table or in-memory ring-buffer of recent passenger reports per route.
  - Expose `GET /routes/:id/crowdsourced` to show active crowdsourced vehicles on that route.
- [x] **Multi-Passenger Consensus (Plausibility Engine)**
  - If 1 user reports: tag as "Passenger reported (Medium confidence)".
  - If 2+ users agree within 100m on the same route: tag as "Verified by crowd (High confidence)".
- [x] **Automated Test Coverage**
  - Add tests in `api/check-crowdsource.ts` and `api/test-api.ts` covering crowdsource ingestion, invalid coordinates, and simulation edge cases.

---

## 4. Long-Term & Production Upgrades

- [ ] **Cloud Recorder Resumption**
  - Re-enable `wimb-recorder.service` on the Azure VM if live streaming vehicle positions are needed for production operations.
- [x] **Arrival Alarms**
  - Local push notification on device when the bus is 1 stop or 5 minutes away from the commuter's destination.
- [x] **Offline Transit Pack**
  - Pre-package local SQLite database (`sqflite`) for full offline route planning with zero network connectivity.
