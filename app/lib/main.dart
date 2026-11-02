// The app's entry point and its shell.
//
// Three jobs, in order:
//
//   1. Apply the theme (see theme.dart - the Delhi bus identity).
//   2. Decide whether anyone is signed in, before showing anything.
//   3. Hold the four tabs once that is settled.
//
// Step 2 is why there is a splash screen at all. Checking the saved token
// means asking the server, which takes a moment; without the splash the
// app would flash the sign-in screen and then snatch it away from someone
// who was already signed in.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'arrival_alarm_service.dart';
import 'auth_client.dart';
import 'home_screen.dart';
import 'journey_screen.dart';
import 'routes_screen.dart';
import 'sign_in_screen.dart';
import 'theme.dart';
import 'timetable_screen.dart';

// ProviderScope is Riverpod's requirement - it is what actually stores the
// state behind every provider used anywhere in the app, so it has to sit
// above everything else.
void main() {
  runApp(const ProviderScope(child: WimbApp()));
}

class WimbApp extends StatelessWidget {
  const WimbApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Where Is My Bus',
      theme: buildWimbTheme(),
      debugShowCheckedModeBanner: false,
      home: const AuthGate(),
    );
  }
}

/// Decides which of the three top-level states the app is in: still
/// working out who you are, not signed in, or ready to use.
class AuthGate extends ConsumerWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final controller = ref.watch(authControllerProvider.notifier);

    return auth.when(
      loading: () => const _SplashScreen(),
      // A failure here means the token check itself broke - not that the
      // token was bad. The app still works without an account, so the
      // honest response is to carry on rather than block the whole app
      // behind an error nobody can act on.
      error: (_, _) => const HomeShell(),
      data: (user) {
        // Signed in, or deliberately chose not to be. Either way, in.
        if (user != null || controller.skippedSignIn) return const HomeShell();
        return const SignInScreen();
      },
    );
  }
}

/// Shown for the moment it takes to check the saved token. An off-white
/// splash with the wordmark in ink, so the first frame already matches the
/// rest of the app.
class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: WimbColors.cream,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            WimbWordmark(color: WimbColors.ink),
            SizedBox(height: 26),
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.2, color: WimbColors.dtcRed),
            ),
          ],
        ),
      ),
    );
  }
}

/// The four tabs, once the app is past the sign-in gate.
///
/// `IndexedStack` (rather than swapping the child) keeps each screen's own
/// state - a half-typed search, a picked place - alive when switching tabs
/// and back, instead of rebuilding it from scratch every time.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  void _openTab(int index) => setState(() => _index = index);

  @override
  Widget build(BuildContext context) {
    // Built here rather than in a `static const` list because the home
    // screen needs a callback into this state to switch tabs.
    final screens = [
      HomeScreen(onOpenTab: _openTab),
      const JourneyScreen(),
      const TimetableScreen(),
      const RoutesScreen(),
    ];

    // When an alarm banner is visible it already accounts for the status
    // bar, so the tab underneath must not add that inset a second time.
    // Without this the app bar would start one status bar lower than usual
    // for as long as the alarm is set.
    final alarmActive = ref.watch(arrivalAlarmProvider).isActive;

    // No SafeArea around the whole body any more. Each tab owns its top
    // edge now: an AppBar draws under the status bar with its own inset,
    // while the home hero paints its red gradient all the way up. Wrapping
    // everything in one SafeArea was what left a strip of flat colour above
    // the hero and made the app look boxed in.
    return Scaffold(
      body: Column(
        children: [
          const ArrivalAlarmBanner(),
          Expanded(
            child: MediaQuery.removePadding(
              context: context,
              removeTop: alarmActive,
              child: IndexedStack(index: _index, children: screens),
            ),
          ),
        ],
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: WimbColors.hairline, width: 0.8)),
        ),
        child: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: _openTab,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_rounded),
              label: 'Home',
            ),
            NavigationDestination(
              icon: Icon(Icons.alt_route_outlined),
              selectedIcon: Icon(Icons.alt_route),
              label: 'Journey',
            ),
            NavigationDestination(
              icon: Icon(Icons.departure_board_outlined),
              selectedIcon: Icon(Icons.departure_board),
              label: 'Timetable',
            ),
            NavigationDestination(
              icon: Icon(Icons.directions_bus_outlined),
              selectedIcon: Icon(Icons.directions_bus_filled),
              label: 'Routes',
            ),
          ],
        ),
      ),
    );
  }
}
