"""Product photos must not advertise a file that is no longer on disk."""

from app.core.media_root import local_media_missing, servable_media_url


def test_missing_local_product_photo_is_not_served(tmp_path, monkeypatch):
    monkeypatch.setenv("MEDIA_ROOT", str(tmp_path))
    missing = "/media-files/products/gone.jpg"
    assert local_media_missing(missing) is True
    assert servable_media_url(missing) is None

    folder = tmp_path / "products"
    folder.mkdir()
    (folder / "ok.jpg").write_bytes(b"jpeg")
    live = "/media-files/products/ok.jpg"
    assert local_media_missing(live) is False
    assert servable_media_url(live) == live


def test_external_image_url_stays(monkeypatch, tmp_path):
    monkeypatch.setenv("MEDIA_ROOT", str(tmp_path))
    url = "https://cdn.example.com/cake.jpg"
    assert local_media_missing(url) is False
    assert servable_media_url(url) == url
    assert servable_media_url("  ") is None
    assert servable_media_url(None) is None
