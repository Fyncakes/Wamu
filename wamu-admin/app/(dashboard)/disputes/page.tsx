"use client";

import { useMemo, useState } from "react";
import { api, ApiError, unwrapItems } from "@/lib/api";
import { useAsyncData } from "@/lib/hooks";
import type { OrderDispute } from "@/lib/types";
import { Badge } from "@/components/badge";
import { DataTable } from "@/components/data-table";
import { LoadingSpinner } from "@/components/loading-spinner";
import { PageHeader } from "@/components/page-header";

function DisputeList({ showOpenOnly }: { showOpenOnly: boolean }) {
  const [actionId, setActionId] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);

  const { data, error, loading } = useAsyncData(async () => {
    const res = await api.admin.getDisputes();
    return unwrapItems(res) as OrderDispute[];
  }, [refreshKey]);

  const disputes = useMemo(() => {
    const all = data ?? [];
    if (!showOpenOnly) return all;
    return all.filter((d) => d.status === "OPEN");
  }, [data, showOpenOnly]);

  async function handleResolve(id: string, status: string) {
    setActionId(id);
    setActionError(null);
    try {
      await api.admin.resolveDispute(id, {
        status,
        resolution_note: status === "RESOLVED_REFUND" ? "Refund approved" : "Closed by admin",
      });
      setRefreshKey((k) => k + 1);
    } catch (err) {
      setActionError(
        err instanceof ApiError ? err.message : "Failed to resolve dispute",
      );
    } finally {
      setActionId(null);
    }
  }

  if (loading) return <LoadingSpinner />;

  const displayError = actionError ?? error;

  return (
    <>
      {displayError && (
        <div className="mb-6 rounded-lg bg-red-50 px-4 py-3 text-sm text-red-700">
          {displayError}
        </div>
      )}

      <DataTable
        data={disputes}
        keyExtractor={(d) => d.id}
        emptyMessage="No disputes in queue"
        columns={[
          {
            key: "order",
            header: "Order",
            render: (d) => (
              <span className="font-mono text-xs text-slate-700">
                {d.order_id.slice(0, 8)}…
              </span>
            ),
          },
          {
            key: "reason",
            header: "Reason",
            render: (d) => (
              <div>
                <span className="font-medium text-slate-900">{d.reason}</span>
                {d.description ? (
                  <p className="text-xs text-slate-500 line-clamp-2">{d.description}</p>
                ) : null}
              </div>
            ),
          },
          {
            key: "status",
            header: "Status",
            render: (d) => <Badge status={d.status}>{d.status}</Badge>,
          },
          {
            key: "created",
            header: "Opened",
            render: (d) =>
              d.created_at ? new Date(d.created_at).toLocaleString("en-UG") : "—",
          },
          {
            key: "actions",
            header: "Actions",
            className: "text-right",
            render: (d) =>
              d.status === "OPEN" ? (
                <div className="flex justify-end gap-2">
                  <button
                    type="button"
                    disabled={actionId === d.id}
                    onClick={() => handleResolve(d.id, "RESOLVED_REFUND")}
                    className="rounded-md bg-emerald-600 px-2.5 py-1 text-xs font-semibold text-white disabled:opacity-50"
                  >
                    Refund
                  </button>
                  <button
                    type="button"
                    disabled={actionId === d.id}
                    onClick={() => handleResolve(d.id, "RESOLVED_REJECT")}
                    className="rounded-md bg-slate-700 px-2.5 py-1 text-xs font-semibold text-white disabled:opacity-50"
                  >
                    Reject
                  </button>
                </div>
              ) : (
                <span className="text-xs text-slate-400">—</span>
              ),
          },
        ]}
      />
    </>
  );
}

export default function DisputesPage() {
  const [tab, setTab] = useState<"open" | "all">("open");

  return (
    <div>
      <PageHeader
        title="Order disputes"
        description="Customer commerce disputes — refund or reject after review."
      />
      <div className="mb-4 flex gap-2">
        <button
          type="button"
          onClick={() => setTab("open")}
          className={`rounded-md px-3 py-1.5 text-sm font-medium ${
            tab === "open" ? "bg-slate-900 text-white" : "bg-slate-100 text-slate-700"
          }`}
        >
          Open
        </button>
        <button
          type="button"
          onClick={() => setTab("all")}
          className={`rounded-md px-3 py-1.5 text-sm font-medium ${
            tab === "all" ? "bg-slate-900 text-white" : "bg-slate-100 text-slate-700"
          }`}
        >
          All
        </button>
      </div>
      <DisputeList showOpenOnly={tab === "open"} />
    </div>
  );
}
