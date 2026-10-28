import 'package:flutter_test/flutter_test.dart';
import 'package:wamu_mobile/features/home/nearby_location.dart';

void main() {
  test('originForAreaId maps Kampala beachhead chips', () {
    final ntinda = originForAreaId('ntinda');
    expect(ntinda.fromGps, isFalse);
    expect(ntinda.label, 'Ntinda');
    expect(ntinda.lat, closeTo(0.3476, 0.0001));
    expect(ntinda.radiusKm, 6);

    final fallback = originForAreaId('unknown-area');
    expect(fallback.label, 'Greater Kampala');
    expect(fallback.radiusKm, 20);
  });

  test('ugandaAreas covers Kampala beachhead and regions', () {
    final ids = ugandaAreas.map((a) => a.id).toSet();
    expect(ids, containsAll(['kampala', 'ntinda', 'nakawa', 'wandegeya']));
    expect(ids, containsAll(['jinja', 'gulu', 'mbarara', 'mbale', 'arua', 'moroto']));
    expect(ugandaAreas.length, greaterThan(100));
  });
}
