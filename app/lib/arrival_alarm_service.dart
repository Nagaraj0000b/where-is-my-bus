// Arrival Alarm & Deboarding Alert Service
//
// In commuter transit (especially on crowded Delhi buses without automated
// stop announcements), missing one's destination stop due to distraction or
// poor exterior visibility is a ubiquitous pain point.
//
// This service maintains an active destination watch. As the commuter travels
// or as the bus telemetry advances, it continuously monitors:
//   1. Stops away (e.g. triggers when 1 stop before destination).
//   2. Estimated time away (e.g. triggers when remaining ETA <= 5 minutes).
//
// When triggered, it produces multi-sensory feedback:
//   - Auditory alert (SystemSound alert).
//   - Haptic vibration pattern (HapticFeedback heavy impact).
//   - Visual persistent banner & modal deboarding notice with Dismiss/Snooze.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'theme.dart';

/// The trigger condition that caused an arrival alarm to fire.
enum AlarmTriggerCondition {
  /// Bus reached the proximity stop threshold (e.g. 1 stop before destination).
  stopsRemaining,

  /// Bus estimated arrival window entered the time threshold (e.g. <= 5 minutes).
  timeWindow,

  /// Triggered manually for testing and demonstration purposes.
  manualTest,
}

/// Immutable state representation for an active or triggered arrival alarm.
@immutable
class ArrivalAlarmState {
  /// Whether an alarm is actively configured and monitoring progress.
  final bool isActive;

  /// Whether the alarm condition has been met and the alert is currently firing.
  final bool isTriggered;

  /// The GTFS route identifier the trip belongs to (e.g. "764").
  final String? routeId;

  /// The human-readable route line name (e.g. "764", "534A").
  final String? routeName;

  /// Name of the commuter's destination stop where they need to deboard.
  final String? targetStopName;

  /// Ordered sequence number of the destination stop along the route.
  final int? targetStopSequence;

  /// Threshold: fire alert when remaining stops is less than or equal to this number.
  /// Defaults to 1 (meaning: alert at the penultimate stop before deboarding).
  final int stopThreshold;

  /// Threshold: fire alert when remaining ETA in minutes is less than or equal to this number.
  /// Defaults to 5 minutes.
  final int minuteThreshold;

  /// The specific condition that caused this alarm to fire.
  final AlarmTriggerCondition? triggerCondition;

  /// Exact timestamp when the alarm was triggered.
  final DateTime? triggeredAt;

  /// Last observed sequence number of the bus along the route.
  final int? currentStopSequence;

  /// Current stops remaining until the destination stop.
  final int? stopsAway;

  /// Current estimated minutes remaining until the destination stop.
  final double? minutesAway;

  /// Timestamp until which the alarm is snoozed (suppressing audio/haptics).
  final DateTime? snoozedUntil;

  const ArrivalAlarmState({
    this.isActive = false,
    this.isTriggered = false,
    this.routeId,
    this.routeName,
    this.targetStopName,
    this.targetStopSequence,
    this.stopThreshold = 1,
    this.minuteThreshold = 5,
    this.triggerCondition,
    this.triggeredAt,
    this.currentStopSequence,
    this.stopsAway,
    this.minutesAway,
    this.snoozedUntil,
  });

  /// Initial idle state with no alarm set.
  static const idle = ArrivalAlarmState();

  /// Returns true if the alarm is currently snoozed.
  bool get isSnoozed {
    if (snoozedUntil == null) return false;
    return DateTime.now().isBefore(snoozedUntil!);
  }

  /// Creates a copy of this state with modified attributes.
  ArrivalAlarmState copyWith({
    bool? isActive,
    bool? isTriggered,
    String? routeId,
    String? routeName,
    String? targetStopName,
    int? targetStopSequence,
    int? stopThreshold,
    int? minuteThreshold,
    AlarmTriggerCondition? triggerCondition,
    DateTime? triggeredAt,
    int? currentStopSequence,
    int? stopsAway,
    double? minutesAway,
    DateTime? snoozedUntil,
    bool clearSnooze = false,
  }) {
    return ArrivalAlarmState(
      isActive: isActive ?? this.isActive,
      isTriggered: isTriggered ?? this.isTriggered,
      routeId: routeId ?? this.routeId,
      routeName: routeName ?? this.routeName,
      targetStopName: targetStopName ?? this.targetStopName,
      targetStopSequence: targetStopSequence ?? this.targetStopSequence,
      stopThreshold: stopThreshold ?? this.stopThreshold,
      minuteThreshold: minuteThreshold ?? this.minuteThreshold,
      triggerCondition: triggerCondition ?? this.triggerCondition,
      triggeredAt: triggeredAt ?? this.triggeredAt,
      currentStopSequence: currentStopSequence ?? this.currentStopSequence,
      stopsAway: stopsAway ?? this.stopsAway,
      minutesAway: minutesAway ?? this.minutesAway,
      snoozedUntil: clearSnooze ? null : (snoozedUntil ?? this.snoozedUntil),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ArrivalAlarmState &&
          runtimeType == other.runtimeType &&
          isActive == other.isActive &&
          isTriggered == other.isTriggered &&
          routeId == other.routeId &&
          routeName == other.routeName &&
          targetStopName == other.targetStopName &&
          targetStopSequence == other.targetStopSequence &&
          stopThreshold == other.stopThreshold &&
          minuteThreshold == other.minuteThreshold &&
          triggerCondition == other.triggerCondition &&
          triggeredAt == other.triggeredAt &&
          currentStopSequence == other.currentStopSequence &&
          stopsAway == other.stopsAway &&
          minutesAway == other.minutesAway &&
          snoozedUntil == other.snoozedUntil;

  @override
  int get hashCode => Object.hash(
        isActive,
        isTriggered,
        routeId,
        routeName,
        targetStopName,
        targetStopSequence,
        stopThreshold,
        minuteThreshold,
        triggerCondition,
        triggeredAt,
        currentStopSequence,
        stopsAway,
        minutesAway,
        snoozedUntil,
      );
}

/// State notifier managing arrival alarm lifecycle, progress evaluation, and sensory alerts.
class ArrivalAlarmNotifier extends StateNotifier<ArrivalAlarmState> {
  ArrivalAlarmNotifier() : super(ArrivalAlarmState.idle);

  /// Configures and activates a new arrival alarm for a specific destination stop.
  ///
  /// Parameters:
  /// - [routeId]: The GTFS route ID (e.g. "764").
  /// - [routeName]: Human-facing route label (e.g. "764").
  /// - [targetStopName]: Name of destination stop (e.g. "Nehru Place Terminal").
  /// - [targetStopSequence]: Sequence position of the destination stop along the route.
  /// - [stopThreshold]: How many stops before destination to alert (defaults to 1).
  /// - [minuteThreshold]: How many minutes before arrival to alert (defaults to 5.0).
  void setAlarm({
    required String routeId,
    required String routeName,
    required String targetStopName,
    required int targetStopSequence,
    int stopThreshold = 1,
    int minuteThreshold = 5,
  }) {
    // Zero-trust input validation: stop sequence must be non-negative
    if (targetStopSequence < 0) {
      throw ArgumentError.value(
        targetStopSequence,
        'targetStopSequence',
        'Stop sequence must be greater than or equal to 0',
      );
    }
    if (stopThreshold < 0) {
      throw ArgumentError.value(
        stopThreshold,
        'stopThreshold',
        'Stop threshold must be non-negative',
      );
    }
    if (minuteThreshold < 0) {
      throw ArgumentError.value(
        minuteThreshold,
        'minuteThreshold',
        'Minute threshold must be non-negative',
      );
    }

    state = ArrivalAlarmState(
      isActive: true,
      isTriggered: false,
      routeId: routeId,
      routeName: routeName,
      targetStopName: targetStopName,
      targetStopSequence: targetStopSequence,
      stopThreshold: stopThreshold,
      minuteThreshold: minuteThreshold,
    );
  }

  /// Evaluates updated transit telemetry and triggers the alert if thresholds are met.
  ///
  /// Parameters:
  /// - [currentStopSequence]: The bus's current sequence index along the route.
  /// - [stopsRemaining]: Computed stops between bus and destination (optional).
  /// - [estimatedSecondsRemaining]: Estimated travel seconds remaining (optional).
  ///
  /// Returns `true` if an alert was newly triggered, `false` otherwise.
  bool evaluateProgress({
    int? currentStopSequence,
    int? stopsRemaining,
    int? estimatedSecondsRemaining,
  }) {
    if (!state.isActive) return false;

    // Calculate effective stops away
    int? computedStopsAway = stopsRemaining;
    if (computedStopsAway == null &&
        currentStopSequence != null &&
        state.targetStopSequence != null) {
      computedStopsAway = state.targetStopSequence! - currentStopSequence;
    }

    // Calculate effective minutes away
    double? computedMinutesAway;
    if (estimatedSecondsRemaining != null) {
      computedMinutesAway = estimatedSecondsRemaining / 60.0;
    }

    // Update progress state metrics
    state = state.copyWith(
      currentStopSequence: currentStopSequence,
      stopsAway: computedStopsAway,
      minutesAway: computedMinutesAway,
    );

    // If already triggered or snoozed, do not re-trigger sound alerts
    if (state.isTriggered || state.isSnoozed) return false;

    // Check stop threshold: e.g. 1 stop away or at destination
    final hitStopThreshold =
        computedStopsAway != null && computedStopsAway <= state.stopThreshold && computedStopsAway >= 0;

    // Check time threshold: e.g. <= 5 minutes away
    final hitTimeThreshold =
        computedMinutesAway != null && computedMinutesAway <= state.minuteThreshold && computedMinutesAway >= 0;

    if (hitStopThreshold || hitTimeThreshold) {
      final condition = hitStopThreshold
          ? AlarmTriggerCondition.stopsRemaining
          : AlarmTriggerCondition.timeWindow;

      _fireTrigger(condition);
      return true;
    }

    return false;
  }

  /// Manually triggers the alarm (useful for testing and PoC demonstrations).
  void triggerManualTest() {
    if (!state.isActive) {
      // Create a temporary demo state if none was set
      setAlarm(
        routeId: '764',
        routeName: '764',
        targetStopName: 'Nehru Place Terminal',
        targetStopSequence: 15,
      );
    }
    _fireTrigger(AlarmTriggerCondition.manualTest);
  }

  /// Fires sensory feedback and transitions state to triggered.
  void _fireTrigger(AlarmTriggerCondition condition) {
    state = state.copyWith(
      isTriggered: true,
      triggerCondition: condition,
      triggeredAt: DateTime.now(),
      clearSnooze: true,
    );

    // Dispatch auditory and haptic feedback
    try {
      SystemSound.play(SystemSoundType.alert);
      HapticFeedback.heavyImpact();
    } catch (_) {
      // In non-native test environments, channel calls are safely ignored
    }
  }

  /// Snoozes the active alert for [duration] (defaults to 2 minutes).
  void snooze({Duration duration = const Duration(minutes: 2)}) {
    state = state.copyWith(
      isTriggered: false,
      snoozedUntil: DateTime.now().add(duration),
    );
  }

  /// Dismisses and completely cancels the active arrival alarm.
  void dismiss() {
    state = ArrivalAlarmState.idle;
  }
}

/// Global Riverpod provider for the arrival alarm state and controller.
final arrivalAlarmProvider =
    StateNotifierProvider<ArrivalAlarmNotifier, ArrivalAlarmState>((ref) {
  return ArrivalAlarmNotifier();
});

/// Reusable banner widget rendering the current alarm status or triggered alert.
///
/// Designed to sit cleanly at the top of the screen or above navigation bars,
/// ensuring high visibility without obscuring primary navigation.
class ArrivalAlarmBanner extends ConsumerWidget {
  const ArrivalAlarmBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alarm = ref.watch(arrivalAlarmProvider);
    final notifier = ref.read(arrivalAlarmProvider.notifier);

    if (!alarm.isActive) return const SizedBox.shrink();

    // The banner is the first thing in the shell, above every tab, so it
    // is also the only place that has to leave room for the status bar.
    final topInset = MediaQuery.of(context).padding.top;

    // Triggered State: bold, urgent, high-contrast deboarding alert.
    if (alarm.isTriggered) {
      return Container(
        width: double.infinity,
        margin: EdgeInsets.fromLTRB(16, topInset + 8, 16, 8),
        padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
        decoration: BoxDecoration(
          color: WimbColors.dtcRed,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: WimbColors.dtcRed.withValues(alpha: 0.26),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.notifications_active, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'GET READY TO DEBOARD!',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Approaching ${alarm.targetStopName ?? "destination"}'
                    '${alarm.stopsAway != null ? " (${alarm.stopsAway} stop away)" : ""}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            TextButton(
              style: TextButton.styleFrom(
                backgroundColor: Colors.white.withValues(alpha: 0.20),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(WimbRadius.pill),
                ),
              ),
              onPressed: () => notifier.snooze(),
              child: const Text('Snooze', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
            ),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 19),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
              tooltip: 'Dismiss alarm',
              onPressed: () => notifier.dismiss(),
            ),
          ],
        ),
      );
    }

    // Monitoring State: calm, reassuring status chip showing active watch.
    return Container(
      width: double.infinity,
      margin: EdgeInsets.fromLTRB(16, topInset + 8, 16, 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        color: WimbColors.cardCream,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: WimbColors.hairline),
        boxShadow: const [
          BoxShadow(
            color: WimbColors.shadow,
            blurRadius: 14,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: WimbColors.delhiGreenLight,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.alarm_on, color: WimbColors.delhiGreen, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Alarm set for ${alarm.targetStopName ?? "destination"} '
              '(${alarm.stopThreshold} stop before)',
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: WimbColors.ink,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: WimbColors.inkMuted, size: 17),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            tooltip: 'Cancel alarm',
            onPressed: () => notifier.dismiss(),
          ),
        ],
      ),
    );
  }
}
