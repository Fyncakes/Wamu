"""Product photos must not advertise a file that is no longer on disk."""

from datetime import datetime, timezone
from types import SimpleNamespace

from app.core.media_root import local_media_missing, servable_media_url
from app.services.product import newest_servable_image


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


def test_newer_upload_replaces_the_photo_the_shop_shows(monkeypatch, tmp_path):
    monkeypatch.setenv("MEDIA_ROOT", str(tmp_path))
    folder = tmp_path / "products"
    folder.mkdir()
    (folder / "old.jpg").write_bytes(b"old")
    (folder / "new.jpg").write_bytes(b"new")
    old = SimpleNamespace(
        url="/media-files/products/old.jpg",
        is_primary=True,
        sort_order=0,
        created_at=datetime(2026, 10, 1, tzinfo=timezone.utc),
    )
    new = SimpleNamespace(
        url="/media-files/products/new.jpg",
        is_primary=False,
        sort_order=1,
        created_at=datetime(2026, 10, 24, tzinfo=timezone.utc),
    )
    assert newest_servable_image([old, new]) is new
    assert newest_servable_image([new, old]) is new


def test_missing_replacement_keeps_the_photo_still_on_disk(monkeypatch, tmp_path):
    monkeypatch.setenv("MEDIA_ROOT", str(tmp_path))
    folder = tmp_path / "products"
    folder.mkdir()
    (folder / "old.jpg").write_bytes(b"old")
    old = SimpleNamespace(
        url="/media-files/products/old.jpg",
        is_primary=True,
        sort_order=0,
        created_at=datetime(2026, 10, 1, tzinfo=timezone.utc),
    )
    gone = SimpleNamespace(
        url="/media-files/products/gone.jpg",
        is_primary=False,
        sort_order=1,
        created_at=datetime(2026, 10, 24, tzinfo=timezone.utc),
    )
    assert newest_servable_image([old, gone]) is old


def test_external_image_url_stays(monkeypatch, tmp_path):
    monkeypatch.setenv("MEDIA_ROOT", str(tmp_path))
    url = "https://cdn.example.com/cake.jpg"
    assert local_media_missing(url) is False
    assert servable_media_url(url) == url
    assert servable_media_url("  ") is None
    assert servable_media_url(None) is None
