"use client";

import { useMemo, useState } from "react";
import { api, ApiError, unwrapItems } from "@/lib/api";
import { useAsyncData } from "@/lib/hooks";
import { Badge } from "@/components/badge";
import { DataTable } from "@/components/data-table";
import { LoadingSpinner } from "@/components/loading-spinner";
import { PageHeader } from "@/components/page-header";

function ReportList({ showOpenOnly }: { showOpenOnly: boolean }) {
  const [actionId, setActionId] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);

  const { data, error, loading } = useAsyncData(async () => {
    const res = await api.admin.getReports();
    return unwrapItems(res);
  }, [refreshKey]);

  const reports = useMemo(() => {
    const all = data ?? [];
    if (!showOpenOnly) return all;
    return all.filter((r) => r.status === "OPEN");
  }, [data, showOpenOnly]);

  async function handleResolve(id: string) {
    setActionId(id);
    setActionError(null);
    try {
      await api.admin.resolveReport(id);
      setRefreshKey((k) => k + 1);
    } catch (err) {
      setActionError(
        err instanceof ApiError ? err.message : "Failed to resolve report",
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
        data={reports}
        keyExtractor={(r) => r.id}
        emptyMessage="No reports to review"
        columns={[
          {
            key: "target",
            header: "Target",
            render: (r) => (
              <div>
                <span className="font-medium text-slate-900">
                  {r.target_type}
                </span>
                <p className="font-mono text-xs text-slate-500">
                  {r.target_id.slice(0, 8)}…
                </p>
              </div>
            ),
          },
          {
            key: "reason",
            header: "Reason",
            render: (r) => r.reason,
          },
          {
            key: "status",
            header: "Status",
            render: (r) => <Badge status={r.status}>{r.status}</Badge>,
          },
          {
            key: "created",
            header: "Reported",
            render: (r) =>
              r.created_at
                ? new Date(r.created_at).toLocaleString("en-UG")
                : "—",
          },
          {
            key: "actions",
            header: "Actions",
            className: "text-right",
            render: (r) =>
              r.status === "OPEN" ? (
                <button
                  type="button"
                  disabled={actionId === r.id}
                  onClick={() => handleResolve(r.id)}
                  className="rounded-lg bg-wamu-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-wamu-700 disabled:opacity-50"
                >
                  Resolve
                </button>
              ) : (
                "—"
              ),
          },
        ]}
      />
    </>
  );
}

export default function ReportsPage() {
  const [showOpenOnly, setShowOpenOnly] = useState(true);

  return (
    <div>
      <PageHeader
        title="Reports"
        description="Moderate user-submitted content reports"
        action={
          <button
            type="button"
            onClick={() => setShowOpenOnly((v) => !v)}
            className="rounded-lg bg-white px-4 py-2 text-sm font-medium text-slate-700 ring-1 ring-slate-200 hover:bg-slate-50"
          >
            {showOpenOnly ? "Show all reports" : "Show open only"}
          </button>
        }
      />

      <ReportList showOpenOnly={showOpenOnly} />
    </div>
  );
}
