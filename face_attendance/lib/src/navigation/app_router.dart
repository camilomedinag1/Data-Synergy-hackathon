import 'package:flutter/material.dart';

import '../screens/home_screen.dart';
import '../screens/settings_screen.dart';
// <<< CAMBIO: Importar la nueva pantalla que crearemos >>>
import '../screens/emergency_scan_screen.dart';

RouterConfig<Object> buildRouter() {
  return RouterConfig<Object>(
    routerDelegate: _AppRouterDelegate(),
    routeInformationParser: _AppRouteParser(),
    routeInformationProvider: PlatformRouteInformationProvider(
      initialRouteInformation: const RouteInformation(location: '/'),
    ),
  );
}

class _AppRouteParser extends RouteInformationParser<List<String>> {
  @override
  Future<List<String>> parseRouteInformation(
    RouteInformation routeInformation,
  ) async {
    final String location = routeInformation.location ?? '/';
    final Uri uri = Uri.parse(location);
    return uri.pathSegments;
  }
}

class _AppRouterDelegate extends RouterDelegate<List<String>>
    with ChangeNotifier, PopNavigatorRouterDelegateMixin<List<String>> {
  @override
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  List<String> _segments = const [];

  @override
  List<String>? get currentConfiguration => _segments;

  @override
  Future<void> setNewRoutePath(List<String> configuration) async {
    _segments = configuration;
  }

  void _goTo(String path) {
    _segments = path == '/' ? const [] : path.split('/').where((e) => e.isNotEmpty).toList();
    notifyListeners();
  }

  @override
  Widget build(BuildContext context) {
    // <<< CAMBIO: Añadir un bool para la nueva ruta >>>
    final bool isSettings = _segments.isNotEmpty && _segments.first == 'settings';
    final bool isEmergency = _segments.isNotEmpty && _segments.first == 'emergency';

    return Navigator(
      key: navigatorKey,
      pages: [
        MaterialPage(
          key: const ValueKey('home'),
          child: HomeScreen(
            onOpenSettings: () => _goTo('/settings'),
            // <<< CAMBIO: Añadir el callback para la nueva ruta >>>
            onOpenEmergencyScan: () => _goTo('/emergency'),
          ),
        ),
        if (isSettings)
          MaterialPage(
            key: const ValueKey('settings'),
            child: const SettingsScreen(),
          ),
        // <<< CAMBIO: Añadir la página de emergencia al stack de navegación >>>
        if (isEmergency)
          const MaterialPage(
            key: ValueKey('emergency'),
            child: EmergencyScanScreen(),
          ),
      ],
      onPopPage: (route, result) {
        if (!route.didPop(result)) {
          return false;
        }
        if (_segments.isNotEmpty) {
          _segments = const [];
          notifyListeners();
        }
        return true;
      },
    );
  }
}