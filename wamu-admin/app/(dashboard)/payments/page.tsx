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

export default function PaymentsPage() {
  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const { data, error, loading } = useAsyncData(async () => {
    const res = await api.admin.getPayments();
    return unwrapItems(res);
  }, [tick]);

  async function onReconcile() {
    setBusy(true);
    setActionError(null);
    try {
      await api.admin.reconcilePayments();
      setTick((t) => t + 1);
    } catch (e) {
      setActionError(e instanceof Error ? e.message : "Reconcile failed");
    } finally {
      setBusy(false);
    }
  }

  if (loading && tick === 0) return <LoadingSpinner />;

  const payments = data ?? [];

  return (
    <div>
      <PageHeader
        title="Payments"
        description="Track payment transactions and provider status"
        action={
          <button
            type="button"
            onClick={onReconcile}
            disabled={busy}
            className="rounded-lg bg-wamu-600 px-4 py-2 text-sm font-medium text-white hover:bg-wamu-700 disabled:opacity-60"
          >
            {busy ? "Reconciling…" : "Reconcile pending"}
          </button>
        }
      />

      {(error || actionError) && (
        <div className="mb-6 rounded-lg bg-red-50 px-4 py-3 text-sm text-red-700">
          {error || actionError}
        </div>
      )}

      <DataTable
        data={payments}
        keyExtractor={(p) => p.id}
        emptyMessage="No payments found"
        columns={[
          {
            key: "id",
            header: "Payment ID",
            render: (p) => (
              <span className="font-mono text-xs text-slate-600">
                {p.id.slice(0, 8)}…
              </span>
            ),
          },
          {
            key: "order",
            header: "Order",
            render: (p) =>
              p.order_id ? `${p.order_id.slice(0, 8)}…` : "—",
          },
          {
            key: "amount",
            header: "Amount",
            render: (p) => formatAmount(p.amount, p.currency),
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
                ? new Date(p.created_at).toLocaleString()
                : "—",
          },
        ]}
      />
    </div>
  );
}
