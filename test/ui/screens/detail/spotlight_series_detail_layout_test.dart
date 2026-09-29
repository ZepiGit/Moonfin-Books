// Which summary cards a series keeps on the Spotlight detail page.
//
// A series with more than one season has a choice to make, so its seasons are
// laid out on the page and the teaser card counting them goes away. The cast,
// crew, studios and recommendation cards move behind a single nested entry in
// the More Actions menu, so a series page spends its card band on what
// identifies the title. A single-season series keeps its teaser, because there
// is nothing to choose between, and every other item type is untouched.
import 'package:flutter_test/flutter_test.dart';
import 'package:moonfin/ui/screens/detail/spotlight/spotlight_detail_content.dart';

const _seriesCards = <String>[
  'seasons',
  'people',
  'chapters_extras',
  'similar',
  'collections',
];

void main() {
  test('a series with more than one season loses its seasons teaser', () {
    expect(
      spotlightVisibleCardIds(
        itemType: 'Series',
        seasonCount: 3,
        cardIds: _seriesCards,
      ),
      ['chapters_extras', 'collections'],
    );
  });

  test('the people and similar cards are what moved behind More Actions', () {
    // The two the layout folds into one nested entry have to be exactly the
    // ones it offers there, or the menu opens a screen that is missing content
    // the page used to show.
    expect(spotlightRelocatedCardIds, ['people', 'similar']);
  });

  test('a single-season series keeps its seasons teaser', () {
    expect(
      spotlightVisibleCardIds(
        itemType: 'Series',
        seasonCount: 1,
        cardIds: _seriesCards,
      ),
      ['seasons', 'chapters_extras', 'collections'],
    );
  });

  test('a series with no seasons at all loses nothing to the seasons rule', () {
    expect(
      spotlightVisibleCardIds(
        itemType: 'Series',
        seasonCount: 0,
        cardIds: _seriesCards,
      ),
      ['seasons', 'chapters_extras', 'collections'],
    );
  });

  test('the cards that stay keep the order the builder gave them', () {
    expect(
      spotlightVisibleCardIds(
        itemType: 'Series',
        seasonCount: 12,
        cardIds: _seriesCards,
      ),
      ['chapters_extras', 'collections'],
    );
  });

  test('cards the builder already left out stay out', () {
    // The builder omits a card whose every section would be empty. The layout
    // only ever removes, so it can never invent one.
    expect(
      spotlightVisibleCardIds(
        itemType: 'Series',
        seasonCount: 4,
        cardIds: ['seasons', 'similar'],
      ),
      isEmpty,
    );
  });

  test('every other item type keeps all of its cards', () {
    for (final type in ['Movie', 'Season', 'Episode', 'Person', 'BoxSet']) {
      expect(
        spotlightVisibleCardIds(
          itemType: type,
          seasonCount: 9,
          cardIds: _seriesCards,
        ),
        _seriesCards,
        reason: type,
      );
    }
  });

  test('the result cannot be written back through by a caller', () {
    final ids = spotlightVisibleCardIds(
      itemType: 'Series',
      seasonCount: 2,
      cardIds: _seriesCards,
    );
    expect(() => ids.add('similar'), throwsUnsupportedError);
  });
}
