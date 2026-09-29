import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:moonfin/auth/models/server.dart';
import 'package:moonfin/auth/models/user.dart';
import 'package:moonfin/auth/repositories/auth_repository.dart';
import 'package:moonfin/auth/repositories/server_repository.dart';
import 'package:moonfin/auth/repositories/server_user_repository.dart';
import 'package:moonfin/auth/repositories/session_repository.dart';
import 'package:moonfin/auth/store/authentication_preferences.dart';
import 'package:moonfin/data/services/media_server_client_factory.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:moonfin/ui/screens/auth/server_screen.dart';
import 'package:moonfin/ui/theme/app_theme.dart';
import 'package:moonfin_design/moonfin_design.dart';
import 'package:server_core/server_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestServers extends Fake implements ServerRepository {
  final Server server;

  _TestServers(this.server);

  @override
  Future<void> loadStoredServers() async {}

  @override
  Server? getServer(String id) => id == server.id ? server : null;
}

class _TestUsers extends Fake implements ServerUserRepository {
  final List<PrivateUser> stored;
  final List<PublicUser> public;

  _TestUsers({this.stored = const [], required this.public});

  @override
  List<PrivateUser> getStoredServerUsers(String serverId) => stored;

  @override
  Future<List<PublicUser>> getPublicServerUsers(Server server) async => public;
}

class _UnusedAuth extends Fake implements AuthRepository {}

class _UnusedSession extends Fake implements SessionRepository {}

class _UnusedClientFactory extends Fake implements MediaServerClientFactory {}

class _AuthPreferences extends Fake implements AuthenticationPreferences {
  @override
  bool get shouldAlwaysAuthenticate => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PreferenceStore store;

  setUp(() async {
    await GetIt.instance.reset();
    SharedPreferences.setMockInitialValues({});
    store = PreferenceStore();
    await store.init();
    GetIt.instance.registerSingleton<PreferenceStore>(store);
    GetIt.instance.registerSingleton<UserPreferences>(UserPreferences(store));
    GetIt.instance.registerSingleton<AuthRepository>(_UnusedAuth());
    GetIt.instance.registerSingleton<SessionRepository>(_UnusedSession());
    GetIt.instance.registerSingleton<MediaServerClientFactory>(
      _UnusedClientFactory(),
    );
    GetIt.instance.registerSingleton<AuthenticationPreferences>(
      _AuthPreferences(),
    );
    ThemeRegistry.setActiveById(ThemeRegistry.moonfinId);
  });

  tearDown(() => GetIt.instance.reset());

  Server server(String address) => Server(
    id: 'server-1',
    name: 'Test server',
    address: address,
    version: '12',
    serverType: ServerType.jellyfin,
    dateAdded: DateTime(2026),
  );

  List<PublicUser> users() => const [
    PublicUser(
      id: 'kids',
      name: 'Kids',
      serverId: 'server-1',
      hasPassword: true,
    ),
    PublicUser(
      id: 'adult',
      name: 'Adult',
      serverId: 'server-1',
      hasPassword: true,
    ),
  ];

  Future<GoRouter> showChooser(
    WidgetTester tester,
    Server server, {
    List<PrivateUser> stored = const [],
    List<PublicUser>? publicUsers,
  }) async {
    GetIt.instance.registerSingleton<ServerRepository>(_TestServers(server));
    GetIt.instance.registerSingleton<ServerUserRepository>(
      _TestUsers(stored: stored, public: publicUsers ?? users()),
    );
    final router = GoRouter(
      initialLocation: '/server?serverId=${server.id}',
      routes: [
        GoRoute(
          path: '/server',
          builder: (_, state) =>
              ServerScreen(serverId: state.uri.queryParameters['serverId']!),
        ),
        GoRoute(path: '/other', builder: (_, _) => const Text('Other screen')),
        GoRoute(
          path: '/login',
          builder: (_, state) =>
              Text('Login: ${state.uri.queryParameters['username']}'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        theme: AppTheme.buildTheme(ThemeRegistry.active),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  bool isFocused(WidgetTester tester, String name) => tester
      .widget<InkWell>(
        find.ancestor(of: find.text(name), matching: find.byType(InkWell)),
      )
      .focusNode!
      .hasFocus;

  testWidgets('watch chooser never preselects Kids when an adult exists', (
    tester,
  ) async {
    final router = await showChooser(
      tester,
      server('https://watch.tiedemann.art'),
    );

    expect(isFocused(tester, 'Kids'), isFalse);
    expect(isFocused(tester, 'Adult'), isTrue);
    expect(find.byType(ServerScreen), findsOneWidget);
    expect(store.getBool('pref_kids_initial_focus_server-1'), isNull);

    router.go('/other');
    await tester.pumpAndSettle();
    router.go('/server?serverId=server-1');
    await tester.pumpAndSettle();

    expect(isFocused(tester, 'Adult'), isTrue);
    await tester.tap(find.text('Adult'));
    await tester.pumpAndSettle();
    expect(find.text('Login: Adult'), findsOneWidget);
  });

  testWidgets('other servers keep their existing first-profile focus', (
    tester,
  ) async {
    await showChooser(tester, server('https://other.example'));

    expect(isFocused(tester, 'Kids'), isTrue);
    expect(store.getBool('pref_kids_initial_focus_server-1'), isNull);
  });

  testWidgets('existing watch users do not receive a new Kids default', (
    tester,
  ) async {
    await showChooser(
      tester,
      server('https://watch.tiedemann.art'),
      stored: [
        PrivateUser(
          id: 'adult',
          name: 'Adult',
          serverId: 'server-1',
          accessToken: 'test-only',
          lastUsed: DateTime(2026),
        ),
      ],
    );

    expect(isFocused(tester, 'Adult'), isTrue);
    expect(store.getBool('pref_kids_initial_focus_server-1'), isNull);
  });

  testWidgets('watch chooser with only Kids leaves the profile unfocused', (
    tester,
  ) async {
    await showChooser(
      tester,
      server('https://watch.tiedemann.art'),
      publicUsers: [users().first],
    );

    expect(isFocused(tester, 'Kids'), isFalse);
    expect(find.byType(ServerScreen), findsOneWidget);
  });
}
