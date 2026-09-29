import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:server_core/server_core.dart';

/// Shelfmark data stays separate from Jellyfin library items. All calls use the
/// current Jellyfin origin and token. Public HTTPS cover URLs are display only.
class BooksRepository {
  BooksRepository(
    MediaServerClient client, {
    required this.username,
    @visibleForTesting Dio? dio,
  }) : _baseUrl = client.baseUrl,
       _token = client.accessToken ?? '',
       _releaseDeadline = const Duration(seconds: 240),
       _releaseDelay = Future.delayed,
       _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 8),
               receiveTimeout: const Duration(seconds: 35),
               sendTimeout: const Duration(seconds: 8),
             ),
           );

  @visibleForTesting
  BooksRepository.forTest(
    String baseUrl,
    String token,
    Dio dio, {
    this.username = '',
    Duration releaseDeadline = const Duration(seconds: 240),
    Future<void> Function(Duration) releaseDelay = Future.delayed,
  }) : _baseUrl = baseUrl,
       _token = token,
       // ignore: prefer_initializing_formals
       _releaseDeadline = releaseDeadline,
       // ignore: prefer_initializing_formals
       _releaseDelay = releaseDelay,
       _dio = dio;

  final String _baseUrl;
  final String _token;
  final String username;
  final Dio _dio;
  final Duration _releaseDeadline;
  final Future<void> Function(Duration) _releaseDelay;

  String get _root =>
      '${_baseUrl.replaceFirst(RegExp(r'/$'), '')}/Moonfin/Books/v1';
  Options get _options => Options(
    headers: {'Authorization': 'MediaBrowser Token="$_token"'},
    contentType: Headers.jsonContentType,
    followRedirects: false,
    validateStatus: (_) => true,
  );

  Future<({int statusCode, dynamic data})> _request(
    String path, {
    Map<String, dynamic>? query,
    Object? body,
    Duration? receiveTimeout,
  }) async {
    if (_token.isEmpty || _baseUrl.isEmpty) throw const BooksApiException(401);
    try {
      final response = body == null
          ? await _dio.get(
              '$_root/$path',
              queryParameters: query,
              options: _options.copyWith(receiveTimeout: receiveTimeout),
            )
          : await _dio.post('$_root/$path', data: body, options: _options);
      final code = response.statusCode ?? 0;
      if (code < 200 || code >= 300) throw BooksApiException(code);
      var data = response.data;
      // The current proxy may serialize a JSON body as a JSON string.
      for (var i = 0; i < 2 && data is String; i++) {
        data = jsonDecode(data);
      }
      return (statusCode: code, data: data);
    } on BooksApiException {
      rethrow;
    } on DioException {
      throw const BooksApiException(0);
    } on FormatException {
      throw const BooksApiException(0);
    }
  }

  Future<void> status() async {
    await _request('Status');
  }

  Future<BooksSearchPage> search(
    String query,
    BooksMediaType type, {
    int page = 1,
    String? author,
  }) async {
    final byAuthor = author != null && author.trim().isNotEmpty;
    final text = query.trim();
    final data = _map(
      (await _request(
        'Search',
        query: {
          // A targeted search sends title/author fields and no free text,
          // because Shelfmark would otherwise add the text as an extra `q`.
          if (byAuthor) ...{
            if (text.isNotEmpty) 'title': _limit(text, 300),
            'author': _limit(author.trim(), 300),
          } else
            'query': query,
          'content_type': type.wire,
          'page': page,
          'limit': 40,
        },
      )).data,
    );
    final books = _list(data['books']).map(BookResult.fromJson).toList();
    final wantedTitle = _tokens(query).join(' ');
    if (wantedTitle.isNotEmpty) {
      final indexed = books.indexed.toList();
      int score(BookResult book) {
        final title = _tokens(book.title).join(' ');
        final titleScore = title == wantedTitle
            ? 100
            : title.startsWith('$wantedTitle ')
            ? 50
            : title.contains(wantedTitle)
            ? 20
            : 0;
        final language = book.language?.toLowerCase().trim();
        final languageScore =
            const {'de', 'deu', 'ger', 'german'}.contains(language)
            ? 8
            : const {'en', 'eng', 'english'}.contains(language)
            ? 2
            : 0;
        return titleScore + languageScore;
      }

      indexed.sort((a, b) {
        final comparison = score(b.$2).compareTo(score(a.$2));
        return comparison != 0 ? comparison : a.$1.compareTo(b.$1);
      });
      books
        ..clear()
        ..addAll(indexed.map((row) => row.$2));
    }
    return BooksSearchPage(
      books: books,
      hasMore: data['has_more'] == true,
      page: (data['page'] as num?)?.toInt() ?? page,
    );
  }

  Future<List<BookRelease>> releases(
    BookResult book,
    BooksMediaType type,
  ) async {
    final timer = Stopwatch()..start();
    Map<String, dynamic> query = {
      'provider': book.provider,
      'book_id': book.id,
      'content_type': type.wire,
      'title': book.title,
      'languages': 'de,en',
      // Shelfmark uses author for manual/source searches; metadata providers
      // resolve their own authors from book_id. Keep the field for those paths.
      if (book.authors.isNotEmpty)
        'author': _limit(book.authors.join(', '), 300),
    };
    String? jobId;
    while (true) {
      Duration remaining() => _releaseDeadline - timer.elapsed;
      if (remaining() <= Duration.zero) throw const BooksApiException(0);
      final response = await _request(
        'Releases',
        query: query,
        receiveTimeout: const Duration(seconds: 35),
      ).timeout(remaining(), onTimeout: () => throw const BooksApiException(0));
      if (response.data is! Map) throw const BooksApiException(0);
      final data = _map(response.data);
      if (response.statusCode == 200) {
        if (data['releases'] is! List ||
            (data['releases'] as List).any((item) => item is! Map)) {
          throw const BooksApiException(0);
        }
        return _list(data['releases']).map(BookRelease.fromJson).toList();
      }
      if (response.statusCode != 202) throw const BooksApiException(0);
      final pendingId = data['job_id'];
      final retryAfter = data['retry_after'];
      if (data['status'] != 'pending' ||
          pendingId is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(pendingId) ||
          (jobId != null && pendingId != jobId) ||
          retryAfter is! int ||
          retryAfter < 1) {
        throw const BooksApiException(0);
      }
      jobId = pendingId;
      query = {'job_id': jobId};
      final delay = Duration(seconds: retryAfter.clamp(1, 5));
      if (remaining() <= delay) throw const BooksApiException(0);
      await _releaseDelay(
        delay,
      ).timeout(remaining(), onTimeout: () => throw const BooksApiException(0));
    }
  }

  Future<List<BookDownload>> active() async {
    if (username.isEmpty) return const [];
    final data = _map((await _request('Status')).data);
    final entries = <BookDownload>[];
    for (final group in data.entries) {
      if (group.value is! Map) continue;
      for (final task in (group.value as Map).entries) {
        final value = _map(task.value);
        if (value['username'] != username) continue;
        entries.add(
          BookDownload(
            id: task.key.toString(),
            title:
                _string(value['title']) ??
                _string(value['book_title']) ??
                task.key.toString(),
            status: group.key,
            progress: (value['progress'] as num?)?.toDouble(),
          ),
        );
      }
    }
    return entries;
  }

  Future<void> download(
    BookResult book,
    BookRelease release,
    BooksMediaType type,
  ) async {
    final data = _map(
      (await _request(
        'Download',
        body: {
          'source': release.source,
          'source_id': release.sourceId,
          'title': book.title,
          if (book.authors.isNotEmpty) 'author': book.authors.join(', '),
          if (book.year != null) 'year': book.year,
          if (release.language != null) 'language': release.language,
          'content_type': type.wire,
          if (release.format != null) 'format': release.format,
          if (release.size != null) 'size': release.size,
        },
      )).data,
    );
    if (data['status'] != 'queued') throw const BooksApiException(0);
  }
}

class BooksApiException implements Exception {
  const BooksApiException(this.statusCode);
  final int statusCode;
}

enum BooksMediaType {
  ebook,
  audiobook;

  String get wire => name;
}

Map<String, dynamic> _map(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
List<Map<String, dynamic>> _list(dynamic value) => value is List
    ? value
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList()
    : <Map<String, dynamic>>[];
String? _string(dynamic value) =>
    value is String && value.trim().isNotEmpty ? value : null;
String _limit(String value, int max) =>
    value.length <= max ? value : value.substring(0, max);

class BooksSearchPage {
  const BooksSearchPage({
    required this.books,
    required this.hasMore,
    required this.page,
  });
  final List<BookResult> books;
  final bool hasMore;
  final int page;
}

class BookResult {
  const BookResult({
    required this.provider,
    required this.id,
    required this.title,
    required this.authors,
    this.year,
    this.coverUrl,
    this.language,
  });
  final String provider;
  final String id;
  final String title;
  final List<String> authors;
  final int? year;
  final String? coverUrl;
  final String? language;

  factory BookResult.fromJson(Map<String, dynamic> json) => BookResult(
    provider: _string(json['provider']) ?? '',
    id: _string(json['provider_id']) ?? '',
    title: _string(json['title']) ?? '',
    authors: json['authors'] is List
        ? (json['authors'] as List).whereType<String>().toList()
        : const [],
    year: (json['publish_year'] as num?)?.toInt(),
    coverUrl: _publicCoverUrl(json['cover_url']),
    language: _string(json['language']),
  );
}

String? _publicCoverUrl(dynamic value) {
  if (value is! String) return null;
  final cover = Uri.tryParse(value);
  if (cover == null) return null;
  if (cover.scheme == 'https') return _safePublicHttpsUrl(value);

  // Shelfmark wraps an external image URL in its own cover route. Decode it
  // locally so the app never sends the image request through the Jellyfin API.
  if (cover.scheme.isNotEmpty ||
      cover.hasAuthority ||
      cover.pathSegments.length != 3 ||
      cover.pathSegments[0] != 'api' ||
      cover.pathSegments[1] != 'covers' ||
      cover.pathSegments[2].isEmpty ||
      cover.queryParametersAll['url']?.length != 1) {
    return null;
  }
  final encoded = cover.queryParametersAll['url']!.single;
  if (encoded.isEmpty || encoded.length > 4096) return null;
  try {
    return _safePublicHttpsUrl(
      utf8.decode(base64Url.decode(base64Url.normalize(encoded))),
    );
  } on FormatException {
    return null;
  }
}

String? _safePublicHttpsUrl(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      !uri.hasAuthority ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.port != 443) {
    return null;
  }
  final host = uri.host.toLowerCase();
  if (host.length > 253 || host.contains(':')) return null; // No IP literals.
  final labels = host.split('.');
  if (labels.length < 2 ||
      labels.last.length < 2 ||
      !RegExp(r'^[a-z]+$').hasMatch(labels.last) ||
      const {
        'arpa',
        'corp',
        'example',
        'home',
        'internal',
        'invalid',
        'lan',
        'local',
        'localhost',
        'onion',
        'test',
      }.contains(labels.last)) {
    return null;
  }
  final labelPattern = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');
  if (labels.any((label) => !labelPattern.hasMatch(label))) return null;
  return value;
}

class BookRelease {
  const BookRelease({
    required this.source,
    required this.sourceId,
    required this.title,
    this.format,
    this.language,
    this.size,
  });
  final String source;
  final String sourceId;
  final String title;
  final String? format;
  final String? language;
  final String? size;
  factory BookRelease.fromJson(Map<String, dynamic> json) => BookRelease(
    source: _string(json['source']) ?? '',
    sourceId: _string(json['source_id']) ?? '',
    title: _string(json['title']) ?? '',
    format: _string(json['format']),
    language: _string(json['language']),
    size: _string(json['size']),
  );
}

class BookDownload {
  const BookDownload({
    required this.id,
    required this.title,
    required this.status,
    this.progress,
  });
  final String id;
  final String title;
  final String status;
  final double? progress;
}

/// How well a release fits the requested work. Nothing here starts a download;
/// the result only orders and labels the list the user chooses from.
class BookReleaseAssessment {
  const BookReleaseAssessment({
    required this.release,
    required this.titleMatches,
    required this.authorMatches,
    required this.formatMismatch,
    required this.languageMismatch,
    required this.likely,
  });
  final BookRelease release;
  final bool titleMatches;
  final bool authorMatches;
  final bool formatMismatch;
  final bool languageMismatch;
  final bool likely;
}

/// Orders matching works first, then compatible German/English editions.
/// The metadata record's own language is deliberately not a reader preference.
List<BookReleaseAssessment> assessReleases(
  BookResult book,
  List<BookRelease> releases,
  BooksMediaType type,
) {
  final titleTokens = _significantTokens(book.title);
  final authors = book.authors
      .map((author) => _tokens(author).toList())
      .where((tokens) => tokens.isNotEmpty)
      .toList();

  final indexed = <(int, BookReleaseAssessment)>[];
  for (final (index, release) in releases.indexed) {
    final tokens = _tokens(release.title).toSet();
    final titleMatches =
        titleTokens.isNotEmpty && titleTokens.every(tokens.contains);
    final authorMatches =
        authors.isEmpty ||
        authors.any(
          (name) => tokens.contains(name.last) || name.every(tokens.contains),
        );
    final format = release.format?.trim().toLowerCase();
    final formatMismatch = type == BooksMediaType.ebook
        ? _audiobookFormats.contains(format) && !_ebookFormats.contains(format)
        : _ebookFormats.contains(format) && !_audiobookFormats.contains(format);
    final languageMismatch = _outsideBookLanguages(release.language);
    final likely =
        titleMatches && authorMatches && !formatMismatch && !languageMismatch;
    indexed.add((
      index,
      BookReleaseAssessment(
        release: release,
        titleMatches: titleMatches,
        authorMatches: authorMatches,
        formatMismatch: formatMismatch,
        languageMismatch: languageMismatch,
        likely: likely,
      ),
    ));
  }
  int workRank(BookReleaseAssessment item) => !item.titleMatches
      ? 2
      : item.authorMatches
      ? 0
      : 1;
  int compatibilityRank(BookReleaseAssessment item) => item.formatMismatch
      ? 2
      : item.languageMismatch
      ? 1
      : 0;
  indexed.sort((a, b) {
    final byWork = workRank(a.$2).compareTo(workRank(b.$2));
    if (byWork != 0) return byWork;
    final byCompatibility = compatibilityRank(a.$2)
        .compareTo(compatibilityRank(b.$2));
    return byCompatibility != 0 ? byCompatibility : a.$1.compareTo(b.$1);
  });
  return [for (final item in indexed) item.$2];
}

const _ebookFormats = {
  'epub',
  'mobi',
  'azw3',
  'pdf',
  'fb2',
  'djvu',
  'cbz',
  'cbr',
  'txt',
  'rtf',
  'doc',
  'docx',
  'zip',
  'rar',
};
const _audiobookFormats = {
  'm4b',
  'mp3',
  'm4a',
  'mp4',
  'flac',
  'ogg',
  'wma',
  'aac',
  'wav',
  'opus',
  'zip',
  'rar',
};

const _germanLanguageNames = {'de', 'deu', 'ger', 'german', 'deutsch'};
const _englishLanguageNames = {'en', 'eng', 'english'};
const _otherLanguageNames = {
  'french',
  'français',
  'spanish',
  'español',
  'italian',
  'italiano',
  'japanese',
  'chinese',
  'russian',
  'portuguese',
  'dutch',
  'latin',
};
final _languageCode = RegExp(r'^[a-z]{2,3}$');

bool _outsideBookLanguages(String? value) {
  if (value == null) return false;
  final parts = value
      .toLowerCase()
      .split(RegExp(r'[^a-zà-ÿ]+'))
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.isEmpty ||
      parts.any(
        (part) =>
            _germanLanguageNames.contains(part) ||
            _englishLanguageNames.contains(part),
      )) {
    return false;
  }
  // Unknown labels stay selectable for manual judgment; only clear other
  // languages are excluded from the requested German/English scope.
  return parts.every(
    (part) =>
        _languageCode.hasMatch(part) || _otherLanguageNames.contains(part),
  );
}

const _titleStopwords = {
  'the',
  'a',
  'an',
  'of',
  'and',
  'novel',
  'der',
  'die',
  'das',
  'ein',
  'eine',
  'und',
  'le',
  'la',
  'les',
  'il',
  'el',
  'de',
  'di',
  'von',
};
const _foldedLetters = {
  'ä': 'a',
  'à': 'a',
  'á': 'a',
  'â': 'a',
  'å': 'a',
  'æ': 'ae',
  'ç': 'c',
  'é': 'e',
  'è': 'e',
  'ê': 'e',
  'ë': 'e',
  'í': 'i',
  'ì': 'i',
  'î': 'i',
  'ï': 'i',
  'ñ': 'n',
  'ö': 'o',
  'ó': 'o',
  'ò': 'o',
  'ô': 'o',
  'ø': 'o',
  'œ': 'oe',
  'ß': 'ss',
  'ü': 'u',
  'ú': 'u',
  'ù': 'u',
  'û': 'u',
};
final _tokenSeparator = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

Iterable<String> _tokens(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r"['’]"), '')
    .split('')
    .map((char) => _foldedLetters[char] ?? char)
    .join()
    .split(_tokenSeparator)
    .where((token) => token.isNotEmpty);

List<String> _significantTokens(String title) {
  final all = _tokens(title.split(':').first).toList();
  final significant = all.where((t) => !_titleStopwords.contains(t)).toList();
  return significant.isEmpty ? all : significant;
}
