import 'package:flutter_test/flutter_test.dart';
import 'package:wamu_mobile/shared/models/business_model.dart';

void main() {
  test('BusinessModel parses payout fields', () {
    final b = BusinessModel.fromJson({
      'id': 'b1',
      'name': 'Ntinda Grill',
      'phone': '+256700000088',
      'payout_phone': '+256700111222',
      'payout_provider': 'MTN',
      'verification_status': 'VERIFIED',
    });
    expect(b.payoutPhone, '+256700111222');
    expect(b.payoutProvider, 'MTN');
    expect(b.effectivePayoutPhone, '+256700111222');
  });

  test('effectivePayoutPhone falls back to business phone', () {
    final b = BusinessModel.fromJson({
      'id': 'b1',
      'name': 'Shop',
      'phone': '+256700000099',
    });
    expect(b.payoutPhone, isNull);
    expect(b.effectivePayoutPhone, '+256700000099');
  });
}
