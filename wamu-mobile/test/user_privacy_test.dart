import 'package:flutter_test/flutter_test.dart';
import 'package:wamu_mobile/shared/models/user_model.dart';

void main() {
  test('UserModel parses show_read_receipts', () {
    final u = UserModel.fromJson({
      'id': '1',
      'phone': '+256700000001',
      'role': 'CUSTOMER',
      'profile': {
        'show_last_seen': true,
        'show_online': true,
        'show_read_receipts': false,
      },
    });
    expect(u.showReadReceipts, isFalse);
    expect(u.showLastSeen, isTrue);
  });

  test('UserModel defaults show_read_receipts to true', () {
    final u = UserModel.fromJson({
      'id': '1',
      'phone': '+256700000001',
    });
    expect(u.showReadReceipts, isTrue);
  });
}
