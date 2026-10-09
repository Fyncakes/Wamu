from app.services.geocode import is_placeholder_dropoff, lookup_kampala_place


def test_kisaasi_lookup():
    coords = lookup_kampala_place("Kisaasi, Kampala")
    assert coords is not None
    lat, lng = coords
    assert 0.35 < lat < 0.39
    assert 32.58 < lng < 32.62


def test_placeholder_offset_detected():
    plat, plng = 0.3476, 32.5825
    assert is_placeholder_dropoff(plat, plng, plat + 0.008, plng + 0.006)
    assert not is_placeholder_dropoff(plat, plng, 0.3668, 32.5969)
