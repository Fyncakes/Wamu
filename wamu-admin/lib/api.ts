import { clearToken, getToken } from "./auth";
import type {
  AdminStats,
  AuthTokens,
  Business,
  Category,
  FinanceOverview,
  HealthStatus,
  MerchantPayout,
  Order,
  OrderDispute,
  PaginatedResponse,
  Payment,
  PayoutQueuePage,
  RailsReadiness,
  ReconciliationRunResult,
  Report,
  SuspenseItem,
  User,
} from "./types";

const API_URL =
  process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000/api/v1";

export class ApiError extends Error {
  constructor(
    message: string,
    public status: number,
    public body?: unknown,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

export function unwrapItems<T>(
  data: T[] | { items?: T[] | null } | null | undefined,
): T[] {
  if (!data) return [];
  if (Array.isArray(data)) return data;
  return data.items ?? [];
}

function parseErrorDetail(data: unknown, status: number): string {
  if (typeof data === "object" && data !== null && "detail" in data) {
    const detail = (data as { detail: unknown }).detail;
    if (typeof detail === "string") return detail;
    if (Array.isArray(detail)) {
      const messages = detail
        .map((item) => {
          if (typeof item === "object" && item !== null && "msg" in item) {
            return String((item as { msg: unknown }).msg);
          }
          return String(item);
        })
        .filter(Boolean);
      if (messages.length > 0) return messages.join("; ");
    }
  }
  return `Request failed (${status})`;
}

async function request<T>(
  path: string,
  options: RequestInit = {},
  authenticated = true,
): Promise<T> {
  const headers = new Headers(options.headers);

  if (!headers.has("Content-Type") && options.body) {
    headers.set("Content-Type", "application/json");
  }

  if (authenticated) {
    const token = getToken();
    if (token) {
      headers.set("Authorization", `Bearer ${token}`);
    }
  }

  const response = await fetch(`${API_URL}${path}`, {
    ...options,
    headers,
  });

  if (response.status === 401 && authenticated) {
    clearToken();
  }

  const text = await response.text();
  let data: unknown = null;
  if (text) {
    try {
      data = JSON.parse(text);
    } catch {
      data = text;
    }
  }

  if (!response.ok) {
    throw new ApiError(parseErrorDetail(data, response.status), response.status, data);
  }

  return data as T;
}

async function fetchHealthEndpoint(
  path: string,
): Promise<{ status: string; latency_ms?: number; detail?: string }> {
  const start = performance.now();
  const response = await fetch(`${API_URL}${path}`);
  const latency_ms = Math.round(performance.now() - start);
  const text = await response.text();
  let data: Record<string, unknown> = {};
  if (text) {
    try {
      data = JSON.parse(text) as Record<string, unknown>;
    } catch {
      data = { status: response.ok ? "ok" : "error" };
    }
  }
  const status =
    typeof data.status === "string"
      ? data.status
      : response.ok
        ? "ok"
        : "error";
  return { status, latency_ms, detail: typeof data.detail === "string" ? data.detail : undefined };
}

export const api = {
  auth: {
    requestOtp: (phone: string) =>
      request<{ message: string; mock_hint?: string | null; expires_in?: number }>(
        "/auth/request-otp",
        { method: "POST", body: JSON.stringify({ phone }) },
        false,
      ),

    verifyOtp: (phone: string, otp: string) =>
      request<AuthTokens>(
        "/auth/verify-otp",
        { method: "POST", body: JSON.stringify({ phone, code: otp }) },
        false,
      ),
  },

  admin: {
    getStats: () => request<AdminStats>("/admin/stats"),
    getFinanceOverview: () =>
      request<FinanceOverview>("/admin/finance/overview"),

    runReconciliation: (body?: {
      provider?: string;
      include_orphan?: boolean;
      hours?: number;
    }) =>
      request<ReconciliationRunResult>("/admin/finance/reconcile/run", {
        method: "POST",
        body: JSON.stringify(body ?? { provider: "MTN" }),
      }),

    getSuspense: (params?: { status?: string; page?: number }) => {
      const query = new URLSearchParams();
      if (params?.status) query.set("status", params.status);
      if (params?.page) query.set("page", String(params.page));
      const qs = query.toString();
      return request<PaginatedResponse<SuspenseItem>>(
        `/admin/finance/suspense${qs ? `?${qs}` : ""}`,
      );
    },

    resolveSuspense: (
      id: string,
      body: { notes: string; action?: "write_off" | "ignore" },
    ) =>
      request<SuspenseItem>(`/admin/finance/suspense/${id}/resolve`, {
        method: "POST",
        body: JSON.stringify(body),
      }),

    getPayoutQueue: () =>
      request<PayoutQueuePage>("/admin/finance/payout-queue"),

    executePayout: (id: string) =>
      request<MerchantPayout>(`/admin/finance/payout-queue/${id}/execute`, {
        method: "POST",
      }),

    executePayoutQueue: (body?: { limit?: number; payout_ids?: string[] }) =>
      request<{
        status: string;
        selected: number;
        executed: number;
        success: number;
        failed: number;
        skipped: number;
      }>("/admin/finance/payout-queue/execute", {
        method: "POST",
        body: JSON.stringify(body ?? { limit: 50 }),
      }),

    getRiderPayoutQueue: () =>
      request<PaginatedResponse<{
        id: string;
        amount: number;
        payee_phone: string;
        status: string;
        provider?: string;
        created_at?: string;
      }>>("/admin/finance/rider-payout-queue"),

    executeRiderPayout: (id: string) =>
      request<{ id: string; status: string }>(
        `/admin/finance/rider-payout-queue/${id}/execute`,
        { method: "POST" },
      ),

    getOwnerPayouts: () =>
      request<{
        available_commission_minor: number;
        owner_payout_phone_set: boolean;
        items: Array<{
          id: string;
          amount_minor: number;
          status: string;
          payee_phone: string;
          created_at?: string;
        }>;
        total: number;
      }>("/admin/finance/owner-payouts"),

    requestOwnerPayout: (body?: { amount_minor?: number; notes?: string }) =>
      request<{ id: string; status: string; amount_minor: number }>(
        "/admin/finance/owner-payouts/request",
        { method: "POST", body: JSON.stringify(body ?? {}) },
      ),

    executeOwnerPayout: (id: string) =>
      request<{ id: string; status: string }>(
        `/admin/finance/owner-payouts/${id}/execute`,
        { method: "POST" },
      ),

    getManualRefunds: () =>
      request<PaginatedResponse<{
        id: string;
        order_id: string;
        amount: number;
        provider?: string;
        provider_reference?: string | null;
        refund?: { manual_required?: boolean; detail?: string; reason?: string };
        created_at?: string;
      }>>("/admin/finance/manual-refunds"),

    importStatement: (body: {
      provider?: string;
      lines: Array<{
        external_ref: string;
        amount_minor?: number;
        amount?: number;
        currency?: string;
      }>;
      notes?: string;
    }) =>
      request<ReconciliationRunResult>("/admin/finance/reconcile/import", {
        method: "POST",
        body: JSON.stringify(body),
      }),

    getUsers: (params?: { page?: number; status?: string }) => {
      const query = new URLSearchParams();
      if (params?.page) query.set("page", String(params.page));
      if (params?.status) query.set("status", params.status);
      const qs = query.toString();
      return request<PaginatedResponse<User> | User[]>(
        `/admin/users${qs ? `?${qs}` : ""}`,
      );
    },

    getBusinesses: (params?: {
      page?: number;
      verification_status?: string;
    }) => {
      const query = new URLSearchParams();
      if (params?.page) query.set("page", String(params.page));
      if (params?.verification_status) {
        query.set("verification_status", params.verification_status);
      }
      const qs = query.toString();
      return request<PaginatedResponse<Business> | Business[]>(
        `/admin/businesses${qs ? `?${qs}` : ""}`,
      );
    },

    verifyBusiness: (id: string) =>
      request<Business>(`/admin/businesses/${id}/verify`, { method: "POST" }),

    suspendUser: (id: string) =>
      request<User>(`/admin/users/${id}/suspend`, { method: "POST" }),

    activateUser: (id: string) =>
      request<User>(`/admin/users/${id}/activate`, { method: "POST" }),

    suspendBusiness: (id: string) =>
      request<Business>(`/admin/businesses/${id}/suspend`, { method: "POST" }),

    getMerchantKycQueue: (status = "QUEUE") =>
      request<{ items?: Record<string, unknown>[] } | Record<string, unknown>[]>(
        `/admin/businesses/kyc-queue?status=${encodeURIComponent(status)}`,
      ),

    getMerchantKyc: (id: string) =>
      request<Record<string, unknown>>(`/admin/businesses/${id}/kyc`),

    approveMerchantKyc: (id: string, note?: string) =>
      request<Record<string, unknown>>(`/admin/businesses/${id}/kyc/approve`, {
        method: "POST",
        body: JSON.stringify({ note: note ?? null }),
      }),

    rejectMerchantKyc: (id: string, note?: string) =>
      request<Record<string, unknown>>(`/admin/businesses/${id}/kyc/reject`, {
        method: "POST",
        body: JSON.stringify({ note: note ?? "Rejected" }),
      }),

    requestMerchantKycReupload: (id: string, note?: string) =>
      request<Record<string, unknown>>(
        `/admin/businesses/${id}/kyc/request-reupload`,
        {
          method: "POST",
          body: JSON.stringify({ note: note ?? null }),
        },
      ),

    getKycPolicy: () => request<Record<string, unknown>>(`/admin/settings/kyc`),

    setKycPolicy: (body: Record<string, unknown>) =>
      request<Record<string, unknown>>(`/admin/settings/kyc`, {
        method: "PUT",
        body: JSON.stringify(body),
      }),

    getOrders: (params?: { page?: number; status?: string }) => {
      const query = new URLSearchParams();
      if (params?.page) query.set("page", String(params.page));
      if (params?.status) query.set("status", params.status);
      const qs = query.toString();
      return request<PaginatedResponse<Order> | Order[]>(
        `/admin/orders${qs ? `?${qs}` : ""}`,
      );
    },

    getPayments: (params?: { page?: number; status?: string }) => {
      const query = new URLSearchParams();
      if (params?.page) query.set("page", String(params.page));
      if (params?.status) query.set("status", params.status);
      const qs = query.toString();
      return request<PaginatedResponse<Payment> | Payment[]>(
        `/admin/payments${qs ? `?${qs}` : ""}`,
      );
    },

    getPayouts: () =>
      request<PaginatedResponse<MerchantPayout> | MerchantPayout[]>(
        "/admin/payouts",
      ),

    reconcilePayouts: () =>
      request<{ status: string }>("/admin/payouts/reconcile", { method: "POST" }),

    reconcilePayments: () =>
      request<{ status: string; summary?: unknown }>("/admin/payments/reconcile", {
        method: "POST",
      }),

    retryPayout: (id: string) =>
      request<MerchantPayout>(`/admin/payouts/${id}/retry`, { method: "POST" }),

    getCategories: () =>
      request<PaginatedResponse<Category> | Category[]>("/admin/categories"),

    getReports: (params?: { page?: number; status?: string }) => {
      const query = new URLSearchParams();
      if (params?.page) query.set("page", String(params.page));
      if (params?.status) query.set("status", params.status);
      const qs = query.toString();
      return request<PaginatedResponse<Report> | Report[]>(
        `/admin/reports${qs ? `?${qs}` : ""}`,
      );
    },

    resolveReport: (id: string) =>
      request<Report>(`/admin/reports/${id}/resolve`, { method: "POST" }),

    getDisputes: (params?: { status?: string }) => {
      const query = new URLSearchParams();
      if (params?.status) query.set("status", params.status);
      const qs = query.toString();
      return request<PaginatedResponse<OrderDispute> | OrderDispute[]>(
        `/admin/disputes${qs ? `?${qs}` : ""}`,
      );
    },

    resolveDispute: (
      id: string,
      body: { status: string; resolution_note?: string },
    ) =>
      request<OrderDispute>(`/admin/disputes/${id}/resolve`, {
        method: "POST",
        body: JSON.stringify(body),
      }),

    getRiders: (params?: { status?: string }) => {
      const query = new URLSearchParams();
      if (params?.status) query.set("status", params.status);
      const qs = query.toString();
      return request<{ items?: Record<string, unknown>[] } | Record<string, unknown>[]>(
        `/admin/riders${qs ? `?${qs}` : ""}`,
      );
    },

    getRider: (id: string) =>
      request<Record<string, unknown>>(`/admin/riders/${id}`),

    approveRider: (id: string, note?: string) =>
      request<Record<string, unknown>>(`/admin/riders/${id}/approve`, {
        method: "POST",
        body: JSON.stringify({ note }),
      }),

    suspendRider: (id: string, note?: string) =>
      request<Record<string, unknown>>(`/admin/riders/${id}/suspend`, {
        method: "POST",
        body: JSON.stringify({ note }),
      }),

    rejectRider: (id: string, note?: string) =>
      request<Record<string, unknown>>(`/admin/riders/${id}/reject`, {
        method: "POST",
        body: JSON.stringify({ note }),
      }),

    requestRiderReupload: (
      id: string,
      body?: { note?: string; reupload_fields?: string[] },
    ) =>
      request<Record<string, unknown>>(`/admin/riders/${id}/request-reupload`, {
        method: "POST",
        body: JSON.stringify(body ?? {}),
      }),

    getRiderVerification: (id: string) =>
      request<Record<string, unknown>>(`/admin/riders/${id}/verification`),

    getDeliveries: () =>
      request<{ items?: Record<string, unknown>[] } | Record<string, unknown>[]>(
        "/admin/deliveries",
      ),

    getAuditLogs: () =>
      request<{ items?: Record<string, unknown>[] } | Record<string, unknown>[]>(
        "/admin/audit-logs",
      ),

    getFraud: () =>
      request<{
        status: string;
        signals: { level: string; code: string; count: number }[];
        checked_at?: string;
      }>("/admin/fraud"),

    getNotifications: () =>
      request<{ items?: Record<string, unknown>[] } | Record<string, unknown>[]>(
        "/admin/notifications",
      ),

    broadcastNotification: (body: {
      title: string;
      body: string;
      audience?: string;
    }) =>
      request<{ sent: number; audience: string }>(
        "/admin/notifications/broadcast",
        { method: "POST", body: JSON.stringify(body) },
      ),

    getVideoRetention: () =>
      request<{ archive_after_days: number; purge_after_days: number }>(
        "/admin/settings/video-retention",
      ),

    putVideoRetention: (body: {
      archive_after_days: number;
      purge_after_days: number;
    }) =>
      request<{ archive_after_days: number; purge_after_days: number }>(
        "/admin/settings/video-retention",
        { method: "PUT", body: JSON.stringify(body) },
      ),

    runVideoLifecycle: () =>
      request<{
        archived: number;
        purged: number;
        archive_after_days: number;
        purge_after_days: number;
      }>("/admin/videos/lifecycle/run", { method: "POST" }),
  },

  health: {
    getStatus: async (): Promise<HealthStatus> => {
      const [apiHealth, dbHealth, redisHealth] = await Promise.all([
        fetchHealthEndpoint("/health"),
        fetchHealthEndpoint("/health/database"),
        fetchHealthEndpoint("/health/redis"),
      ]);

      return {
        status: apiHealth.status,
        database: {
          status: dbHealth.status,
          latency_ms: dbHealth.latency_ms,
        },
        redis: {
          status: redisHealth.status,
          latency_ms: redisHealth.latency_ms,
        },
      };
    },

    getRails: () =>
      fetch(`${API_URL}/health/rails`).then(async (res) => {
        if (!res.ok) throw new Error(`Rails health ${res.status}`);
        return (await res.json()) as RailsReadiness;
      }),
  },
};
