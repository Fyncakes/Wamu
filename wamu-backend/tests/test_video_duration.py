"""Discover short duration rules: max 90s, no 1-minute minimum."""

from __future__ import annotations

import pytest

from app.services.video_processing import VideoDurationError, assert_short_duration


@pytest.mark.parametrize(
    "seconds,ok",
    [
        (1, True),
        (15, True),
        (59, True),
        (60, True),
        (75, True),
        (90, True),
        (91, False),
        (120, False),
        (None, False),
        (0, False),
    ],
)
def test_assert_short_duration_max_90(seconds, ok):
    if ok:
        assert assert_short_duration(float(seconds)) == int(round(seconds))
    else:
        with pytest.raises(VideoDurationError):
            assert_short_duration(None if seconds is None else float(seconds))
