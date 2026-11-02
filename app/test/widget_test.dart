// Smoke tests for the app shell.
//
// Deliberately small, and deliberately offline. No test here touches the
// API: the sign-in gate resolves to "nobody is signed in" without a
// network call (there is no saved token in a test environment - see
// savedToken() in auth_client.dart), and every screen these tests reach is
// one that draws itself before asking the server anything.
//
// So this proves the app boots, the sign-in gate behaves, and the tabs are
// wired up - not that any particular bus data is correct. That is what the
// api/check-*.ts scripts are for.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:latlong2/latlong.dart';
import 'package:wimb_app/main.dart';
import 'package:wimb_app/route_map_widget.dart';

/// Secure storage is a plugin, and a plugin's real Android side does not
/// exist in a test. Left alone, the app's startup token check hangs
/// forever waiting for an answer that never comes, and every test below
/// times out on the splash screen.
///
/// So the channel is answered here with "there is no saved token", which
/// is the true state of a freshly installed app anyway - and it is the
/// state these tests are about, since they all start signed out.
void mockEmptySecureStorage() {
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (MethodCall call) async {
    switch (call.method) {
      case 'read':
        return null; // no token stored
      case 'readAll':
        return <String, String>{};
      case 'containsKey':
        return false;
      default:
        // write / delete / deleteAll - nothing to do, but they must still
        // answer or the awaiting code hangs exactly as read did.
        return null;
    }
  });
}

// ProviderScope is required at the root for any of Riverpod's `ref.watch`
// calls to work, same as in main.dart - pumping WimbApp on its own throws
// "Bad state: No ProviderScope found" the moment AuthGate builds.
Widget app() => const ProviderScope(child: WimbApp());

/// Boots the app and waits for the sign-in gate to finish deciding.
///
/// It pumps frames until the sign-in screen appears rather than pumping a
/// fixed number of times, because how many frames the token check takes is
/// an implementation detail that would otherwise silently break this
/// helper whenever it changed.
///
/// `pumpAndSettle` cannot be used: the splash shown while the check runs
/// has a spinner, which never stops animating, so settling never happens.
Future<void> bootToSignIn(WidgetTester tester) async {
  await tester.pumpWidget(app());

  for (var frame = 0; frame < 20; frame++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (find.text('Continue without an account').evaluate().isNotEmpty) return;
  }

  fail('The sign-in screen never appeared - the auth gate did not resolve.');
}

void main() {
  setUp(mockEmptySecureStorage);

  testWidgets('opens on the sign-in screen when nobody is signed in',
      (WidgetTester tester) async {
    await bootToSignIn(tester);

    expect(find.text('Honest bus times, not guesses.'), findsOneWidget);
    expect(find.text('Sign in'), findsWidgets);
    // The escape hatch matters as much as the form - the app is meant to
    // work without an account at all.
    expect(find.text('Continue without an account'), findsOneWidget);
  });

  testWidgets('switching to create-account asks for a name too',
      (WidgetTester tester) async {
    await bootToSignIn(tester);

    // The name field belongs only to signup, so it should not be there yet.
    expect(find.text('Your name'), findsNothing);

    await tester.tap(find.text("I'm new here - create an account"));
    await tester.pump();

    expect(find.text('Your name'), findsOneWidget);
    expect(find.text('Create account'), findsWidgets);
  });

  testWidgets('a short password is refused without asking the server',
      (WidgetTester tester) async {
    await bootToSignIn(tester);
    await tester.tap(find.text("I'm new here - create an account"));
    await tester.pump();

    await tester.enterText(find.widgetWithText(TextField, 'Your name'), 'Test Person');
    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'test@example.com');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'short');

    await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
    await tester.pump();

    // Caught by the form's own copy of the rule, so no request is made.
    expect(find.text('Password must be at least 8 characters.'), findsOneWidget);
  });

  testWidgets('continuing without an account reaches the four tabs',
      (WidgetTester tester) async {
    await bootToSignIn(tester);

    await tester.tap(find.text('Continue without an account'));
    await tester.pump();

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Journey'), findsOneWidget);
    expect(find.text('Timetable'), findsOneWidget);
    expect(find.text('Routes'), findsOneWidget);

    // The home screen greets an anonymous visitor without a name.
    expect(find.text('Where are you headed?'), findsOneWidget);
  });

  testWidgets('the Routes tab still shows its search prompt',
      (WidgetTester tester) async {
    await bootToSignIn(tester);
    await tester.tap(find.text('Continue without an account'));
    await tester.pump();

    await tester.tap(find.text('Routes'));
    await tester.pump();

    expect(find.text('Route number, e.g. 764'), findsOneWidget);
    expect(find.text('POPULAR TRANSIT ROUTES'), findsOneWidget);
  });

  testWidgets('the Timetable tab shows direct bus search and corridor presets',
      (WidgetTester tester) async {
    await bootToSignIn(tester);
    await tester.tap(find.text('Continue without an account'));
    await tester.pump();

    await tester.tap(find.text('Timetable'));
    await tester.pump();

    expect(find.text('FROM STOP'), findsOneWidget);
    expect(find.text('TO STOP (OPTIONAL)'), findsOneWidget);
    expect(find.text('POPULAR TRANSIT CORRIDORS'), findsOneWidget);
  });

  testWidgets('the Journey tab provides Delhi demo presets and simulation toggle',
      (WidgetTester tester) async {
    await bootToSignIn(tester);
    await tester.tap(find.text('Continue without an account'));
    await tester.pump();

    await tester.tap(find.text('Journey'));
    await tester.pump();

    // Verify demo presets banner and key hub chips exist
    expect(find.text('DEMO PRESETS'), findsOneWidget);
    expect(find.text('Shivaji Stadium (CP)'), findsOneWidget);
    expect(find.text('AIIMS'), findsOneWidget);
    expect(find.text('Nehru Place'), findsOneWidget);
    expect(find.text('Simulate'), findsOneWidget);

    // Tap a preset chip to set FROM
    await tester.tap(find.text('Shivaji Stadium (CP)'));
    await tester.pump();
    expect(find.text('Shivaji Stadium Terminal (Connaught Place)'), findsOneWidget);

    // Tap another preset chip to set TO
    await tester.tap(find.text('AIIMS'));
    await tester.pump();
    expect(find.text('AIIMS / Safdarjung Hospital'), findsOneWidget);

    // Verify the "Find buses" button is now enabled
    final findBusesButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Find buses'),
    );
    expect(findBusesButton.onPressed, isNotNull);

    // Toggle simulation switch
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(find.text('Use demo location'), findsOneWidget);
  });

  testWidgets('one-tap sample trip loads CP to Nehru Place directly',
      (WidgetTester tester) async {
    await bootToSignIn(tester);
    await tester.tap(find.text('Continue without an account'));
    await tester.pump();

    await tester.tap(find.text('Journey'));
    await tester.pump();

    // Tap "Sample Trip (CP -> Nehru Pl)"
    await tester.tap(find.text('Sample Trip (CP -> Nehru Pl)'));
    await tester.pump();

    expect(find.text('Shivaji Stadium Terminal (Connaught Place)'), findsOneWidget);
    expect(find.text('Nehru Place Terminal'), findsOneWidget);
  });

  testWidgets('RouteMapWidget renders smoothly with stops and polylines',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: RouteMapWidget(
            polylinePoints: [
              LatLng(28.6323, 77.2165),
              LatLng(28.5487, 77.2570),
            ],
            origin: LatLng(28.6323, 77.2165),
            destination: LatLng(28.5487, 77.2570),
            enableTiles: false,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(RouteMapWidget), findsOneWidget);
  });
}

