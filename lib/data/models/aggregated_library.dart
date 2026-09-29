class AggregatedLibrary {
  final String id;
  final String name;
  final String collectionType;
  final String serverId;
  final double? primaryImageAspectRatio;
  final Map<String, dynamic>? imageTags;
  final List<String>? backdropImageTags;

  const AggregatedLibrary({
    required this.id,
    required this.name,
    required this.collectionType,
    required this.serverId,
    this.primaryImageAspectRatio,
    this.imageTags,
    this.backdropImageTags,
  });
}

/// MichelFlix library order; unlisted libraries keep their server order after
/// the known folders. Sorting a copy preserves each user's hidden-view list.
const _michelFlixLibraryNames = [
  'filme',
  'serien',
  'anime',
  'bücher',
  'hörbücher',
  'noten',
  'filme kids',
  'serien kids',
];

int michelFlixLibraryRank(String name) {
  final index = _michelFlixLibraryNames.indexOf(name.trim().toLowerCase());
  return index < 0 ? _michelFlixLibraryNames.length : index;
}

List<AggregatedLibrary> orderMichelFlixLibraries(
  List<AggregatedLibrary> items,
) {
  final indexed = items.indexed.toList();
  indexed.sort((a, b) {
    final comparison = michelFlixLibraryRank(a.$2.name)
        .compareTo(michelFlixLibraryRank(b.$2.name));
    return comparison != 0 ? comparison : a.$1.compareTo(b.$1);
  });
  return [for (final row in indexed) row.$2];
}
