"use client";

import { api } from "@/lib/api";
import { useAsyncData } from "@/lib/hooks";
import { Badge } from "@/components/badge";
import { LoadingSpinner } from "@/components/loading-spinner";
import { PageHeader } from "@/components/page-header";

export default function FraudPage() {
  const { data, error, loading } = useAsyncData(() => api.admin.getFraud(), []);

  if (loading && !data) return <LoadingSpinner />;

  const signals = data?.signals ?? [];

  return (
    <div>
      <PageHeader
        title="Fraud / security"
        description="Heuristic risk signals for ops review"
      />
      {error && <p className="mb-4 text-sm text-red-600">{error}</p>}
      <div className="mb-6 flex items-center gap-3">
        <span className="text-sm text-slate-500">Platform status</span>
        <Badge status={data?.status === "ok" ? "ACTIVE" : "PENDING"}>
          {data?.status ?? "unknown"}
        </Badge>
        {data?.checked_at && (
          <span className="text-xs text-slate-400">Checked {data.checked_at}</span>
        )}
      </div>
      {signals.length === 0 ? (
        <p className="rounded-xl border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-800">
          No elevated fraud signals right now.
        </p>
      ) : (
        <ul className="space-y-3">
          {signals.map((s) => (
            <li
              key={s.code}
              className="flex items-center justify-between rounded-xl border border-slate-200 bg-white px-4 py-3"
            >
              <div>
                <p className="font-medium text-slate-900">{s.code}</p>
                <p className="text-xs text-slate-500">Level: {s.level}</p>
              </div>
              <span className="text-lg font-semibold">{s.count}</span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
