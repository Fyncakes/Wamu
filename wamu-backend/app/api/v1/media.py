from fastapi import APIRouter, Depends, File, UploadFile
from fastapi import HTTPException

from app.core.deps import get_current_user
from app.integrations.storage import s3
from app.models.user import User
from app.services.video_processing import process_uploaded_video_bytes

router = APIRouter()

_IMAGE_AUDIO_MAX = 5 * 1024 * 1024
_VIDEO_MAX = 25 * 1024 * 1024
_VIDEO_TYPES = {"video/mp4", "video/webm", "video/quicktime"}


@router.post("/upload")
async def upload(
    file: UploadFile = File(...),
    user: User = Depends(get_current_user),
):
    data = await file.read()
    content_type = (file.content_type or "application/octet-stream").lower()
    name = (file.filename or "").lower()
    is_video = content_type in _VIDEO_TYPES or name.endswith((".mp4", ".webm", ".mov"))
    max_bytes = _VIDEO_MAX if is_video else _IMAGE_AUDIO_MAX
    if len(data) > max_bytes:
        raise HTTPException(
            status_code=400,
            detail=f"Max {25 if is_video else 5}MB",
        )
    allowed = (
        is_video
        or content_type.startswith("image/")
        or content_type.startswith("audio/")
        or content_type in {"application/pdf", "application/x-pdf"}
        or name.endswith(".pdf")
    )
    if not allowed:
        raise HTTPException(status_code=400, detail="Unsupported file type")
    if name.endswith(".pdf") and not content_type.startswith("application/pdf"):
        content_type = "application/pdf"
    if is_video and content_type not in _VIDEO_TYPES:
        if name.endswith(".mp4"):
            content_type = "video/mp4"
        elif name.endswith(".webm"):
            content_type = "video/webm"
        elif name.endswith(".mov"):
            content_type = "video/quicktime"

    poster_url = None
    original_url = None
    if is_video:
        # Keep original briefly for audit; serve compressed progressive MP4 + poster.
        original_url, _ = s3.upload_bytes(data, content_type=content_type, folder="media/originals")
        compressed, poster_bytes, content_type = process_uploaded_video_bytes(data)
        url, key = s3.upload_bytes(compressed, content_type=content_type, folder="media")
        if poster_bytes:
            poster_url, _ = s3.upload_bytes(
                poster_bytes, content_type="image/jpeg", folder="media/posters"
            )
        return {
            "url": url,
            "object_key": key,
            "mime_type": content_type,
            "owner_id": str(user.id),
            "poster_url": poster_url,
            "original_url": original_url,
            "bytes": len(compressed),
            "original_bytes": len(data),
        }

    url, key = s3.upload_bytes(data, content_type=content_type, folder="media")
    return {
        "url": url,
        "object_key": key,
        "mime_type": content_type,
        "owner_id": str(user.id),
        "bytes": len(data),
    }
