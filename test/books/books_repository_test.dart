import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/repositories/books_repository.dart';

class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter({this.reply});

  final requests = <RequestOptions>[];
  final Future<ResponseBody> Function(RequestOptions, int)? reply;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (reply != null) return reply!(options, requests.length);
    final Object body = switch (options.uri.pathSegments.last) {
      'Search' => {'books': [], 'has_more': false},
      'Releases' => {'releases': []},
      'Download' => {'status': 'queued'},
      _ => {},
    };
    return _jsonResponse(body);
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

const _jobId = 'opaqueJobId1234567890';

BooksRepository _repository(
  _RecordingAdapter adapter, {
  Duration deadline = const Duration(seconds: 240),
  Future<void> Function(Duration)? delay,
}) => BooksRepository.forTest(
  'https://jellyfin.example',
  'test-token',
  Dio(BaseOptions(receiveTimeout: const Duration(seconds: 35)))
    ..httpClientAdapter = adapter,
  username: 'owner',
  releaseDeadline: deadline,
  releaseDelay: delay ?? Future.delayed,
);

BookResult _resultWithCover(Object? cover) => BookResult.fromJson({
  'provider': 'openlibrary',
  'provider_id': 'book-1',
  'title': 'Example',
  'authors': ['First Author', 'Second Author'],
  'publish_year': 2020,
  'cover_url': cover,
});

void main() {
  test(
    'German exact-title editions outrank translations and summaries',
    () async {
      final adapter = _RecordingAdapter(
        reply: (request, _) async => _jsonResponse({
          'books': [
            {
              'provider': 'openlibrary',
              'provider_id': 'translation',
              'title': 'Metamorphosis',
              'authors': ['Franz Kafka'],
              'language': 'jpn',
            },
            {
              'provider': 'openlibrary',
              'provider_id': 'summary',
              'title': 'Die Verwandlung: Zusammenfassung',
              'authors': ['Other'],
              'language': 'ger',
            },
            {
              'provider': 'openlibrary',
              'provider_id': 'original',
              'title': 'Die Verwandlung',
              'authors': ['Franz Kafka'],
              'language': 'ger',
            },
            {
              'provider': 'openlibrary',
              'provider_id': 'edition',
              'title': 'Die Verwandlung',
              'authors': ['Franz Kafka'],
              'language': 'eng',
            },
          ],
          'has_more': false,
        }),
      );
      final page = await _repository(adapter)
          .search('Die Verwandlung', BooksMediaType.ebook);
      expect(page.books.map((item) => item.id), [
        'original',
        'edition',
        'summary',
        'translation',
      ]);
      expect(page.books.first.language, 'ger');
    },
  );

  test('decodes Shelfmark covers and accepts only public HTTPS images', () {
    const publicCover = 'https://covers.openlibrary.org/b/id/123-L.jpg';
    String wrapped(String url) =>
        '/api/covers/book-1?url=${base64Url.encode(utf8.encode(url)).replaceAll('=', '')}';

    expect(_resultWithCover(wrapped(publicCover)).coverUrl, publicCover);
    expect(_resultWithCover(publicCover).coverUrl, publicCover);
    for (final unsafe in [
      'http://covers.openlibrary.org/cover.jpg',
      'https://localhost/cover.jpg',
      'https://192.168.1.4/cover.jpg',
      'https://books.internal/cover.jpg',
      'https://user@covers.openlibrary.org/cover.jpg',
      'https://covers.openlibrary.org:8443/cover.jpg',
    ]) {
      expect(_resultWithCover(wrapped(unsafe)).coverUrl, isNull);
      expect(_resultWithCover(unsafe).coverUrl, isNull);
    }
    expect(_resultWithCover('/api/covers/book-1?url=%%%').coverUrl, isNull);
    expect(
      _resultWithCover(
        '/other?url=${base64Url.encode(utf8.encode(publicCover))}',
      ).coverUrl,
      isNull,
    );
    expect(_resultWithCover(null).coverUrl, isNull);
  });

  test(
    'search, releases, status and download use bounded authenticated calls',
    () async {
      final adapter = _RecordingAdapter();
      final dio = Dio(BaseOptions(receiveTimeout: const Duration(seconds: 35)))
        ..httpClientAdapter = adapter;
      final repository = BooksRepository.forTest(
        'https://jellyfin.example',
        'test-token',
        dio,
        username: 'owner',
      );
      final book = _resultWithCover(null);
      const release = BookRelease(
        source: 'prowlarr',
        sourceId: 'release-1',
        title: 'Example EPUB',
        language: 'en',
      );

      await repository.search('Example', BooksMediaType.ebook);
      await repository.releases(book, BooksMediaType.ebook);
      await repository.active();
      await repository.download(book, release, BooksMediaType.ebook);

      for (final request in adapter.requests) {
        expect(request.uri.host, 'jellyfin.example');
        expect(
          request.headers['Authorization'],
          'MediaBrowser Token="test-token"',
        );
        expect(request.receiveTimeout, const Duration(seconds: 35));
      }
      final body =
          adapter.requests
                  .singleWhere(
                    (request) => request.uri.path.endsWith('/Download'),
                  )
                  .data
              as Map<String, dynamic>;
      expect(body, containsPair('author', 'First Author, Second Author'));
      expect(body, containsPair('source', 'prowlarr'));
      expect(body, containsPair('title', 'Example'));
      expect(body, containsPair('year', 2020));
      expect(body, containsPair('language', 'en'));
    },
  );

  test(
    'polls 202 jobs with only job_id and returns the 200 releases',
    () async {
      final delays = <Duration>[];
      final adapter = _RecordingAdapter(
        reply: (request, count) async => count < 3
            ? _jsonResponse({
                'status': 'pending',
                'job_id': _jobId,
                'retry_after': count == 1 ? 2 : 99,
              }, status: 202)
            : _jsonResponse({
                'releases': [
                  {
                    'source': 'prowlarr',
                    'source_id': 'opaque-release',
                    'title': 'EPUB',
                  },
                ],
              }),
      );
      final releases = await _repository(
        adapter,
        delay: (duration) async => delays.add(duration),
      ).releases(_resultWithCover(null), BooksMediaType.ebook);

      expect(releases.single.sourceId, 'opaque-release');
      expect(delays, [const Duration(seconds: 2), const Duration(seconds: 5)]);
      expect(adapter.requests, hasLength(3));
      expect(adapter.requests.first.queryParameters, {
        'provider': 'openlibrary',
        'book_id': 'book-1',
        'content_type': 'ebook',
        'title': 'Example',
        'languages': 'de,en',
        'author': 'First Author, Second Author',
      });
      for (final request in adapter.requests.skip(1)) {
        expect(request.queryParameters, {'job_id': _jobId});
      }
      for (final request in adapter.requests) {
        expect(request.uri.host, 'jellyfin.example');
        expect(request.uri.path, '/Moonfin/Books/v1/Releases');
        expect(
          request.headers['Authorization'],
          'MediaBrowser Token="test-token"',
        );
        expect(request.receiveTimeout, const Duration(seconds: 35));
      }
    },
  );

  test('rejects malformed pending and completed replies', () async {
    final malformed = <Object>[
      {'job_id': _jobId, 'retry_after': 2},
      {'status': 'pending', 'job_id': '../outside', 'retry_after': 2},
      {'status': 'pending', 'job_id': _jobId, 'retry_after': 0},
      {'status': 'pending', 'job_id': _jobId, 'retry_after': '2'},
      {'status': 'pending', 'job_id': _jobId, 'retry_after': 1.5},
    ];
    for (final body in malformed) {
      final adapter = _RecordingAdapter(
        reply: (_, _) async => _jsonResponse(body, status: 202),
      );
      await expectLater(
        _repository(
          adapter,
          delay: (_) async {},
        ).releases(_resultWithCover(null), BooksMediaType.ebook),
        throwsA(
          isA<BooksApiException>().having((e) => e.statusCode, 'status', 0),
        ),
      );
      expect(adapter.requests, hasLength(1));
    }
    for (final body in <Object>[
      {},
      {
        'releases': [null],
      },
    ]) {
      final adapter = _RecordingAdapter(
        reply: (_, _) async => _jsonResponse(body),
      );
      await expectLater(
        _repository(adapter)
            .releases(_resultWithCover(null), BooksMediaType.ebook),
        throwsA(
          isA<BooksApiException>().having((e) => e.statusCode, 'status', 0),
        ),
      );
    }
  });

  test('rejects a changed pending job_id', () async {
    final adapter = _RecordingAdapter(
      reply: (_, count) async => _jsonResponse({
        'status': 'pending',
        'job_id': count == 1 ? _jobId : 'differentJobId123456789',
        'retry_after': 1,
      }, status: 202),
    );
    await expectLater(
      _repository(
        adapter,
        delay: (_) async {},
      ).releases(_resultWithCover(null), BooksMediaType.ebook),
      throwsA(
        isA<BooksApiException>().having((e) => e.statusCode, 'status', 0),
      ),
    );
    expect(adapter.requests, hasLength(2));
  });

  test('preserves HTTP errors from polling', () async {
    final adapter = _RecordingAdapter(
      reply: (_, count) async => count == 1
          ? _jsonResponse({
              'status': 'pending',
              'job_id': _jobId,
              'retry_after': 1,
            }, status: 202)
          : _jsonResponse({'error': 'busy'}, status: 429),
    );
    await expectLater(
      _repository(
        adapter,
        delay: (_) async {},
      ).releases(_resultWithCover(null), BooksMediaType.ebook),
      throwsA(
        isA<BooksApiException>().having((e) => e.statusCode, 'status', 429),
      ),
    );
  });

  test('overall deadline covers pending delay and a stalled request', () async {
    final pending = _RecordingAdapter(
      reply: (_, _) async => _jsonResponse({
        'status': 'pending',
        'job_id': _jobId,
        'retry_after': 1,
      }, status: 202),
    );
    await expectLater(
      _repository(
        pending,
        deadline: const Duration(milliseconds: 100),
      ).releases(_resultWithCover(null), BooksMediaType.ebook),
      throwsA(
        isA<BooksApiException>().having((e) => e.statusCode, 'status', 0),
      ),
    );
    expect(pending.requests, hasLength(1));

    final stalled = _RecordingAdapter(
      reply: (_, _) => Completer<ResponseBody>().future,
    );
    await expectLater(
      _repository(
        stalled,
        deadline: const Duration(milliseconds: 100),
      ).releases(_resultWithCover(null), BooksMediaType.ebook),
      throwsA(
        isA<BooksApiException>().having((e) => e.statusCode, 'status', 0),
      ),
    );
    expect(stalled.requests, hasLength(1));
  });

  test(
    'releases request German and English despite Italian book metadata',
    () async {
      final adapter = _RecordingAdapter();
      final repository = _repository(adapter);
      final book = BookResult.fromJson({
        'provider': 'openlibrary',
        'provider_id': 'book-1',
        'title': 'Inferno',
        'authors': ['Dante Alighieri'],
        'language': 'ita',
      });
      await repository.releases(book, BooksMediaType.ebook);
      await repository.releases(
        const BookResult(
          provider: 'openlibrary',
          id: '2',
          title: 'Bare',
          authors: [],
        ),
        BooksMediaType.ebook,
      );

      final withContext = adapter.requests[0].uri.queryParameters;
      expect(withContext['author'], 'Dante Alighieri');
      expect(withContext['languages'], 'de,en');
      final bare = adapter.requests[1].uri.queryParameters;
      expect(bare.containsKey('author'), isFalse);
      expect(bare['languages'], 'de,en');
    },
  );

  test('assessReleases ranks the work first and marks weak matches', () {
    const book = BookResult(
      provider: 'openlibrary',
      id: '1',
      title: 'Inferno',
      authors: ['Dante Alighieri'],
    );
    const dante = BookRelease(
      source: 'p',
      sourceId: 'dante-unknown',
      title: 'Dante Alighieri - Inferno',
    );
    const danteEn = BookRelease(
      source: 'p',
      sourceId: 'dante-en',
      title: 'Inferno by Dante Alighieri',
      format: 'epub',
      language: 'en',
    );
    const danteDe = BookRelease(
      source: 'p',
      sourceId: 'dante-de',
      title: 'Dante Alighieri: Inferno',
      format: 'epub',
      language: 'German',
    );
    const danteIt = BookRelease(
      source: 'p',
      sourceId: 'dante-it',
      title: 'Dante Alighieri: Inferno',
      format: 'epub',
      language: 'ita',
    );
    const other = BookRelease(
      source: 'p',
      sourceId: 'lara',
      title: 'Inferno (Lara Steel)',
      format: 'epub',
      language: 'de',
    );
    const comic = BookRelease(
      source: 'p',
      sourceId: 'comic',
      title: 'Event Horizon: Inferno #1',
    );

    final ranked = assessReleases(book, [
      other,
      comic,
      danteEn,
      dante,
      danteDe,
      danteIt,
    ], BooksMediaType.ebook);

    expect(ranked.map((item) => item.release.sourceId), [
      'dante-en', // the right work stays ahead regardless of edition language
      'dante-unknown',
      'dante-de',
      'dante-it', // same work remains above unrelated books, but cannot be selected
      'lara', // other work, but not ranked above matching works
      'comic',
    ]);
    final byId = {for (final item in ranked) item.release.sourceId: item};
    expect(byId['dante-de']!.likely, isTrue);
    expect(byId['dante-unknown']!.likely, isTrue);
    expect(byId['dante-en']!.likely, isTrue);
    expect(byId['dante-en']!.formatMismatch, isFalse);
    expect(byId['dante-it']!.languageMismatch, isTrue);
    expect(byId['dante-it']!.likely, isFalse);
    expect(
      assessReleases(book, const [
        BookRelease(
          source: 'p',
          sourceId: 'labelled-it',
          title: 'Dante Alighieri Inferno',
          format: 'epub',
          language: 'Italian (IT)',
        ),
      ], BooksMediaType.ebook).single.languageMismatch,
      isTrue,
    );
    expect(byId['lara']!.likely, isFalse);
    expect(byId['comic']!.likely, isFalse);
  });

  test('assessment rejects a known wrong media format', () {
    const book = BookResult(
      provider: 'openlibrary',
      id: '1',
      title: 'Inferno',
      authors: ['Dante Alighieri'],
    );
    final ranked = assessReleases(book, const [
      BookRelease(
        source: 'p',
        sourceId: 'audio',
        title: 'Dante Alighieri Inferno',
        format: 'mp3',
      ),
      BookRelease(
        source: 'p',
        sourceId: 'pdf',
        title: 'Dante Alighieri Inferno',
        format: 'pdf',
      ),
      BookRelease(
        source: 'p',
        sourceId: 'unknown-format',
        title: 'Dante Alighieri Inferno',
        format: 'exe',
      ),
    ], BooksMediaType.ebook);

    expect(ranked.first.release.sourceId, 'pdf');
    expect(ranked.last.release.sourceId, 'audio');
    expect(ranked.last.formatMismatch, isTrue);
    expect(
      ranked
          .where((item) => item.release.sourceId == 'unknown-format')
          .single
          .formatMismatch,
      isFalse,
    );
  });

  test('subtitle and apostrophe spelling do not hide the right work', () {
    const book = BookResult(
      provider: 'openlibrary',
      id: '1',
      title: "Harry Potter and the Philosopher's Stone: A Novel",
      authors: ['J. K. Rowling'],
    );
    final ranked = assessReleases(book, const [
      BookRelease(
        source: 'p',
        sourceId: 'match',
        title: 'Harry Potter and the Philosophers Stone - Rowling',
        format: 'epub',
      ),
    ], BooksMediaType.ebook);

    expect(ranked.single.likely, isTrue);
  });

  test(
    'search with an author sends title/author fields and no free text',
    () async {
      final adapter = _RecordingAdapter();
      final repository = _repository(adapter);

      await repository.search(
        'Inferno',
        BooksMediaType.ebook,
        author: ' Dante ',
      );
      await repository.search('', BooksMediaType.ebook, author: 'Dante');
      await repository.search('Inferno', BooksMediaType.ebook);
      await repository.search('Inferno', BooksMediaType.ebook, author: '  ');

      final titleAndAuthor = adapter.requests[0].uri.queryParameters;
      expect(titleAndAuthor['title'], 'Inferno');
      expect(titleAndAuthor['author'], 'Dante');
      expect(titleAndAuthor.containsKey('query'), isFalse);
      final authorOnly = adapter.requests[1].uri.queryParameters;
      expect(authorOnly['author'], 'Dante');
      expect(authorOnly.containsKey('title'), isFalse);
      expect(authorOnly.containsKey('query'), isFalse);
      for (final plain in adapter.requests.skip(2)) {
        expect(plain.uri.queryParameters['query'], 'Inferno');
        expect(plain.uri.queryParameters.containsKey('author'), isFalse);
        expect(plain.uri.queryParameters.containsKey('title'), isFalse);
      }
    },
  );
}
