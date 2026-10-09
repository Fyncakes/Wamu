"use client";

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

export default function OrdersPage() {
  const { data, error, loading } = useAsyncData(async () => {
    const res = await api.admin.getOrders();
    return unwrapItems(res);
  }, [], 5000);

  if (loading) return <LoadingSpinner />;

  const orders = data ?? [];

  return (
    <div>
      <PageHeader
        title="Orders"
        description="Monitor marketplace orders across all businesses"
      />

      {error && (
        <div className="mb-6 rounded-lg bg-red-50 px-4 py-3 text-sm text-red-700">
          {error}
        </div>
      )}

      <DataTable
        data={orders}
        keyExtractor={(o) => o.id}
        emptyMessage="No orders found"
        columns={[
          {
            key: "id",
            header: "Order ID",
            render: (o) => (
              <span className="font-mono text-xs text-slate-600">
                {o.id.slice(0, 8)}…
              </span>
            ),
          },
          {
            key: "business",
            header: "Business",
            render: (o) => o.business_name ?? o.business_id?.slice(0, 8) ?? "—",
          },
          {
            key: "amount",
            header: "Total",
            render: (o) =>
              formatAmount(o.total_amount ?? o.total ?? 0, o.currency),
          },
          {
            key: "status",
            header: "Status",
            render: (o) => <Badge status={o.status}>{o.status}</Badge>,
          },
          {
            key: "created",
            header: "Date",
            render: (o) =>
              o.created_at
                ? new Date(o.created_at).toLocaleString("en-UG")
                : "—",
          },
        ]}
      />
    </div>
  );
}
