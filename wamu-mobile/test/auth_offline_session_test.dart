import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wamu_mobile/shared/models/user_model.dart';

void main() {
  test('user snapshot round-trips for offline reopen', () {
    const user = UserModel(
      id: 'u1',
      phone: '+256788578208',
      firstName: 'Kola',
      lastName: 'S',
      role: 'ADMIN',
      ownsBusiness: true,
      wantsToRide: false,
    );

    final restored = UserModel.fromJson(
      jsonDecode(jsonEncode(user.toJson())) as Map<String, dynamic>,
    );

    expect(restored.id, 'u1');
    expect(restored.phone, '+256788578208');
    expect(restored.firstName, 'Kola');
    expect(restored.lastName, 'S');
    expect(restored.isAdmin, isTrue);
    expect(restored.ownsBusiness, isTrue);
    expect(restored.needsProfileSetup, isFalse);
  });

  test('empty name still needs profile setup after offline restore', () {
    const user = UserModel(id: 'u2', phone: '+256700000001');
    final restored = UserModel.fromJson(user.toJson());
    expect(restored.needsProfileSetup, isTrue);
  });
}
