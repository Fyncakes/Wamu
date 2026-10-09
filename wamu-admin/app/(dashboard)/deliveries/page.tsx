"use client";

import { api, unwrapItems } from "@/lib/api";
import { useAsyncData } from "@/lib/hooks";
import { Badge } from "@/components/badge";
import { DataTable } from "@/components/data-table";
import { LoadingSpinner } from "@/components/loading-spinner";
import { PageHeader } from "@/components/page-header";

type DeliveryRow = {
  id: string;
  order_id: string;
  status: string;
  dropoff_address?: string;
  fee: number;
  rider_name?: string;
  created_at?: string;
};

export default function DeliveriesPage() {
  const { data, error, loading } = useAsyncData(async () => {
    const res = await api.admin.getDeliveries();
    return unwrapItems(res as DeliveryRow[] | { items?: DeliveryRow[] });
  }, [], 5000);

  if (loading && !data) return <LoadingSpinner />;
  const rows = (data ?? []) as DeliveryRow[];

  return (
    <div>
      <PageHeader title="Deliveries" description="Platform delivery jobs" />
      {error && <p className="mb-4 text-sm text-red-600">{error}</p>}
      <DataTable
        data={rows}
        keyExtractor={(r) => r.id}
        columns={[
          {
            key: "order",
            header: "Order",
            render: (r) => r.order_id.slice(0, 8),
          },
          {
            key: "status",
            header: "Status",
            render: (r) => <Badge status={r.status}>{r.status}</Badge>,
          },
          { key: "rider", header: "Rider", render: (r) => r.rider_name ?? "—" },
          {
            key: "dropoff",
            header: "Drop-off",
            render: (r) => r.dropoff_address ?? "—",
          },
          {
            key: "fee",
            header: "Fee",
            render: (r) => `UGX ${Number(r.fee).toLocaleString()}`,
          },
          {
            key: "created",
            header: "Created",
            render: (r) => r.created_at ?? "—",
          },
        ]}
      />
    </div>
  );
}
