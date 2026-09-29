import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../data/repositories/sheet_music_repository.dart';
import '../../../util/platform_detection.dart';
import '../playback/book_reader_screen.dart';

class SheetMusicSearchDialog extends StatefulWidget {
  const SheetMusicSearchDialog({
    super.key,
    required this.repository,
    this.serverId,
  });

  final SheetMusicRepository repository;
  final String? serverId;

  @override
  State<SheetMusicSearchDialog> createState() => _SheetMusicSearchDialogState();
}

class _SheetMusicSearchDialogState extends State<SheetMusicSearchDialog> {
  final _title = TextEditingController();
  final _composer = TextEditingController();
  final _instrument = TextEditingController();
  Future<List<SheetMusicPiece>>? _results;

  bool get _german => Localizations.localeOf(context).languageCode == 'de';

  void _search() {
    setState(() {
      _results = widget.repository.search(
        query: _title.text,
        composer: _composer.text,
        instrument: _instrument.text,
      );
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _composer.dispose();
    _instrument.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final german = _german;
    return Dialog(
      child: SizedBox(
        width: 720,
        height: MediaQuery.sizeOf(context).height * 0.85,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      german ? 'Noten suchen' : 'Search sheet music',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: german ? 'Schließen' : 'Close',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              TextField(
                controller: _title,
                decoration: InputDecoration(
                  labelText: german ? 'Werk' : 'Work',
                ),
                onSubmitted: (_) => _search(),
              ),
              TextField(
                controller: _composer,
                decoration: InputDecoration(
                  labelText: german ? 'Komponist' : 'Composer',
                ),
                onSubmitted: (_) => _search(),
              ),
              TextField(
                controller: _instrument,
                decoration: InputDecoration(
                  labelText: german ? 'Instrument' : 'Instrument',
                ),
                onSubmitted: (_) => _search(),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _search,
                child: Text(german ? 'Suchen' : 'Search'),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: _results == null
                    ? Center(
                        child: Text(
                          german
                              ? 'Werk, Komponist oder Instrument eingeben.'
                              : 'Enter a work, composer or instrument.',
                        ),
                      )
                    : FutureBuilder<List<SheetMusicPiece>>(
                        future: _results,
                        builder: (context, snapshot) {
                          if (snapshot.connectionState !=
                              ConnectionState.done) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }
                          if (snapshot.hasError) {
                            return Center(
                              child: Text(
                                german
                                    ? 'Notenkatalog nicht verfügbar.'
                                    : 'Sheet music catalog unavailable.',
                              ),
                            );
                          }
                          final pieces = snapshot.data ?? const [];
                          if (pieces.isEmpty) {
                            return Center(
                              child: Text(
                                german
                                    ? 'Keine Noten gefunden.'
                                    : 'No sheet music found.',
                              ),
                            );
                          }
                          return ListView.builder(
                            itemCount: pieces.length,
                            itemBuilder: (context, index) {
                              final piece = pieces[index];
                              return _ScoreTile(
                                key: ValueKey(piece.id),
                                piece: piece,
                                repository: widget.repository,
                                serverId: widget.serverId,
                                german: german,
                              );
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScoreTile extends StatefulWidget {
  const _ScoreTile({
    super.key,
    required this.piece,
    required this.repository,
    required this.serverId,
    required this.german,
  });
  final SheetMusicPiece piece;
  final SheetMusicRepository repository;
  final String? serverId;
  final bool german;

  @override
  State<_ScoreTile> createState() => _ScoreTileState();
}

class _ScoreTileState extends State<_ScoreTile> {
  Timer? _timer;
  String? _jobId;
  SheetMusicJobStatus? _status;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _request() async {
    if (_busy || _jobId != null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = await widget.repository.request(widget.piece);
      if (!mounted) return;
      setState(() {
        _jobId = id;
        _busy = false;
      });
      await _poll();
      if (mounted && _status?.status != 'ready' && _status?.status != 'error') {
        _timer = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = widget.german ? 'Anfrage fehlgeschlagen' : 'Request failed';
        });
      }
    }
  }

  Future<void> _poll() async {
    final id = _jobId;
    if (id == null || _busy) return;
    try {
      final status = await widget.repository.status(id);
      if (!mounted) return;
      setState(() => _status = status);
      if (status.status == 'ready' || status.status == 'error') {
        _timer?.cancel();
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = widget.german
              ? 'Status nicht verfügbar'
              : 'Status unavailable',
        );
      }
    }
  }

  Future<void> _download() async {
    final id = _jobId;
    if (id == null || _busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await widget.repository.download(id);
      final name = widget.piece.title.replaceAll(
        RegExp(r'[^\p{L}\p{N}]+', unicode: true),
        '_',
      );
      final path = await FilePicker.saveFile(
        dialogTitle: widget.german ? 'Noten speichern' : 'Save sheet music',
        fileName: '${name.isEmpty ? 'sheet_music' : name}.pdf',
        bytes: bytes,
      );
      if (!mounted) return;
      if (path != null || PlatformDetection.isWeb) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.german ? 'Noten gespeichert' : 'Sheet music saved',
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = widget.german
              ? 'Download fehlgeschlagen'
              : 'Download failed',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final piece = widget.piece;
    final german = widget.german;
    final pdf = _mutopiaPdf(piece.pdfUrl);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(piece.title, style: Theme.of(context).textTheme.titleMedium),
            Text(
              [
                piece.composer,
                if (piece.opus != null) piece.opus!,
                if (piece.instrument != null) piece.instrument!,
              ].join(' · '),
            ),
            Text('${german ? 'Lizenz' : 'License'}: ${piece.license}'),
            SelectableText(
              '${german ? 'Quelle' : 'Source'}: ${piece.sourceUrl}',
            ),
            if (_status != null)
              Text('${german ? 'Status' : 'Status'}: ${_status!.status}'),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: Colors.red)),
            Wrap(
              spacing: 8,
              children: [
                if (pdf != null && !PlatformDetection.isWeb)
                  TextButton(
                    onPressed: () => Navigator.push<void>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => _SheetPdf(piece: piece, uri: pdf),
                      ),
                    ),
                    child: Text(german ? 'Vorschau' : 'Preview'),
                  ),
                FilledButton(
                  onPressed: _jobId == null && !_busy ? _request : null,
                  child: Text(german ? 'Anfragen' : 'Request'),
                ),
                if (_status?.status == 'ready' && _status?.itemId != null)
                  TextButton(
                    onPressed: () => Navigator.push<void>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => BookReaderScreen(
                          itemId: _status!.itemId!,
                          serverId: widget.serverId,
                        ),
                      ),
                    ),
                    child: Text(german ? 'In App öffnen' : 'Open in app'),
                  ),
                if (_status?.status == 'ready')
                  TextButton(
                    onPressed: _busy ? null : _download,
                    child: Text(german ? 'Herunterladen' : 'Download'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Uri? _mutopiaPdf(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host != 'www.mutopiaproject.org' ||
      uri.port != 443 ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      !uri.path.startsWith('/ftp/') ||
      !uri.path.toLowerCase().endsWith('.pdf')) {
    return null;
  }
  return uri;
}

class _SheetPdf extends StatelessWidget {
  const _SheetPdf({required this.piece, required this.uri});

  final SheetMusicPiece piece;
  final Uri uri;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(piece.title)),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text('${piece.composer} · ${piece.license}'),
        ),
        Expanded(child: PdfViewer.uri(uri)),
      ],
    ),
  );
}
