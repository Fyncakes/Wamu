"use client";

import Link from "next/link";
import { api, unwrapItems } from "@/lib/api";
import { useAsyncData } from "@/lib/hooks";
import { Badge } from "@/components/badge";
import { LoadingSpinner } from "@/components/loading-spinner";
import { PageHeader } from "@/components/page-header";
import { StatsCard } from "@/components/stats-card";

function formatNumber(n: number): string {
  return new Intl.NumberFormat("en-UG").format(n);
}

function formatCurrency(n: number): string {
  return new Intl.NumberFormat("en-UG", {
    style: "currency",
    currency: "UGX",
    maximumFractionDigits: 0,
  }).format(n);
}

type RiderRow = {
  id?: string;
  display_name?: string;
  phone?: string;
  status?: string;
  wamu_rider_ref?: string;
  vehicle_type?: string;
  available_delivery?: boolean;
};

export default function DashboardPage() {
  const { data: stats, error, loading } = useAsyncData(
    () => api.admin.getStats(),
    [],
    5000,
  );
  const { data: riders } = useAsyncData(async () => {
    const res = await api.admin.getRiders();
    return unwrapItems(res as { items?: RiderRow[] } | RiderRow[]) as RiderRow[];
  }, [], 5000);

  if (loading) return <LoadingSpinner />;

  const riderRows = (riders ?? []).slice(0, 8);

  return (
    <div>
      <PageHeader
        title="Dashboard"
        description="Overview of WAMU marketplace activity"
      />

      {error && (
        <div className="mb-6 rounded-lg bg-red-50 px-4 py-3 text-sm text-red-700">
          {error}
        </div>
      )}

      <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <StatsCard
          label="Users"
          value={stats ? formatNumber(stats.users) : "—"}
          hint="Registered accounts"
          icon={<span className="text-lg">◎</span>}
        />
        <StatsCard
          label="Riders"
          value={stats?.riders != null ? formatNumber(stats.riders) : "—"}
          hint={
            stats?.riders_pending
              ? `${stats.riders_pending} pending review · ${stats.riders_approved ?? 0} approved`
              : `${stats?.riders_approved ?? 0} approved`
          }
          icon={<span className="text-lg">🛵</span>}
        />
        <StatsCard
          label="Businesses"
          value={stats ? formatNumber(stats.businesses) : "—"}
          hint={
            stats?.pending_verifications
              ? `${stats.pending_verifications} pending verification`
              : "Active listings"
          }
          icon={<span className="text-lg">▣</span>}
        />
        <StatsCard
          label="Orders"
          value={stats ? formatNumber(stats.orders) : "—"}
          hint="All time"
          icon={<span className="text-lg">▤</span>}
        />
      </div>

      <div className="mt-4 grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
        <StatsCard
          label="GMV collected"
          value={
            stats?.revenue_ugx != null
              ? formatCurrency(stats.revenue_ugx)
              : "—"
          }
          hint={
            stats
              ? `${formatNumber(stats.payments)} payments`
              : "Successful collections"
          }
          icon={<span className="text-lg">◈</span>}
        />
        <StatsCard
          label="Platform fees"
          value={
            stats?.platform_fee_ugx != null
              ? formatCurrency(stats.platform_fee_ugx)
              : "—"
          }
          hint="Retained in MoMo float (non-custodial)"
          icon={<span className="text-lg">⬡</span>}
        />
        <StatsCard
          label="Net to merchants"
          value={
            stats?.payout_net_ugx != null
              ? formatCurrency(stats.payout_net_ugx)
              : "—"
          }
          hint={
            stats?.successful_payouts
              ? `${formatNumber(stats.successful_payouts)} successful payouts`
              : "Disbursed after fee"
          }
          icon={<span className="text-lg">⇢</span>}
        />
      </div>

      <div className="mt-8 rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
        <div className="flex items-center justify-between gap-3">
          <div>
            <h3 className="font-display text-lg font-semibold text-slate-900">
              Riders
            </h3>
            <p className="mt-1 text-sm text-slate-500">
              Latest rider profiles — approve from the Riders page
            </p>
          </div>
          <Link
            href="/riders"
            className="rounded-lg border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50"
          >
            View all
          </Link>
        </div>
        <ul className="mt-4 divide-y divide-slate-100">
          {riderRows.map((r) => (
            <li
              key={String(r.id)}
              className="flex items-center justify-between gap-3 py-3 text-sm"
            >
              <div className="min-w-0">
                <p className="truncate font-medium text-slate-900">
                  {r.display_name || r.phone || "Rider"}
                </p>
                <p className="truncate text-slate-500">
                  {[r.phone, r.wamu_rider_ref, r.vehicle_type]
                    .filter(Boolean)
                    .join(" · ")}
                </p>
              </div>
              <Badge status={String(r.status ?? "—")}>
                {String(r.status ?? "—")}
              </Badge>
            </li>
          ))}
          {riderRows.length === 0 && (
            <li className="py-6 text-sm text-slate-500">No riders yet</li>
          )}
        </ul>
      </div>

      {(stats?.orders_by_status || stats?.payments_by_status) && (
        <div className="mt-8 grid gap-4 lg:grid-cols-2">
          <div className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
            <h3 className="font-display text-lg font-semibold text-slate-900">
              Orders by status
            </h3>
            <ul className="mt-4 space-y-2 text-sm">
              {Object.entries(stats?.orders_by_status ?? {})
                .sort(([a], [b]) => a.localeCompare(b))
                .map(([status, count]) => (
                  <li
                    key={status}
                    className="flex items-center justify-between border-b border-slate-100 pb-2 last:border-0"
                  >
                    <span className="text-slate-600">{status}</span>
                    <span className="font-medium text-slate-900">
                      {formatNumber(count)}
                    </span>
                  </li>
                ))}
              {Object.keys(stats?.orders_by_status ?? {}).length === 0 && (
                <li className="text-slate-500">No orders yet</li>
              )}
            </ul>
          </div>
          <div className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
            <h3 className="font-display text-lg font-semibold text-slate-900">
              Payments by status
            </h3>
            <ul className="mt-4 space-y-2 text-sm">
              {Object.entries(stats?.payments_by_status ?? {})
                .sort(([a], [b]) => a.localeCompare(b))
                .map(([status, count]) => (
                  <li
                    key={status}
                    className="flex items-center justify-between border-b border-slate-100 pb-2 last:border-0"
                  >
                    <span className="text-slate-600">{status}</span>
                    <span className="font-medium text-slate-900">
                      {formatNumber(count)}
                    </span>
                  </li>
                ))}
              {Object.keys(stats?.payments_by_status ?? {}).length === 0 && (
                <li className="text-slate-500">No payments yet</li>
              )}
            </ul>
          </div>
        </div>
      )}

      <div className="mt-8 grid gap-4 lg:grid-cols-3">
        <Link
          href="/riders"
          className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm transition-shadow hover:shadow-md"
        >
          <h3 className="font-display text-lg font-semibold text-slate-900">
            Rider verification
          </h3>
          <p className="mt-1 text-sm text-slate-500">
            {stats?.riders_pending
              ? `${stats.riders_pending} riders awaiting review`
              : "Review and approve rider applications"}
          </p>
        </Link>
        <Link
          href="/users"
          className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm transition-shadow hover:shadow-md"
        >
          <h3 className="font-display text-lg font-semibold text-slate-900">
            Users & roles
          </h3>
          <p className="mt-1 text-sm text-slate-500">
            Phone, Gmail, and role for every account
          </p>
        </Link>
        <Link
          href="/businesses"
          className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm transition-shadow hover:shadow-md"
        >
          <h3 className="font-display text-lg font-semibold text-slate-900">
            Verification queue
          </h3>
          <p className="mt-1 text-sm text-slate-500">
            {stats?.pending_verifications
              ? `${stats.pending_verifications} businesses awaiting review`
              : "Review and approve pending business registrations"}
          </p>
        </Link>
      </div>
    </div>
  );
}
