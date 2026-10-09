import 'package:flutter_test/flutter_test.dart';

import 'package:wamu_mobile/shared/models/business_model.dart';
import 'package:wamu_mobile/shared/utils/json_numbers.dart';
import 'package:wamu_mobile/shared/utils/phone_normalize.dart';
import 'package:wamu_mobile/shared/utils/ugx_formatter.dart';

void main() {
  test('normalizeUgPhone formats to E.164', () {
    expect(normalizeUgPhone('0700123456'), '+256700123456');
    expect(normalizeUgPhone('+256700123456'), '+256700123456');
  });

  test('formatUgx adds thousand separators', () {
    expect(formatUgx(1500000), 'UGX 1,500,000');
  });

  test('parseDouble accepts string decimals from API', () {
    expect(parseDouble('4.80'), 4.80);
    expect(parseDouble(4.8), 4.8);
    expect(parseDouble(null), isNull);
  });

  test('BusinessModel parses string rating', () {
    final b = BusinessModel.fromJson({
      'id': '1',
      'name': 'FynCakes',
      'rating': '4.80',
      'review_count': '12',
    });
    expect(b.rating, 4.80);
    expect(b.reviewCount, 12);
  });
}
