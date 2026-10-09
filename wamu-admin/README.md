# WAMU Admin Dashboard

Administration web app for the **WAMU Uganda Super App** marketplace. Built with Next.js (App Router), TypeScript, and Tailwind CSS.

## Features

- Phone OTP login (mock flow against FastAPI)
- Dashboard with marketplace stats
- User, business, order, and payment management
- Business verification queue with verify/suspend actions
- Category listing
- Content report moderation
- System health monitoring

## Prerequisites

- Node.js 18+
- WAMU FastAPI backend running at `http://localhost:8000`

## Setup

```bash
cd wamu-admin
npm install
cp .env.local.example .env.local
```

Edit `.env.local` if your API URL differs:

```
NEXT_PUBLIC_API_URL=http://localhost:8000/api/v1
```

## Run

```bash
# Development
npm run dev

# Production build
npm run build
npm start

# Lint
npm run lint
```

Open [http://localhost:3000](http://localhost:3000). You will be redirected to `/login` if not authenticated.

## Authentication

1. Enter an admin phone number (e.g. `+256700000000`)
2. Request OTP via `POST /api/v1/auth/request-otp`
3. Enter the OTP to verify via `POST /api/v1/auth/verify-otp`
4. JWT access token is stored in `localStorage` and sent as `Authorization: Bearer <token>` on admin requests

## API Endpoints Used

| Feature | Endpoint |
|---------|----------|
| Request OTP | `POST /auth/request-otp` |
| Verify OTP | `POST /auth/verify-otp` |
| Dashboard stats | `GET /admin/stats` |
| Users | `GET /admin/users` |
| Businesses | `GET /admin/businesses` |
| Verify business | `POST /admin/businesses/{id}/verify` |
| Suspend business | `POST /admin/businesses/{id}/suspend` |
| Orders | `GET /admin/orders` |
| Payments | `GET /admin/payments` |
| Categories | `GET /admin/categories` |
| Reports | `GET /admin/reports` |
| Resolve report | `POST /admin/reports/{id}/resolve` |
| Health | `GET /health` (root, not under `/api/v1`) |

## Project Structure

```
wamu-admin/
├── app/
│   ├── (dashboard)/     # Protected admin pages with sidebar layout
│   ├── login/           # OTP login flow
│   ├── layout.tsx
│   └── globals.css
├── components/          # Reusable UI (sidebar, tables, cards)
├── lib/
│   ├── api.ts           # FastAPI client
│   ├── auth.ts          # JWT localStorage helpers
│   └── types.ts         # Shared TypeScript types
└── .env.local.example
```

## Design

- Primary color: WAMU green `#0B6E4F`
- Fonts: DM Sans (UI) + Fraunces (headings) via Google Fonts
