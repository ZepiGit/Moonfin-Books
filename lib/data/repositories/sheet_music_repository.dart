import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:server_core/server_core.dart';

/// Authenticated sheet-music search, request, status and file access through
/// Moonbase Books. The server resolves each source ID before downloading.
class SheetMusicRepository {
  SheetMusicRepository(MediaServerClient client, {@visibleForTesting Dio? dio})
    : _baseUrl = client.baseUrl,
      _token = client.accessToken ?? '',
      _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 15),
            ),
          );

  final String _baseUrl;
  final String _token;
  final Dio _dio;

  String get _root =>
      '${_baseUrl.replaceFirst(RegExp(r'/$'), '')}/Moonfin/Books/v1/SheetMusic';
  Options get _options => Options(
    headers: {'Authorization': 'MediaBrowser Token="$_token"'},
    responseType: ResponseType.json,
    followRedirects: false,
    validateStatus: (_) => true,
  );

  @visibleForTesting
  SheetMusicRepository.forTest(String baseUrl, String token, Dio dio)
    : _baseUrl = baseUrl,
      _token = token,
      _dio = dio;

  Future<List<SheetMusicPiece>> search({
    String? query,
    String? composer,
    String? instrument,
  }) async {
    if (_token.isEmpty || _baseUrl.isEmpty) {
      throw const SheetMusicApiException(401);
    }
    try {
      final response = await _dio.get<dynamic>(
        _root,
        queryParameters: {
          if (query != null && query.trim().isNotEmpty) 'query': query.trim(),
          if (composer != null && composer.trim().isNotEmpty)
            'composer': composer.trim(),
          if (instrument != null && instrument.trim().isNotEmpty)
            'instrument': instrument.trim(),
        },
        options: _options,
      );
      final code = response.statusCode ?? 0;
      if (code < 200 || code >= 300) throw SheetMusicApiException(code);
      final data = response.data;
      if (data == null) throw const SheetMusicApiException(0);
      // The proxy may serialize a JSON body as a JSON string.
      dynamic decoded = data;
      if (decoded is String) decoded = jsonDecode(decoded);
      if (decoded is Map) decoded = decoded['pieces'];
      if (decoded is! List) throw const SheetMusicApiException(0);
      return decoded
          .whereType<Map>()
          .map(
            (item) => SheetMusicPiece.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList();
    } on SheetMusicApiException {
      rethrow;
    } on DioException catch (error) {
      throw SheetMusicApiException(error.response?.statusCode ?? 0);
    } on FormatException {
      throw const SheetMusicApiException(0);
    }
  }

  Future<String> request(SheetMusicPiece piece) async {
    if (_token.isEmpty) throw const SheetMusicApiException(401);
    try {
      final response = await _dio.post<dynamic>(
        '$_root/Request',
        data: {'id': piece.id},
        options: _options,
      );
      if (response.statusCode != 202) {
        throw SheetMusicApiException(response.statusCode ?? 0);
      }
      final body = _map(response.data);
      final id = body['job_id'];
      if (id is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(id)) {
        throw const SheetMusicApiException(0);
      }
      return id;
    } on DioException catch (error) {
      throw SheetMusicApiException(error.response?.statusCode ?? 0);
    }
  }

  Future<SheetMusicJobStatus> status(String jobId) async {
    if (_token.isEmpty) throw const SheetMusicApiException(401);
    try {
      final response = await _dio.get<dynamic>(
        '$_root/Status',
        queryParameters: {'jobId': jobId},
        options: _options,
      );
      if (response.statusCode != 200) {
        throw SheetMusicApiException(response.statusCode ?? 0);
      }
      final body = _map(response.data);
      return SheetMusicJobStatus(
        status: _string(body['status']) ?? '',
        itemId: _string(body['item_id']),
        error: _string(body['error']),
      );
    } on DioException catch (error) {
      throw SheetMusicApiException(error.response?.statusCode ?? 0);
    }
  }

  Future<Uint8List> download(String jobId) async {
    if (_token.isEmpty) throw const SheetMusicApiException(401);
    try {
      final response = await _dio.get<List<int>>(
        '$_root/File',
        queryParameters: {'jobId': jobId},
        options: _options.copyWith(responseType: ResponseType.bytes),
      );
      if (response.statusCode != 200 || response.data == null) {
        throw SheetMusicApiException(response.statusCode ?? 0);
      }
      final bytes = Uint8List.fromList(response.data!);
      if (bytes.length < 5 ||
          bytes.length > 100000000 ||
          utf8.decode(bytes.sublist(0, 5)) != '%PDF-') {
        throw const SheetMusicApiException(0);
      }
      return bytes;
    } on DioException catch (error) {
      throw SheetMusicApiException(error.response?.statusCode ?? 0);
    }
  }
}

Map<String, dynamic> _map(dynamic value) {
  if (value is String) value = jsonDecode(value);
  if (value is! Map) throw const SheetMusicApiException(0);
  return Map<String, dynamic>.from(value);
}

class SheetMusicJobStatus {
  const SheetMusicJobStatus({required this.status, this.itemId, this.error});
  final String status;
  final String? itemId;
  final String? error;
}

class SheetMusicApiException implements Exception {
  const SheetMusicApiException(this.statusCode);
  final int statusCode;
}

class SheetMusicPiece {
  const SheetMusicPiece({
    required this.id,
    required this.title,
    required this.composer,
    required this.license,
    required this.sourceUrl,
    required this.pdfUrl,
    this.opus,
    this.instrument,
    this.style,
  });

  final String id;
  final String title;
  final String composer;
  final String? opus;
  final String? instrument;
  final String? style;

  /// Per-piece license exactly as Mutopia publishes it (e.g. Public Domain
  /// or a Creative Commons variant); must be shown in the UI.
  final String license;
  final String sourceUrl;

  /// Optional source PDF preview. Actual imports and user downloads use the
  /// authenticated Moonbase request and file endpoints.
  final String pdfUrl;

  factory SheetMusicPiece.fromJson(Map<String, dynamic> json) =>
      SheetMusicPiece(
        id: _string(json['id']) ?? '',
        title: _string(json['title']) ?? '',
        composer: _string(json['composer']) ?? '',
        license: _string(json['license']) ?? '',
        sourceUrl: _string(json['source_url']) ?? '',
        pdfUrl: _string(json['pdf_url']) ?? '',
        opus: _string(json['opus']),
        instrument: _string(json['instrument']),
        style: _string(json['style']),
      );
}

String? _string(dynamic value) =>
    value is String && value.trim().isNotEmpty ? value : null;
