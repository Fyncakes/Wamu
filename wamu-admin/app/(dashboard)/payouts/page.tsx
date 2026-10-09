"use client";

import { useState } from "react";
import { api, unwrapItems } from "@/lib/api";
import { useAsyncData } from "@/lib/hooks";
import { Badge } from "@/components/badge";
import { DataTable } from "@/components/data-table";
import { LoadingSpinner } from "@/components/loading-spinner";
import { PageHeader } from "@/components/page-header";

function formatAmount(amount: number, currency = "UGX"): string {
  return new Intl.NumberFormat("en-UG", {
    style: "currency",
    currency,
    maximumFractionDigits: 0,
  }).format(amount);
}

export default function PayoutsPage() {
  const [busy, setBusy] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const { data, error, loading } = useAsyncData(async () => {
    const res = await api.admin.getPayouts();
    return unwrapItems(res);
  }, [tick]);

  async function onReconcile() {
    setBusy("reconcile");
    setActionError(null);
    try {
      await api.admin.reconcilePayouts();
      setTick((t) => t + 1);
    } catch (e) {
      setActionError(e instanceof Error ? e.message : "Reconcile failed");
    } finally {
      setBusy(null);
    }
  }

  async function onRetry(id: string) {
    setBusy(id);
    setActionError(null);
    try {
      await api.admin.retryPayout(id);
      setTick((t) => t + 1);
    } catch (e) {
      setActionError(e instanceof Error ? e.message : "Retry failed");
    } finally {
      setBusy(null);
    }
  }

  if (loading && tick === 0) return <LoadingSpinner />;

  const payouts = data ?? [];

  return (
    <div>
      <PageHeader
        title="Merchant payouts"
        description="Non-custodial disbursements — net to merchant, fee stays in MoMo float"
        action={
          <button
            type="button"
            onClick={onReconcile}
            disabled={busy === "reconcile"}
            className="rounded-lg bg-wamu-600 px-4 py-2 text-sm font-medium text-white hover:bg-wamu-700 disabled:opacity-60"
          >
            {busy === "reconcile" ? "Reconciling…" : "Reconcile open"}
          </button>
        }
      />

      {(error || actionError) && (
        <div className="mb-6 rounded-lg bg-red-50 px-4 py-3 text-sm text-red-700">
          {error || actionError}
        </div>
      )}

      <DataTable
        data={payouts}
        keyExtractor={(p) => p.id}
        emptyMessage="No merchant payouts yet"
        columns={[
          {
            key: "id",
            header: "Payout",
            render: (p) => (
              <span className="font-mono text-xs text-slate-600">
                {p.id.slice(0, 8)}…
              </span>
            ),
          },
          {
            key: "net",
            header: "Net to merchant",
            render: (p) => formatAmount(Number(p.amount), p.currency),
          },
          {
            key: "fee",
            header: "Platform fee",
            render: (p) => (
              <span>
                {formatAmount(Number(p.platform_fee ?? 0), p.currency)}
                {p.fee_bps ? (
                  <span className="ml-1 text-xs text-slate-400">
                    ({p.fee_bps} bps)
                  </span>
                ) : null}
              </span>
            ),
          },
          {
            key: "payee",
            header: "Payee",
            render: (p) => p.payee_phone ?? "—",
          },
          {
            key: "provider",
            header: "Provider",
            render: (p) => p.provider ?? "—",
          },
          {
            key: "status",
            header: "Status",
            render: (p) => <Badge status={p.status}>{p.status}</Badge>,
          },
          {
            key: "created",
            header: "Date",
            render: (p) =>
              p.created_at
                ? new Date(p.created_at).toLocaleString("en-UG")
                : "—",
          },
          {
            key: "actions",
            header: "",
            render: (p) =>
              p.status === "SUCCESS" ? (
                <span className="text-xs text-slate-400">—</span>
              ) : (
                <button
                  type="button"
                  onClick={() => onRetry(p.id)}
                  disabled={busy === p.id}
                  className="text-sm font-medium text-wamu-700 hover:underline disabled:opacity-50"
                >
                  {busy === p.id ? "…" : "Retry"}
                </button>
              ),
          },
        ]}
      />
    </div>
  );
}
