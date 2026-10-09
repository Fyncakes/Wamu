"use client";

import { api, unwrapItems } from "@/lib/api";
import { useAsyncData } from "@/lib/hooks";
import { DataTable } from "@/components/data-table";
import { LoadingSpinner } from "@/components/loading-spinner";
import { PageHeader } from "@/components/page-header";

type AuditRow = {
  id: string;
  action: string;
  entity_type: string;
  entity_id?: string;
  actor_id?: string;
  created_at?: string;
};

export default function AuditLogsPage() {
  const { data, error, loading } = useAsyncData(async () => {
    const res = await api.admin.getAuditLogs();
    return unwrapItems(res as AuditRow[] | { items?: AuditRow[] });
  }, []);

  if (loading && !data) return <LoadingSpinner />;
  const rows = (data ?? []) as AuditRow[];

  return (
    <div>
      <PageHeader title="Audit logs" description="Sensitive actions across the platform" />
      {error && <p className="mb-4 text-sm text-red-600">{error}</p>}
      <DataTable
        data={rows}
        keyExtractor={(r) => r.id}
        columns={[
          { key: "when", header: "When", render: (r) => r.created_at ?? "—" },
          { key: "action", header: "Action", render: (r) => r.action },
          { key: "entity", header: "Entity", render: (r) => r.entity_type },
          {
            key: "id",
            header: "ID",
            render: (r) => (r.entity_id ? r.entity_id.slice(0, 8) : "—"),
          },
          {
            key: "actor",
            header: "Actor",
            render: (r) => (r.actor_id ? r.actor_id.slice(0, 8) : "system"),
          },
        ]}
      />
    </div>
  );
}
