// Unit and widget tests for the Arrival Alarm and Deboarding Alert System.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wimb_app/arrival_alarm_service.dart';

void main() {
  group('ArrivalAlarmNotifier Unit Tests', () {
    late ArrivalAlarmNotifier notifier;

    setUp(() {
      notifier = ArrivalAlarmNotifier();
    });

    test('starts in idle state', () {
      expect(notifier.state.isActive, isFalse);
      expect(notifier.state.isTriggered, isFalse);
    });

    test('setAlarm activates with validated inputs', () {
      notifier.setAlarm(
        routeId: '764',
        routeName: '764',
        targetStopName: 'Nehru Place Terminal',
        targetStopSequence: 15,
        stopThreshold: 1,
        minuteThreshold: 5,
      );

      expect(notifier.state.isActive, isTrue);
      expect(notifier.state.isTriggered, isFalse);
      expect(notifier.state.routeId, equals('764'));
      expect(notifier.state.targetStopName, equals('Nehru Place Terminal'));
      expect(notifier.state.targetStopSequence, equals(15));
      expect(notifier.state.stopThreshold, equals(1));
    });

    test('setAlarm rejects negative stop sequence (zero-trust)', () {
      expect(
        () => notifier.setAlarm(
          routeId: '764',
          routeName: '764',
          targetStopName: 'Invalid Stop',
          targetStopSequence: -1,
        ),
        throwsArgumentError,
      );
    });

    test('does not trigger if bus is too far away', () {
      notifier.setAlarm(
        routeId: '764',
        routeName: '764',
        targetStopName: 'Nehru Place Terminal',
        targetStopSequence: 15,
        stopThreshold: 1,
        minuteThreshold: 5,
      );

      // Bus is at stop 10 (5 stops away, ETA 15 mins)
      final triggered = notifier.evaluateProgress(
        currentStopSequence: 10,
        estimatedSecondsRemaining: 900,
      );

      expect(triggered, isFalse);
      expect(notifier.state.isTriggered, isFalse);
      expect(notifier.state.stopsAway, equals(5));
      expect(notifier.state.minutesAway, equals(15.0));
    });

    test('triggers alert when within stopThreshold (1 stop away)', () {
      notifier.setAlarm(
        routeId: '764',
        routeName: '764',
        targetStopName: 'Nehru Place Terminal',
        targetStopSequence: 15,
        stopThreshold: 1,
        minuteThreshold: 5,
      );

      // Bus reaches stop 14 (1 stop away)
      final triggered = notifier.evaluateProgress(
        currentStopSequence: 14,
        estimatedSecondsRemaining: 480, // 8 mins
      );

      expect(triggered, isTrue);
      expect(notifier.state.isTriggered, isTrue);
      expect(notifier.state.triggerCondition, equals(AlarmTriggerCondition.stopsRemaining));
      expect(notifier.state.stopsAway, equals(1));
    });

    test('triggers alert when within minuteThreshold (<= 5 minutes)', () {
      notifier.setAlarm(
        routeId: '764',
        routeName: '764',
        targetStopName: 'Nehru Place Terminal',
        targetStopSequence: 15,
        stopThreshold: 1,
        minuteThreshold: 5,
      );

      // Bus is 2 stops away, but ETA is 4 minutes (240s)
      final triggered = notifier.evaluateProgress(
        currentStopSequence: 13,
        estimatedSecondsRemaining: 240,
      );

      expect(triggered, isTrue);
      expect(notifier.state.isTriggered, isTrue);
      expect(notifier.state.triggerCondition, equals(AlarmTriggerCondition.timeWindow));
    });

    test('snooze temporarily suppresses alert', () {
      notifier.setAlarm(
        routeId: '764',
        routeName: '764',
        targetStopName: 'Nehru Place Terminal',
        targetStopSequence: 15,
      );

      notifier.evaluateProgress(currentStopSequence: 14);
      expect(notifier.state.isTriggered, isTrue);

      notifier.snooze(duration: const Duration(minutes: 5));
      expect(notifier.state.isTriggered, isFalse);
      expect(notifier.state.isSnoozed, isTrue);

      // Re-evaluation while snoozed returns false
      final retriggered = notifier.evaluateProgress(currentStopSequence: 14);
      expect(retriggered, isFalse);
    });

    test('dismiss resets back to idle', () {
      notifier.setAlarm(
        routeId: '764',
        routeName: '764',
        targetStopName: 'Nehru Place Terminal',
        targetStopSequence: 15,
      );

      notifier.dismiss();
      expect(notifier.state.isActive, isFalse);
      expect(notifier.state.targetStopName, isNull);
    });
  });

  group('ArrivalAlarmBanner Widget Tests', () {
    testWidgets('renders nothing when idle', (WidgetTester tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: ArrivalAlarmBanner(),
            ),
          ),
        ),
      );

      expect(find.text('GET READY TO DEBOARD!'), findsNothing);
      expect(find.byIcon(Icons.alarm_on), findsNothing);
    });

    testWidgets('renders active status chip when monitoring', (WidgetTester tester) async {
      final container = ProviderContainer();
      container.read(arrivalAlarmProvider.notifier).setAlarm(
            routeId: '764',
            routeName: '764',
            targetStopName: 'AIIMS Bus Stop',
            targetStopSequence: 12,
          );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: ArrivalAlarmBanner(),
            ),
          ),
        ),
      );

      expect(find.textContaining('Alarm set for AIIMS Bus Stop'), findsOneWidget);
      expect(find.byIcon(Icons.alarm_on), findsOneWidget);
    });

    testWidgets('renders urgent alert when triggered', (WidgetTester tester) async {
      final container = ProviderContainer();
      container.read(arrivalAlarmProvider.notifier).setAlarm(
            routeId: '764',
            routeName: '764',
            targetStopName: 'AIIMS Bus Stop',
            targetStopSequence: 12,
          );
      container.read(arrivalAlarmProvider.notifier).evaluateProgress(currentStopSequence: 11);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: ArrivalAlarmBanner(),
            ),
          ),
        ),
      );

      expect(find.text('GET READY TO DEBOARD!'), findsOneWidget);
      expect(find.textContaining('Approaching AIIMS Bus Stop'), findsOneWidget);
      expect(find.text('Snooze'), findsOneWidget);
    });
  });
}
