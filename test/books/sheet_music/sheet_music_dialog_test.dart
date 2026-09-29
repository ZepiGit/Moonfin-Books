import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/repositories/sheet_music_repository.dart';
import 'package:moonfin/ui/screens/books/sheet_music_search_dialog.dart';

class _Catalog extends SheetMusicRepository {
  _Catalog() : super.forTest('https://server.example', 'test-token', Dio());

  @override
  Future<List<SheetMusicPiece>> search({
    String? query,
    String? composer,
    String? instrument,
  }) async => const [
    SheetMusicPiece(
      id: 'BachJS/BWV999/score',
      title: 'Prelude in D Minor',
      composer: 'BachJS',
      instrument: 'Lute, Guitar',
      license: 'Public Domain',
      sourceUrl: 'https://www.mutopiaproject.org/ftp/BachJS/BWV999/score.ly',
      pdfUrl: 'https://www.mutopiaproject.org/ftp/BachJS/BWV999/score-a4.pdf',
    ),
  ];
}

void main() {
  testWidgets('sheet music search shows provenance before any PDF request', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        home: Scaffold(body: SheetMusicSearchDialog(repository: _Catalog())),
      ),
    );

    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();

    expect(find.text('Prelude in D Minor'), findsOneWidget);
    expect(find.text('License: Public Domain'), findsOneWidget);
    expect(
      find.textContaining('Source: https://www.mutopiaproject.org/ftp/'),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilledButton, 'Request'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Preview'), findsOneWidget);
  });
}
