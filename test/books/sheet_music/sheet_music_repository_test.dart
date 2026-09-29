import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/repositories/sheet_music_repository.dart';

class _StubAdapter implements HttpClientAdapter {
  _StubAdapter({this.reply});

  final Future<ResponseBody> Function(RequestOptions, int)? reply;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (reply != null) return reply!(options, 1);
    return _jsonResponse({'pieces': [], 'count': 0, 'truncated': false});
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _jsonResponse(Object body, {int status = 200}) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

SheetMusicRepository _repo({_StubAdapter? adapter}) {
  final dio = Dio();
  if (adapter != null) dio.httpClientAdapter = adapter;
  return SheetMusicRepository.forTest(
    'https://server.example',
    'token-123',
    dio,
  );
}

void main() {
  test('request, owner status and PDF download use Jellyfin auth', () async {
    final requests = <RequestOptions>[];
    final repository = _repo(
      adapter: _StubAdapter(
        reply: (options, _) async {
          requests.add(options);
          switch (options.uri.pathSegments.last) {
            case 'Request':
              return _jsonResponse({
                'job_id': 'a' * 32,
                'status': 'queued',
              }, status: 202);
            case 'Status':
              return _jsonResponse({'status': 'ready', 'item_id': 'b' * 32});
            case 'File':
              return ResponseBody(
                Stream.value(
                  Uint8List.fromList(utf8.encode('%PDF-1.4\nscore')),
                ),
                200,
                headers: {
                  Headers.contentTypeHeader: ['application/pdf'],
                },
              );
          }
          return _jsonResponse({'error': 'unknown'}, status: 404);
        },
      ),
    );
    const piece = SheetMusicPiece(
      id: 'mutopia:BachJS/BWV999/score',
      title: 'Prelude',
      composer: 'BachJS',
      license: 'Public Domain',
      sourceUrl: 'https://www.mutopiaproject.org/ftp/score.ly',
      pdfUrl: 'https://www.mutopiaproject.org/ftp/score-a4.pdf',
    );

    final jobId = await repository.request(piece);
    final status = await repository.status(jobId);
    final bytes = await repository.download(jobId);

    expect(jobId, 'a' * 32);
    expect(status.status, 'ready');
    expect(status.itemId, 'b' * 32);
    expect(utf8.decode(bytes), startsWith('%PDF-'));
    expect(requests.map((item) => item.uri.pathSegments.last), [
      'Request',
      'Status',
      'File',
    ]);
    expect(requests.first.data, {'id': piece.id});
    expect(
      requests.every(
        (item) =>
            item.headers['Authorization'] == 'MediaBrowser Token="token-123"',
      ),
      isTrue,
    );
  });

  test('parses pieces with provenance and per-piece license', () async {
    final repository = _repo(
      adapter: _StubAdapter(
        reply: (options, _) async => _jsonResponse({
          'pieces': [
            {
              'id': 'BachJS/BWV999/Bach_Prelude_BWV999',
              'title': 'Prelude in D Minor',
              'composer': 'BachJS',
              'opus': 'BWV 999',
              'instrument': 'Lute, Guitar',
              'style': 'Baroque',
              'license': 'Public Domain',
              'source_url': 'https://www.mutopiaproject.org/ftp/BachJS/BWV999/Bach_Prelude_BWV999/Bach_Prelude_BWV999.ly',
              'pdf_url': 'https://www.mutopiaproject.org/ftp/BachJS/BWV999/Bach_Prelude_BWV999/Bach_Prelude_BWV999-a4.pdf',
            },
          ],
          'count': 1,
        }),
      ),
    );

    final pieces = await repository.search(query: 'prelude');

    expect(pieces, hasLength(1));
    final piece = pieces.single;
    expect(piece.id, 'BachJS/BWV999/Bach_Prelude_BWV999');
    expect(piece.title, 'Prelude in D Minor');
    expect(piece.composer, 'BachJS');
    expect(piece.license, 'Public Domain');
    expect(piece.instrument, 'Lute, Guitar');
    expect(piece.sourceUrl, contains('mutopiaproject.org'));
    expect(piece.pdfUrl, endsWith('-a4.pdf'));
  });

  test('omits empty filters from the request', () async {
    RequestOptions? captured;
    final repository = _repo(
      adapter: _StubAdapter(
        reply: (options, _) async {
          captured = options;
          return _jsonResponse({'pieces': []});
        },
      ),
    );

    await repository.search(query: '  ', composer: 'Bach');

    expect(captured!.queryParameters, {'composer': 'Bach'});
    expect(captured!.uri.path, endsWith('/Moonfin/Books/v1/SheetMusic'));
  });

  test('auth header uses the Jellyfin media browser format', () async {
    RequestOptions? captured;
    final repository = _repo(
      adapter: _StubAdapter(
        reply: (options, _) async {
          captured = options;
          return _jsonResponse({'pieces': []});
        },
      ),
    );

    await repository.search(query: 'x');

    expect(
      captured!.headers['Authorization'],
      'MediaBrowser Token="token-123"',
    );
  });

  test('non-2xx raises SheetMusicApiException', () async {
    final repository = _repo(
      adapter: _StubAdapter(
        reply: (options, _) async =>
            _jsonResponse({'error': 'no'}, status: 503),
      ),
    );

    await expectLater(
      repository.search(query: 'x'),
      throwsA(isA<SheetMusicApiException>()),
    );
  });

  test('malformed body raises SheetMusicApiException', () async {
    final repository = _repo(
      adapter: _StubAdapter(
        reply: (options, _) async => _jsonResponse({'unexpected': true}),
      ),
    );

    await expectLater(
      repository.search(query: 'x'),
      throwsA(isA<SheetMusicApiException>()),
    );
  });
}
