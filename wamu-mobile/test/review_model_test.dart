import 'package:flutter_test/flutter_test.dart';
import 'package:wamu_mobile/shared/models/review_model.dart';

void main() {
  test('ReviewModel parses reply and rating', () {
    final r = ReviewModel.fromJson({
      'id': 'r1',
      'rating': 5,
      'comment': 'Great',
      'reply': 'Webale!',
      'user_id': 'u1',
    });
    expect(r.rating, 5);
    expect(r.comment, 'Great');
    expect(r.reply, 'Webale!');
  });
}
