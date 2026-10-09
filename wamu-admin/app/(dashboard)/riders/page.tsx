"use client";

import { useMemo, useState } from "react";
import { api, unwrapItems } from "@/lib/api";
import { useAsyncData } from "@/lib/hooks";
import { Badge } from "@/components/badge";
import { DataTable } from "@/components/data-table";
import { LoadingSpinner } from "@/components/loading-spinner";
import { PageHeader } from "@/components/page-header";

type RiderRow = {
  id: string;
  user_id: string;
  phone?: string;
  display_name: string;
  status: string;
  vehicle_type: string;
  plate_number?: string;
  available_delivery: boolean;
  rating: number;
  delivery_count: number;
  completed_deliveries?: number;
  wamu_rider_ref?: string;
  ai_result?: string;
  submitted_at?: string;
  created_at?: string;
};

type Filter = "PENDING" | "APPROVED" | "SUSPENDED" | "REJECTED" | "ALL";

const PENDING_STATUSES = new Set([
  "DRAFT",
  "SUBMITTED",
  "UNDER_REVIEW",
  "NEEDS_REUPLOAD",
]);

export default function RidersPage() {
  const [filter, setFilter] = useState<Filter>("PENDING");
  const [busyId, setBusyId] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const [detail, setDetail] = useState<Record<string, unknown> | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);

  const statusParam =
    filter === "ALL" ? undefined : filter === "PENDING" ? "PENDING" : filter;

  const { data, error, loading } = useAsyncData(async () => {
    const res = await api.admin.getRiders(
      statusParam ? { status: statusParam } : undefined,
    );
    return unwrapItems(res as RiderRow[] | { items?: RiderRow[] });
  }, [tick, filter], 5000);

  const riders = (data ?? []) as RiderRow[];

  const pendingCountLabel = useMemo(() => {
    if (filter === "PENDING") return `${riders.length} in verification queue`;
    return "Review KYC, AI signals, approve / re-upload / suspend — audit logged";
  }, [filter, riders.length]);

  async function act(
    id: string,
    kind: "approve" | "suspend" | "reject" | "reupload",
  ) {
    setBusyId(id);
    setActionError(null);
    try {
      if (kind === "approve") await api.admin.approveRider(id, "Approved by admin");
      if (kind === "suspend") await api.admin.suspendRider(id, "Suspended for policy");
      if (kind === "reject") await api.admin.rejectRider(id, "Application rejected");
      if (kind === "reupload")
        await api.admin.requestRiderReupload(id, {
          note: "Please re-upload clearer documents",
          reupload_fields: ["SELFIE", "NATIONAL_ID_FRONT", "NATIONAL_ID_BACK"],
        });
      setDetail(null);
      setTick((t) => t + 1);
    } catch (e) {
      setActionError(e instanceof Error ? e.message : "Action failed");
    } finally {
      setBusyId(null);
    }
  }

  async function openReport(id: string) {
    setActionError(null);
    try {
      const d = await api.admin.getRider(id);
      setDetail(d);
    } catch (e) {
      setActionError(e instanceof Error ? e.message : "Failed to load rider");
    }
  }

  function downloadCsv() {
    const header = [
      "id",
      "name",
      "phone",
      "status",
      "ai_result",
      "vehicle",
      "plate",
      "rating",
      "jobs",
      "completed",
      "ref",
      "created_at",
    ];
    const lines = [
      header.join(","),
      ...riders.map((r) =>
        [
          r.id,
          JSON.stringify(r.display_name),
          r.phone ?? "",
          r.status,
          r.ai_result ?? "",
          r.vehicle_type,
          r.plate_number ?? "",
          r.rating,
          r.delivery_count,
          r.completed_deliveries ?? 0,
          r.wamu_rider_ref ?? "",
          r.created_at ?? "",
        ].join(","),
      ),
    ];
    const blob = new Blob([lines.join("\n")], { type: "text/csv;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `wamu-riders-${filter.toLowerCase()}.csv`;
    a.click();
    URL.revokeObjectURL(url);
  }

  const verification = (detail?.verification ?? null) as Record<string, unknown> | null;
  const aiChecks =
    verification && typeof verification.ai_checks === "object" && verification.ai_checks
      ? ((verification.ai_checks as { checks?: Record<string, string> }).checks ?? {})
      : {};
  const documents = (verification?.documents as Record<string, unknown>[] | undefined) ?? [];

  if (loading && !data) return <LoadingSpinner />;

  return (
    <div>
      <PageHeader title="Rider verification" description={pendingCountLabel} />

      <div className="mb-4 flex flex-wrap items-center gap-2">
        {(
          [
            ["PENDING", "Verification queue"],
            ["APPROVED", "Verified"],
            ["REJECTED", "Rejected"],
            ["SUSPENDED", "Suspended"],
            ["ALL", "All"],
          ] as const
        ).map(([key, label]) => (
          <button
            key={key}
            type="button"
            onClick={() => setFilter(key)}
            className={`rounded-full px-3 py-1.5 text-sm font-medium ${
              filter === key
                ? "bg-wamu-600 text-white"
                : "bg-slate-100 text-slate-700 hover:bg-slate-200"
            }`}
          >
            {label}
          </button>
        ))}
        <button
          type="button"
          onClick={downloadCsv}
          className="ml-auto rounded-lg border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50"
        >
          Export CSV
        </button>
      </div>

      {(error || actionError) && (
        <p className="mb-4 text-sm text-red-600">{actionError ?? error}</p>
      )}

      <DataTable
        data={riders}
        keyExtractor={(r) => r.id}
        emptyMessage={
          filter === "PENDING"
            ? "No rider applications waiting"
            : "No riders in this filter"
        }
        columns={[
          {
            key: "name",
            header: "Rider",
            render: (r) => (
              <div>
                <div className="font-medium">{r.display_name}</div>
                <div className="text-xs text-slate-500">{r.wamu_rider_ref ?? ""}</div>
              </div>
            ),
          },
          { key: "phone", header: "Phone", render: (r) => r.phone ?? "—" },
          {
            key: "ai",
            header: "AI",
            render: (r) => r.ai_result ?? "—",
          },
          {
            key: "status",
            header: "Status",
            render: (r) => <Badge status={r.status}>{r.status}</Badge>,
          },
          {
            key: "rating",
            header: "Rating",
            render: (r) => `★ ${Number(r.rating).toFixed(1)}`,
          },
          {
            key: "actions",
            header: "Actions",
            render: (r) => (
              <div className="flex flex-wrap gap-2">
                <button
                  type="button"
                  className="text-xs font-medium text-sky-700 hover:underline"
                  onClick={() => openReport(r.id)}
                >
                  Open
                </button>
                {PENDING_STATUSES.has(r.status) && (
                  <>
                    <button
                      type="button"
                      disabled={busyId === r.id}
                      className="text-xs font-medium text-emerald-700 hover:underline disabled:opacity-50"
                      onClick={() => act(r.id, "approve")}
                    >
                      Approve
                    </button>
                    <button
                      type="button"
                      disabled={busyId === r.id}
                      className="text-xs font-medium text-amber-700 hover:underline disabled:opacity-50"
                      onClick={() => act(r.id, "reupload")}
                    >
                      Re-upload
                    </button>
                    <button
                      type="button"
                      disabled={busyId === r.id}
                      className="text-xs font-medium text-red-700 hover:underline disabled:opacity-50"
                      onClick={() => act(r.id, "reject")}
                    >
                      Reject
                    </button>
                  </>
                )}
                {r.status === "APPROVED" && (
                  <button
                    type="button"
                    disabled={busyId === r.id}
                    className="text-xs font-medium text-amber-700 hover:underline disabled:opacity-50"
                    onClick={() => act(r.id, "suspend")}
                  >
                    Suspend
                  </button>
                )}
                {r.status === "SUSPENDED" && (
                  <button
                    type="button"
                    disabled={busyId === r.id}
                    className="text-xs font-medium text-emerald-700 hover:underline disabled:opacity-50"
                    onClick={() => act(r.id, "approve")}
                  >
                    Reinstate
                  </button>
                )}
              </div>
            ),
          },
        ]}
      />

      {detail && (
        <div className="fixed inset-0 z-40 flex items-center justify-center bg-black/40 p-4">
          <div className="max-h-[90vh] w-full max-w-2xl overflow-y-auto rounded-2xl bg-white p-6 shadow-xl">
            <div className="mb-4 flex items-start justify-between gap-3">
              <div>
                <h2 className="font-display text-xl font-semibold">
                  {String(detail.display_name ?? "Rider")}
                </h2>
                <p className="text-sm text-slate-500">
                  {String(detail.wamu_rider_ref ?? "")} · {String(detail.phone ?? "")}
                </p>
              </div>
              <button
                type="button"
                className="text-sm text-slate-500 hover:text-slate-800"
                onClick={() => setDetail(null)}
              >
                Close
              </button>
            </div>

            <dl className="grid grid-cols-2 gap-3 text-sm sm:grid-cols-3">
              {[
                ["Status", detail.status],
                ["AI result", detail.ai_result ?? verification?.ai_result],
                ["NIN", verification?.nin ?? "—"],
                ["DOB", verification?.date_of_birth ?? "—"],
                ["Licence", verification?.licence_number ?? "—"],
                ["Moto reg", verification?.motorcycle_reg ?? detail.plate_number],
                ["Insurance", verification?.insurance_policy ?? "—"],
                ["Earnings", `UGX ${Number(detail.earnings_ugx ?? 0).toLocaleString()}`],
              ].map(([k, v]) => (
                <div key={String(k)} className="rounded-lg bg-slate-50 p-3">
                  <dt className="text-xs uppercase tracking-wide text-slate-500">{String(k)}</dt>
                  <dd className="mt-1 break-all font-medium text-slate-900">
                    {String(v ?? "—")}
                  </dd>
                </div>
              ))}
            </dl>

            <h3 className="mb-2 mt-5 text-sm font-semibold text-slate-800">AI analysis</h3>
            <ul className="mb-4 grid grid-cols-2 gap-2 text-sm">
              {Object.keys(aiChecks).length === 0 ? (
                <li className="text-slate-500">No AI run yet</li>
              ) : (
                Object.entries(aiChecks).map(([k, v]) => (
                  <li key={k} className="rounded-lg border border-slate-200 px-3 py-2">
                    <span className="text-slate-600">{k.replaceAll("_", " ")}</span>
                    <span className="float-right font-semibold">{v}</span>
                  </li>
                ))
              )}
            </ul>
            <p className="mb-4 text-xs text-slate-500">
              AI results are verification signals for admins — not proof a government
              document is genuine. Connect an authorized government API later after
              licensing.
            </p>

            <h3 className="mb-2 text-sm font-semibold text-slate-800">Documents (admin only)</h3>
            <ul className="mb-5 space-y-2 text-sm">
              {documents.length === 0 ? (
                <li className="text-slate-500">No documents uploaded</li>
              ) : (
                documents.map((d) => (
                  <li
                    key={`${d.doc_type}-${d.url}`}
                    className="rounded-lg border border-slate-200 px-3 py-2"
                  >
                    <div className="font-medium">{String(d.doc_type)}</div>
                    {d.url ? (
                      <a
                        className="break-all text-sky-700 underline"
                        href={String(d.url)}
                        target="_blank"
                        rel="noreferrer"
                      >
                        {String(d.url)}
                      </a>
                    ) : null}
                  </li>
                ))
              )}
            </ul>

            <div className="flex flex-wrap gap-2">
              {PENDING_STATUSES.has(String(detail.status)) && (
                <>
                  <button
                    type="button"
                    disabled={busyId === String(detail.id)}
                    className="rounded-lg bg-emerald-600 px-3 py-2 text-sm font-medium text-white disabled:opacity-50"
                    onClick={() => act(String(detail.id), "approve")}
                  >
                    Approve rider
                  </button>
                  <button
                    type="button"
                    disabled={busyId === String(detail.id)}
                    className="rounded-lg border border-amber-300 px-3 py-2 text-sm font-medium text-amber-800 disabled:opacity-50"
                    onClick={() => act(String(detail.id), "reupload")}
                  >
                    Request re-upload
                  </button>
                  <button
                    type="button"
                    disabled={busyId === String(detail.id)}
                    className="rounded-lg border border-red-300 px-3 py-2 text-sm font-medium text-red-700 disabled:opacity-50"
                    onClick={() => act(String(detail.id), "reject")}
                  >
                    Reject
                  </button>
                </>
              )}
              {detail.status === "APPROVED" && (
                <button
                  type="button"
                  disabled={busyId === String(detail.id)}
                  className="rounded-lg border border-slate-300 px-3 py-2 text-sm font-medium disabled:opacity-50"
                  onClick={() => act(String(detail.id), "suspend")}
                >
                  Suspend
                </button>
              )}
            </div>

            <p className="mt-4 text-xs text-slate-500">
              Actions are written to Audit Logs. Customers never see NIN, licence,
              insurance, or selfie verification media.
            </p>
          </div>
        </div>
      )}
    </div>
  );
}
