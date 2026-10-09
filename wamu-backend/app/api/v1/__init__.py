"""API v1 router aggregate."""

from fastapi import APIRouter

from app.api.v1 import (
    admin,
    ai,
    auth,
    businesses,
    calls,
    categories,
    chat,
    communities,
    dashboards,
    devices,
    discover,
    favorites,
    health,
    media,
    notifications,
    order_disputes,
    orders,
    payments,
    products,
    reports,
    reviews,
    riders,
    search,
    status,
    users,
)

api_router = APIRouter(prefix="/api/v1")
api_router.include_router(auth.router, prefix="/auth", tags=["auth"])
api_router.include_router(users.router, prefix="/users", tags=["users"])
api_router.include_router(categories.router, prefix="/categories", tags=["categories"])
api_router.include_router(businesses.router, prefix="/businesses", tags=["businesses"])
api_router.include_router(products.router, prefix="/products", tags=["products"])
api_router.include_router(search.router, prefix="/search", tags=["search"])
api_router.include_router(orders.router, prefix="/orders", tags=["orders"])
api_router.include_router(order_disputes.router, prefix="/disputes", tags=["disputes"])
api_router.include_router(payments.router, prefix="/payments", tags=["payments"])
api_router.include_router(chat.router, prefix="/chat", tags=["chat"])
api_router.include_router(calls.router, prefix="/calls", tags=["calls"])
api_router.include_router(status.router, prefix="/status", tags=["status"])
api_router.include_router(communities.router, prefix="/communities", tags=["communities"])
api_router.include_router(reviews.router, prefix="/reviews", tags=["reviews"])
api_router.include_router(favorites.router, prefix="/favorites", tags=["favorites"])
api_router.include_router(notifications.router, prefix="/notifications", tags=["notifications"])
api_router.include_router(devices.router, prefix="/devices", tags=["devices"])
api_router.include_router(reports.router, prefix="/reports", tags=["reports"])
api_router.include_router(media.router, prefix="/media", tags=["media"])
api_router.include_router(ai.router, prefix="/ai", tags=["ai"])
api_router.include_router(admin.router, prefix="/admin", tags=["admin"])
api_router.include_router(discover.router, prefix="/discover", tags=["discover"])
api_router.include_router(dashboards.router, prefix="/dashboard", tags=["dashboard"])
api_router.include_router(riders.router, tags=["riders"])
api_router.include_router(health.router, tags=["health"])
