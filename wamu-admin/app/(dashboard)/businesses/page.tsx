"use client";

import { useMemo, useState } from "react";
import { api, ApiError, unwrapItems } from "@/lib/api";
import { useAsyncData } from "@/lib/hooks";
import { Badge } from "@/components/badge";
import { DataTable } from "@/components/data-table";
import { LoadingSpinner } from "@/components/loading-spinner";
import { PageHeader } from "@/components/page-header";

type Filter = "all" | "PENDING" | "VERIFIED" | "SUSPENDED";

function BusinessList({ filter }: { filter: Filter }) {
  const [actionId, setActionId] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);

  const { data, error, loading } = useAsyncData(async () => {
    const res = await api.admin.getBusinesses();
    return unwrapItems(res);
  }, [refreshKey], 5000);

  const businesses = useMemo(() => {
    const all = data ?? [];
    if (filter === "all") return all;
    return all.filter((b) => b.verification_status === filter);
  }, [data, filter]);

  async function reload() {
    setRefreshKey((k) => k + 1);
  }

  async function handleVerify(id: string) {
    setActionId(id);
    setActionError(null);
    try {
      await api.admin.verifyBusiness(id);
      await reload();
    } catch (err) {
      setActionError(
        err instanceof ApiError ? err.message : "Failed to verify business",
      );
    } finally {
      setActionId(null);
    }
  }

  async function handleSuspend(id: string) {
    setActionId(id);
    setActionError(null);
    try {
      await api.admin.suspendBusiness(id);
      await reload();
    } catch (err) {
      setActionError(
        err instanceof ApiError ? err.message : "Failed to suspend business",
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
        data={businesses}
        keyExtractor={(b) => b.id}
        emptyMessage={
          filter === "PENDING"
            ? "No businesses awaiting verification"
            : "No businesses found"
        }
        columns={[
          {
            key: "name",
            header: "Business",
            render: (b) => (
              <span className="font-medium text-slate-900">{b.name}</span>
            ),
          },
          {
            key: "category",
            header: "Category",
            render: (b) => b.category ?? "—",
          },
          {
            key: "city",
            header: "City",
            render: (b) => b.location?.city ?? "—",
          },
          {
            key: "status",
            header: "Status",
            render: (b) => (
              <Badge status={b.verification_status}>
                {b.verification_status}
              </Badge>
            ),
          },
          {
            key: "rating",
            header: "Rating",
            render: (b) =>
              b.rating != null ? `${b.rating} (${b.review_count ?? 0})` : "—",
          },
          {
            key: "actions",
            header: "Actions",
            className: "text-right",
            render: (b) => (
              <div className="flex justify-end gap-2">
                {(b.verification_status === "PENDING" ||
                  b.verification_status === "UNVERIFIED") && (
                  <button
                    type="button"
                    disabled={actionId === b.id}
                    onClick={() => handleVerify(b.id)}
                    className="rounded-lg bg-wamu-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-wamu-700 disabled:opacity-50"
                  >
                    Verify
                  </button>
                )}
                {b.verification_status !== "SUSPENDED" && (
                  <button
                    type="button"
                    disabled={actionId === b.id}
                    onClick={() => handleSuspend(b.id)}
                    className="rounded-lg bg-red-50 px-3 py-1.5 text-xs font-semibold text-red-700 ring-1 ring-red-200 hover:bg-red-100 disabled:opacity-50"
                  >
                    Suspend
                  </button>
                )}
              </div>
            ),
          },
        ]}
      />
    </>
  );
}

export default function BusinessesPage() {
  const [filter, setFilter] = useState<Filter>("all");

  const filters: { value: Filter; label: string }[] = [
    { value: "all", label: "All" },
    { value: "PENDING", label: "Verification queue" },
    { value: "VERIFIED", label: "Verified" },
    { value: "SUSPENDED", label: "Suspended" },
  ];

  return (
    <div>
      <PageHeader
        title="Businesses"
        description="Review listings, verify new businesses, and manage suspensions"
      />

      <div className="mb-6 flex flex-wrap gap-2">
        {filters.map((f) => (
          <button
            key={f.value}
            type="button"
            onClick={() => setFilter(f.value)}
            className={`rounded-lg px-4 py-2 text-sm font-medium transition-colors ${
              filter === f.value
                ? "bg-wamu-600 text-white"
                : "bg-white text-slate-600 ring-1 ring-slate-200 hover:bg-slate-50"
            }`}
          >
            {f.label}
          </button>
        ))}
      </div>

      <BusinessList filter={filter} />
    </div>
  );
}
