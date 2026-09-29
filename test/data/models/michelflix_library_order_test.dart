import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/data/models/aggregated_library.dart';

void main() {
  test('orders MichelFlix folders while preserving unknown folders', () {
    AggregatedLibrary library(String name) => AggregatedLibrary(
      id: name,
      name: name,
      collectionType: 'books',
      serverId: 'server',
    );
    final input = [
      'Serien Kids',
      'Other',
      'Hörbücher',
      'Filme Kids',
      'Anime',
      'Noten',
      'Serien',
      'Bücher',
      'Filme',
      'Another',
    ].map(library).toList();

    expect(orderMichelFlixLibraries(input).map((item) => item.name), [
      'Filme',
      'Serien',
      'Anime',
      'Bücher',
      'Hörbücher',
      'Noten',
      'Filme Kids',
      'Serien Kids',
      'Other',
      'Another',
    ]);
    expect(input.first.name, 'Serien Kids');
  });
}
