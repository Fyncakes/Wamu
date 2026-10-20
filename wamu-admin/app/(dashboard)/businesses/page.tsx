"use client";

import { useMemo, useState } from "react";
import { api, ApiError, unwrapItems } from "@/lib/api";
import { useAsyncData } from "@/lib/hooks";
import { Badge } from "@/components/badge";
import { DataTable } from "@/components/data-table";
import { LoadingSpinner } from "@/components/loading-spinner";
import { PageHeader } from "@/components/page-header";

type Filter = "all" | "PENDING" | "UNVERIFIED" | "VERIFIED" | "SUSPENDED" | "KYC_QUEUE";

function KycModal({
  businessId,
  onClose,
  onDone,
}: {
  businessId: string;
  onClose: () => void;
  onDone: () => void;
}) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const { data, loading, error } = useAsyncData(
    () => api.admin.getMerchantKyc(businessId),
    [businessId],
  );

  async function act(kind: "approve" | "reject" | "reupload") {
    setBusy(true);
    setErr(null);
    try {
      if (kind === "approve") await api.admin.approveMerchantKyc(businessId);
      if (kind === "reject") await api.admin.rejectMerchantKyc(businessId);
      if (kind === "reupload") await api.admin.requestMerchantKycReupload(businessId);
      onDone();
      onClose();
    } catch (e) {
      setErr(e instanceof ApiError ? e.message : "Action failed");
    } finally {
      setBusy(false);
    }
  }

  const docs = Array.isArray(data?.documents) ? (data.documents as Record<string, unknown>[]) : [];

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
      <div className="max-h-[90vh] w-full max-w-lg overflow-y-auto rounded-xl bg-white p-5 shadow-xl">
        <div className="mb-3 flex items-start justify-between gap-3">
          <div>
            <h2 className="text-lg font-semibold text-slate-900">Merchant KYC</h2>
            <p className="text-sm text-slate-500">
              {(data?.business_name as string) ?? businessId} ·{" "}
              {(data?.kyc_status as string) ?? "…"}
            </p>
          </div>
          <button type="button" onClick={onClose} className="text-slate-500 hover:text-slate-800">
            Close
          </button>
        </div>
        {(err || error) && (
          <div className="mb-3 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700">
            {err ?? error}
          </div>
        )}
        {loading || !data ? (
          <LoadingSpinner />
        ) : (
          <>
            <dl className="mb-4 grid grid-cols-2 gap-2 text-sm">
              <div>
                <dt className="text-slate-500">Owner</dt>
                <dd className="font-medium">{(data.owner_full_name as string) ?? "—"}</dd>
              </div>
              <div>
                <dt className="text-slate-500">NIN</dt>
                <dd className="font-mono text-xs">{(data.owner_nin as string) ?? "—"}</dd>
              </div>
              <div>
                <dt className="text-slate-500">AI</dt>
                <dd>{(data.ai_result as string) ?? "—"}</dd>
              </div>
              <div>
                <dt className="text-slate-500">Badge</dt>
                <dd>{(data.verification_status as string) ?? "—"}</dd>
              </div>
            </dl>
            <div className="mb-4 space-y-2">
              <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">
                Documents
              </p>
              {docs.length === 0 && (
                <p className="text-sm text-slate-500">No documents uploaded yet</p>
              )}
              {docs.map((d) => (
                <a
                  key={String(d.doc_type)}
                  href={String(d.url ?? "#")}
                  target="_blank"
                  rel="noreferrer"
                  className="block truncate rounded-lg bg-slate-50 px-3 py-2 text-sm text-wamu-700 ring-1 ring-slate-200 hover:bg-slate-100"
                >
                  {String(d.doc_type)}
                </a>
              ))}
            </div>
            <div className="flex flex-wrap justify-end gap-2">
              <button
                type="button"
                disabled={busy}
                onClick={() => act("reupload")}
                className="rounded-lg bg-amber-50 px-3 py-1.5 text-xs font-semibold text-amber-800 ring-1 ring-amber-200 disabled:opacity-50"
              >
                Request reupload
              </button>
              <button
                type="button"
                disabled={busy}
                onClick={() => act("reject")}
                className="rounded-lg bg-red-50 px-3 py-1.5 text-xs font-semibold text-red-700 ring-1 ring-red-200 disabled:opacity-50"
              >
                Reject
              </button>
              <button
                type="button"
                disabled={busy}
                onClick={() => act("approve")}
                className="rounded-lg bg-wamu-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-wamu-700 disabled:opacity-50"
              >
                Approve KYC
              </button>
            </div>
          </>
        )}
      </div>
    </div>
  );
}

function BusinessList({ filter }: { filter: Filter }) {
  const [actionId, setActionId] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);
  const [kycId, setKycId] = useState<string | null>(null);

  const { data, error, loading } = useAsyncData(async () => {
    if (filter === "KYC_QUEUE") {
      const res = await api.admin.getMerchantKycQueue("QUEUE");
      return unwrapItems(res).map((row) => {
        const r = row as Record<string, unknown>;
        return {
          id: String(r.id),
          name: String(r.business_name ?? "Shop"),
          category: null,
          location: null,
          verification_status: String(r.verification_status ?? "PENDING"),
          rating: null,
          review_count: 0,
          kyc_status: String(r.kyc_status ?? ""),
        };
      });
    }
    const res = await api.admin.getBusinesses();
    return unwrapItems(res);
  }, [refreshKey, filter], 5000);

  const businesses = useMemo(() => {
    const all = data ?? [];
    if (filter === "all" || filter === "KYC_QUEUE") return all;
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
          filter === "PENDING" || filter === "KYC_QUEUE"
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
                {b.kyc_status ? ` · ${b.kyc_status}` : ""}
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
                <button
                  type="button"
                  onClick={() => setKycId(b.id)}
                  className="rounded-lg bg-slate-100 px-3 py-1.5 text-xs font-semibold text-slate-800 ring-1 ring-slate-200 hover:bg-slate-200"
                >
                  Review KYC
                </button>
                {(b.verification_status === "PENDING" ||
                  b.verification_status === "UNVERIFIED") && (
                  <button
                    type="button"
                    disabled={actionId === b.id}
                    onClick={() => handleVerify(b.id)}
                    className="rounded-lg bg-wamu-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-wamu-700 disabled:opacity-50"
                  >
                    Quick verify
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

      {kycId && (
        <KycModal
          businessId={kycId}
          onClose={() => setKycId(null)}
          onDone={reload}
        />
      )}
    </>
  );
}

export default function BusinessesPage() {
  const [filter, setFilter] = useState<Filter>("all");

  const filters: { value: Filter; label: string }[] = [
    { value: "all", label: "All" },
    { value: "KYC_QUEUE", label: "KYC docs queue" },
    { value: "PENDING", label: "Badge pending" },
    { value: "UNVERIFIED", label: "Unverified" },
    { value: "VERIFIED", label: "Verified" },
    { value: "SUSPENDED", label: "Suspended" },
  ];

  return (
    <div>
      <PageHeader
        title="Businesses"
        description="Review KYC documents, verify shops, and manage suspensions"
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
