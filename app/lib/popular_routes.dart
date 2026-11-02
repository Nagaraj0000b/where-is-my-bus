// The handful of routes shown before anyone searches.
//
// Shared by the home screen (as a horizontal row) and the Routes tab (as
// the "popular transit routes" list), so the two cannot drift apart. These
// are real identifiers from the loaded Delhi snapshot, kept as a static
// shortcut rather than a database query: the home screen has to draw
// instantly and work with no network.

import 'api_client.dart';

final popularRoutes = <RouteSuggestion>[
  RouteSuggestion(
    routeId: '1992',
    routeShortName: '500UP',
    routeDesc: 'New Delhi Railway Station Gate 2 to Saket J Block',
  ),
  RouteSuggestion(
    routeId: '1991',
    routeShortName: '500DOWN',
    routeDesc: 'Saket J Block to New Delhi Railway Station Gate 2',
  ),
  RouteSuggestion(
    routeId: '2232',
    routeShortName: '764UP',
    routeDesc: 'Jharoda Kalan Border to Nehru Place Terminal',
  ),
  RouteSuggestion(
    routeId: '2229',
    routeShortName: '764DOWN',
    routeDesc: 'Nehru Place Terminal to Jharoda Kalan Border',
  ),
  RouteSuggestion(
    routeId: '2050',
    routeShortName: '534UP',
    routeDesc: 'ISBT Anand Vihar Terminal to Mehrauli Terminal',
  ),
  RouteSuggestion(
    routeId: '2048',
    routeShortName: '534DOWN',
    routeDesc: 'Mehrauli Terminal to ISBT Anand Vihar',
  ),
  RouteSuggestion(
    routeId: '2127',
    routeShortName: '615UP',
    routeDesc: 'Minto Road Terminal to Poorvanchal Hostel (JNU)',
  ),
];
