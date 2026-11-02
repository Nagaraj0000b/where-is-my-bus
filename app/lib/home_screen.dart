// The landing screen: one question, one search field.
//
// LAYOUT REFERENCE
//
// The anchor is lookap entry "Expanding Search Interaction" by sucodee
// (@sucodeee, https://x.com/sucodeee/status/2106690154429841524): a soft
// off-white canvas, one large pill search field, and generous space around
// it. Nothing else competes with the search. The route row and quick tiles
// below are this project's own, built from data it already has.
//
// BRAND
//
// The wordmark is now just "WHERE IS MY BUS". The old "दिल्ली · DELHI" line
// branded the product to one city; the data can stay Delhi without the logo
// saying so.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';
import 'auth_client.dart';
import 'popular_routes.dart';
import 'routes_screen.dart';
import 'theme.dart';

/// Which tab to jump to when a shortcut is tapped. main.dart owns the tab
/// index; this is how the home asks it to change.
typedef TabRequest = void Function(int tabIndex);

class HomeScreen extends ConsumerWidget {
  final TabRequest onOpenTab;
  const HomeScreen({super.key, required this.onOpenTab});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).value;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      // The canvas is light, so the status icons must be dark. Without this
      // Android can leave white icons over a white header.
      value: SystemUiOverlayStyle.dark,
      child: Scaffold(
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 10, 24, 36),
            children: [
              _TopBar(user: user),
              const SizedBox(height: 42),

              if (user != null) ...[
                Text(
                  'Hello, ${user.firstName}.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 6),
              ],

              // The whole screen exists to ask this one question.
              Text(
                'Where is your bus?',
                style: Theme.of(context).textTheme.displaySmall?.copyWith(
                      fontSize: 38,
                      height: 1.02,
                      letterSpacing: -0.6,
                    ),
              ),
              const SizedBox(height: 10),
              Text(
                'Real arrival windows, measured from buses on the road.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: WimbColors.inkMuted,
                    ),
              ),
              const SizedBox(height: 26),

              _SearchCard(onTap: () => onOpenTab(1)),
              const SizedBox(height: 34),

              const SectionLabel('Quick actions'),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _QuickTile(
                        icon: Icons.departure_board_outlined,
                        title: 'Timetable & schedules',
                        subtitle: 'Direct buses between two stops',
                        onTap: () => onOpenTab(2),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _QuickTile(
                        icon: Icons.directions_bus_outlined,
                        title: 'Browse routes',
                        subtitle: 'Every stop a route calls at',
                        onTap: () => onOpenTab(3),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 34),

              SectionLabel(
                'Popular routes',
                trailing: TextButton(
                  onPressed: () => onOpenTab(3),
                  style: TextButton.styleFrom(
                    minimumSize: Size.zero,
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    'See all',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              SizedBox(
                height: 116,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  clipBehavior: Clip.none,
                  itemCount: popularRoutes.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (context, i) => _PopularRouteCard(route: popularRoutes[i]),
                ),
              ),
              const SizedBox(height: 34),

              const _TrustLine(),
            ],
          ),
        ),
      ),
    );
  }
}

/// The small header above the question: wordmark on the left, account on
/// the right. No coloured band - the page should be quiet until the search.
class _TopBar extends StatelessWidget {
  final AuthUser? user;
  const _TopBar({required this.user});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(child: WimbWordmark(color: WimbColors.ink)),
        _AccountButton(user: user),
      ],
    );
  }
}

/// The account avatar, and the sheet behind it. Kept as its own widget so
/// the home build method stays a layout, not a pile of sheet code.
class _AccountButton extends ConsumerWidget {
  final AuthUser? user;
  const _AccountButton({required this.user});

  void _openSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: WimbColors.cardCream,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 4, 22, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionLabel('Account'),
              if (user == null) ...[
                Text(
                  "You're using the app without an account.",
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  'Everything here works as it is. An account only adds saved '
                  'places and lets you report a bus the feed has missed.',
                  style: Theme.of(sheetContext).textTheme.bodySmall,
                ),
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    ref.read(authControllerProvider.notifier).showSignIn();
                  },
                  child: const Text('Sign in or create an account'),
                ),
              ] else ...[
                Text(user!.displayName, style: Theme.of(sheetContext).textTheme.titleLarge),
                Text(user!.email, style: Theme.of(sheetContext).textTheme.bodySmall),
                const SizedBox(height: 18),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    ref.read(authControllerProvider.notifier).signOut();
                  },
                  icon: const Icon(Icons.logout, size: 18),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: WimbColors.dtcRed,
                    minimumSize: const Size.fromHeight(48),
                  ),
                  label: const Text('Sign out'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return InkWell(
      onTap: () => _openSheet(context, ref),
      customBorder: const CircleBorder(),
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: WimbColors.surfaceMuted,
          border: Border.all(color: WimbColors.hairline),
        ),
        child: user == null
            ? const Icon(Icons.person_outline, color: WimbColors.ink, size: 21)
            : Center(
                child: Text(
                  user!.firstName.characters.first.toUpperCase(),
                  style: const TextStyle(
                    color: WimbColors.ink,
                    fontWeight: FontWeight.w700,
                    fontSize: 17,
                  ),
                ),
              ),
      ),
    );
  }
}

/// The one control the home screen is really for. A white pill with a soft
/// edge, a search icon, and a black arrow at the far end - the reference's
/// single-anchor layout, in this app's own colours.
class _SearchCard extends StatelessWidget {
  final VoidCallback onTap;
  const _SearchCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: WimbColors.cardCream,
      borderRadius: BorderRadius.circular(WimbRadius.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(WimbRadius.pill),
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(WimbRadius.pill),
            border: Border.all(color: WimbColors.hairline),
            boxShadow: const [
              BoxShadow(
                color: WimbColors.shadow,
                blurRadius: 20,
                offset: Offset(0, 7),
              ),
            ],
          ),
          child: Row(
            children: [
              const Icon(Icons.search, size: 23, color: WimbColors.ink),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Where are you headed?',
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w600,
                        color: WimbColors.ink,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      'Search a stop, route or place',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              Container(
                width: 38,
                height: 38,
                decoration: const BoxDecoration(
                  color: WimbColors.ink,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.arrow_forward, size: 19, color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One of the two quieter ways in. Equal-width tiles because they are
/// peers, and two peers read faster side by side.
class _QuickTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _QuickTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: WimbColors.surfaceMuted,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: WimbColors.ink, size: 21),
              ),
              const SizedBox(height: 14),
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 3),
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A route in the horizontal row. The board is the visual anchor, with the
/// destination underneath so the number is not the only thing to go on.
class _PopularRouteCard extends StatelessWidget {
  final RouteSuggestion route;
  const _PopularRouteCard({required this.route});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 156,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => RouteStopsScreen(route: route)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: RouteBoard(routeName: route.routeShortName, compact: true),
                ),
                const SizedBox(height: 9),
                Text(
                  route.routeDesc,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    height: 1.3,
                    color: WimbColors.inkMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One quiet line at the bottom, repeated from the rest of the app: times
/// are windows, not point estimates.
class _TrustLine extends StatelessWidget {
  const _TrustLine();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 1),
          child: TrustDots(level: 'high', showLabel: false),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'Every time is a range, not a guess. The window says how much '
            'history stands behind it.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
