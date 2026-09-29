// The two halves of folding a series' seasons, cast, crew, studios and
// recommendations into the page itself: the nested row the More Actions menu
// offers for them, and the season strip that replaces the seasons teaser.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:mocktail/mocktail.dart';
import 'package:moonfin/data/models/aggregated_item.dart';
import 'package:moonfin/l10n/app_localizations.dart';
import 'package:moonfin/preference/user_preferences.dart';
import 'package:moonfin/ui/screens/detail/item_detail_screen.dart';
import 'package:moonfin/ui/widgets/media_card.dart';
import 'package:moonfin/util/platform_detection.dart';
import 'package:server_core/server_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ImageApi extends Mock implements ImageApi {}

List<DetailOverflowMenuRow> rows(int sections, int actions) =>
    DetailActionButtonsState.overflowMenuRows(
      sectionCount: sections,
      actionCount: actions,
    );

void main() {
  group('the More Actions menu rows', () {
    test('the nested section comes before the actions', () {
      // The content behind the menu is the reason a viewer opens it, so it
      // has to be the first row rather than something below the fold.
      expect(rows(1, 3), const [
        DetailOverflowMenuRow.section(0),
        DetailOverflowMenuRow.action(0),
        DetailOverflowMenuRow.action(1),
        DetailOverflowMenuRow.action(2),
      ]);
    });

    test('a row says which of the two lists it points at', () {
      expect(rows(2, 1).map((r) => r.kind), [
        DetailOverflowRowKind.section,
        DetailOverflowRowKind.section,
        DetailOverflowRowKind.action,
      ]);
    });

    test('each row points at its own source, not at a running count', () {
      // Dropping a section must not renumber the actions, or the menu would
      // run the wrong handler.
      expect(rows(1, 3).map((r) => r.index).toList(), [0, 0, 1, 2]);
    });

    test('a series with nothing to nest still gets its actions', () {
      expect(rows(0, 2), const [
        DetailOverflowMenuRow.action(0),
        DetailOverflowMenuRow.action(1),
      ]);
    });

    test('an empty menu is an empty list, not a stray row', () {
      expect(rows(0, 0), isEmpty);
    });
  });

  group('the inline season strip', () {
    late UserPreferences prefs;
    late _ImageApi imageApi;

    AggregatedItem season(String id, {int? index, int? childCount}) =>
        AggregatedItem(
          id: id,
          serverId: 's1',
          rawData: {
            'Id': id,
            'Type': 'Season',
            'Name': 'Season ${index ?? 1}',
            'IndexNumber': index ?? 1,
            'ParentIndexNumber': 1,
            'ChildCount': childCount ?? 10,
            'ImageTags': {'Primary': 'tag-$id'},
          },
        );

    List<AggregatedItem> threeSeasons() => [
      season('s1', index: 1),
      season('s2', index: 2),
      season('s3', index: 3),
    ];

    setUp(() async {
      await GetIt.instance.reset();
      SharedPreferences.setMockInitialValues({});
      final store = PreferenceStore();
      await store.init();
      prefs = UserPreferences(store);
      GetIt.instance.registerSingleton<UserPreferences>(prefs);
      PlatformDetection.setInterfaceLayout(InterfaceLayout.desktop);

      imageApi = _ImageApi();
      when(
        () => imageApi.getPrimaryImageUrl(
          any(),
          maxWidth: any(named: 'maxWidth'),
          maxHeight: any(named: 'maxHeight'),
          tag: any(named: 'tag'),
        ),
      ).thenReturn('http://server/img');
      when(
        () => imageApi.getThumbImageUrl(
          any(),
          maxWidth: any(named: 'maxWidth'),
          tag: any(named: 'tag'),
        ),
      ).thenReturn('http://server/thumb');
    });

    tearDown(() {
      PlatformDetection.setInterfaceLayout(InterfaceLayout.automatic);
      return GetIt.instance.reset();
    });

    Future<FocusNode> pump(
      WidgetTester tester, {
      List<AggregatedItem>? seasons,
      KeyEventResult Function(int index, KeyEvent event)? onItemKeyEvent,
    }) async {
      final node = FocusNode(debugLabel: 'seasonsFirst');
      addTearDown(node.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 900,
                child: DetailInlineSeasonsSection(
                  seasons: seasons ?? threeSeasons(),
                  imageApi: imageApi,
                  prefs: prefs,
                  height: 240,
                  cellWidth: 100,
                  firstItemFocusNode: node,
                  onItemKeyEvent: onItemKeyEvent,
                ),
              ),
            ),
          ),
        ),
      );
      return node;
    }

    testWidgets('it names the section and counts the seasons', (tester) async {
      await pump(tester);

      expect(find.text('Seasons'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('every season is on the page, not behind a teaser', (
      tester,
    ) async {
      await pump(tester);

      expect(find.byType(MediaCard), findsNWidgets(3));
      for (final name in ['Season 1', 'Season 2', 'Season 3']) {
        expect(find.text(name), findsOneWidget);
      }
    });

    testWidgets('a series with no seasons draws nothing', (tester) async {
      await pump(tester, seasons: const []);

      expect(find.byType(DetailInlineSeasonsSection), findsOneWidget);
      expect(find.byType(MediaCard), findsNothing);
      expect(find.text('Seasons'), findsNothing);
    });

    testWidgets('the first poster is where the host sends focus', (
      tester,
    ) async {
      final node = await pump(tester);

      expect(node.context, isNotNull);
      node.requestFocus();
      await tester.pump();
      expect(node.hasFocus, isTrue);
    });

    testWidgets('the d-pad handler hears about the poster that was focused', (
      tester,
    ) async {
      final seen = <int>[];
      final node = await pump(
        tester,
        onItemKeyEvent: (index, event) {
          if (event is KeyDownEvent) seen.add(index);
          return KeyEventResult.ignored;
        },
      );

      node.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();

      // The strip is one stop in the page's vertical chain, so the host has to
      // be told which poster the key landed on to route it.
      expect(seen, [0]);
    });

    testWidgets('the strip holds the height its host gave it', (tester) async {
      await pump(tester);

      final section = tester.getSize(find.byType(DetailInlineSeasonsSection));
      // Header plus the row, which carries a 2:3 poster per 100px width.
      expect(section.height, greaterThan(158));
      expect(tester.takeException(), isNull);
    });
  });
}
