"use client";

import { useState } from "react";
import { api } from "@/lib/api";
import { useAsyncData } from "@/lib/hooks";
import type { MerchantPayout, SuspenseItem } from "@/lib/types";
import { Badge } from "@/components/badge";
import { DataTable } from "@/components/data-table";
import { LoadingSpinner } from "@/components/loading-spinner";
import { PageHeader } from "@/components/page-header";
import { StatsCard } from "@/components/stats-card";

function formatMinor(n: number, currency = "UGX"): string {
  return new Intl.NumberFormat("en-UG", {
    style: "currency",
    currency,
    maximumFractionDigits: 0,
  }).format(n);
}

export default function ReconciliationPage() {
  const [busy, setBusy] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [lastRun, setLastRun] = useState<string | null>(null);
  const [tick, setTick] = useState(0);

  const { data: finance } = useAsyncData(
    () => api.admin.getFinanceOverview(),
    [tick],
    10000,
  );
  const { data: suspensePage, error: suspenseError, loading } = useAsyncData(
    () => api.admin.getSuspense({ status: "OPEN" }),
    [tick],
  );
  const { data: queue } = useAsyncData(
    () => api.admin.getPayoutQueue(),
    [tick],
  );
  const { data: riderQueue } = useAsyncData(
    () => api.admin.getRiderPayoutQueue(),
    [tick],
  );
  const { data: owner } = useAsyncData(
    () => api.admin.getOwnerPayouts(),
    [tick],
  );
  const { data: manualRefunds } = useAsyncData(
    () => api.admin.getManualRefunds(),
    [tick],
  );

  async function onRun(includeOrphan = false) {
    setBusy(includeOrphan ? "orphan" : "run");
    setActionError(null);
    try {
      const res = await api.admin.runReconciliation({
        provider: "MTN",
        include_orphan: includeOrphan,
        hours: 48,
      });
      setLastRun(
        `Matched ${res.run.matched} · unmatched ${res.run.unmatched} · suspense ${res.run.suspense} (${res.run.lines_total} lines)`,
      );
      setTick((t) => t + 1);
    } catch (e) {
      setActionError(e instanceof Error ? e.message : "Reconcile failed");
    } finally {
      setBusy(null);
    }
  }

  async function onResolve(id: string) {
    const notes = window.prompt("Resolution notes (required)");
    if (!notes || notes.trim().length < 3) return;
    setBusy(id);
    setActionError(null);
    try {
      await api.admin.resolveSuspense(id, {
        notes: notes.trim(),
        action: "write_off",
      });
      setTick((t) => t + 1);
    } catch (e) {
      setActionError(e instanceof Error ? e.message : "Resolve failed");
    } finally {
      setBusy(null);
    }
  }

  async function onExecutePayout(id: string) {
    setBusy(`ex-${id}`);
    setActionError(null);
    try {
      await api.admin.executePayout(id);
      setTick((t) => t + 1);
    } catch (e) {
      setActionError(e instanceof Error ? e.message : "Execute failed");
    } finally {
      setBusy(null);
    }
  }

  async function onExecuteQueue() {
    if (
      !window.confirm(
        "Execute all pending/failed payouts in the queue via MoMo disbursement?",
      )
    ) {
      return;
    }
    setBusy("queue");
    setActionError(null);
    try {
      const res = await api.admin.executePayoutQueue({ limit: 50 });
      setLastRun(
        `Queue execute: ${res.success} success · ${res.failed} failed · ${res.executed} attempted`,
      );
      setTick((t) => t + 1);
    } catch (e) {
      setActionError(e instanceof Error ? e.message : "Queue execute failed");
    } finally {
      setBusy(null);
    }
  }

  async function onWithdrawCommission() {
    if (!window.confirm("Queue a full commission withdrawal to OWNER_PAYOUT_PHONE?")) {
      return;
    }
    setBusy("owner");
    setActionError(null);
    try {
      const res = await api.admin.requestOwnerPayout({});
      setLastRun(
        `Owner payout ${res.id.slice(0, 8)}… → ${res.status} (${res.amount_minor} UGX)`,
      );
      setTick((t) => t + 1);
    } catch (e) {
      setActionError(e instanceof Error ? e.message : "Owner withdraw failed");
    } finally {
      setBusy(null);
    }
  }

  async function onExecuteOwner(id: string) {
    setBusy(`own-${id}`);
    setActionError(null);
    try {
      await api.admin.executeOwnerPayout(id);
      setTick((t) => t + 1);
    } catch (e) {
      setActionError(e instanceof Error ? e.message : "Execute owner payout failed");
    } finally {
      setBusy(null);
    }
  }

  async function onExecuteRider(id: string) {
    setBusy(`rid-${id}`);
    setActionError(null);
    try {
      await api.admin.executeRiderPayout(id);
      setTick((t) => t + 1);
    } catch (e) {
      setActionError(e instanceof Error ? e.message : "Execute rider payout failed");
    } finally {
      setBusy(null);
    }
  }

  async function onImportStatement() {
    const raw = window.prompt(
      'Paste JSON lines array, e.g. [{"external_ref":"MTN-1","amount_minor":5000}]',
    );
    if (!raw?.trim()) return;
    setBusy("import");
    setActionError(null);
    try {
      const lines = JSON.parse(raw) as Array<{
        external_ref: string;
        amount_minor?: number;
        amount?: number;
      }>;
      if (!Array.isArray(lines)) throw new Error("Expected a JSON array");
      const res = await api.admin.importStatement({
        provider: "MTN",
        lines,
        notes: "admin paste import",
      });
      setLastRun(
        `Import matched ${res.run.matched} · suspense ${res.run.suspense}`,
      );
      setTick((t) => t + 1);
    } catch (e) {
      setActionError(e instanceof Error ? e.message : "Import failed");
    } finally {
      setBusy(null);
    }
  }

  if (loading && tick === 0) return <LoadingSpinner />;

  const suspenseItems: SuspenseItem[] = suspensePage?.items ?? [];
  const queueItems: MerchantPayout[] = queue?.items ?? [];

  return (
    <div>
      <PageHeader
        title="Reconciliation"
        description="Statement matching, suspense queue, and pending payout entitlements"
        action={
          <div className="flex gap-2">
            <button
              type="button"
              onClick={() => onRun(false)}
              disabled={!!busy}
              className="rounded-lg bg-wamu-600 px-4 py-2 text-sm font-medium text-white hover:bg-wamu-700 disabled:opacity-60"
            >
              {busy === "run" ? "Running…" : "Run match"}
            </button>
            <button
              type="button"
              onClick={() => onRun(true)}
              disabled={!!busy}
              className="rounded-lg border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-60"
            >
              {busy === "orphan" ? "…" : "Match + orphan"}
            </button>
            <button
              type="button"
              onClick={onImportStatement}
              disabled={!!busy}
              className="rounded-lg border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-60"
            >
              {busy === "import" ? "…" : "Import JSON"}
            </button>
          </div>
        }
      />

      {(suspenseError || actionError) && (
        <div className="mb-6 rounded-lg bg-red-50 px-4 py-3 text-sm text-red-700">
          {actionError || suspenseError}
        </div>
      )}
      {lastRun && (
        <div className="mb-6 rounded-lg bg-emerald-50 px-4 py-3 text-sm text-emerald-800">
          {lastRun}
        </div>
      )}

      <div className="mb-8 grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <StatsCard
          label="Suspense balance"
          value={
            finance?.suspense_minor != null
              ? formatMinor(finance.suspense_minor)
              : "—"
          }
          hint="Open unmatched statement amounts"
        />
        <StatsCard
          label="Open suspense"
          value={String(suspensePage?.total ?? suspenseItems.length)}
          hint="Items awaiting admin resolve"
        />
        <StatsCard
          label="Payout queue"
          value={String(queue?.total ?? queueItems.length)}
          hint={
            queue?.auto_execute === false
              ? "Auto-execute OFF — entitlements only"
              : "Pending / processing disbursements"
          }
        />
        <StatsCard
          label="Queue amount"
          value={
            finance?.payout_queue_minor != null
              ? formatMinor(Number(finance.payout_queue_minor))
              : "—"
          }
          hint="Net owed to merchants (queued)"
        />
      </div>

      <h2 className="mb-3 font-display text-lg font-semibold text-slate-900">
        Suspense
      </h2>
      <div className="mb-10">
        <DataTable
          data={suspenseItems}
          keyExtractor={(s) => s.id}
          emptyMessage="No open suspense items"
          columns={[
            {
              key: "id",
              header: "Item",
              render: (s) => (
                <span className="font-mono text-xs text-slate-600">
                  {s.id.slice(0, 8)}…
                </span>
              ),
            },
            {
              key: "provider",
              header: "Provider",
              render: (s) => s.provider,
            },
            {
              key: "amount",
              header: "Amount",
              render: (s) => formatMinor(s.amount_minor, s.currency),
            },
            {
              key: "reason",
              header: "Reason",
              render: (s) => (
                <span className="max-w-xs truncate text-sm text-slate-600">
                  {s.reason}
                </span>
              ),
            },
            {
              key: "status",
              header: "Status",
              render: (s) => <Badge status={s.status}>{s.status}</Badge>,
            },
            {
              key: "actions",
              header: "",
              render: (s) => (
                <button
                  type="button"
                  onClick={() => onResolve(s.id)}
                  disabled={busy === s.id}
                  className="text-sm font-medium text-wamu-700 hover:underline disabled:opacity-50"
                >
                  {busy === s.id ? "…" : "Resolve"}
                </button>
              ),
            },
          ]}
        />
      </div>

      <div className="mb-3 flex items-center justify-between gap-3">
        <h2 className="font-display text-lg font-semibold text-slate-900">
          Payout queue
        </h2>
        <button
          type="button"
          onClick={onExecuteQueue}
          disabled={!!busy || queueItems.length === 0}
          className="rounded-lg bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800 disabled:opacity-50"
        >
          {busy === "queue" ? "Executing…" : "Execute queue"}
        </button>
      </div>
      <DataTable
        data={queueItems}
        keyExtractor={(p) => p.id}
        emptyMessage="No pending payouts in queue"
        columns={[
          {
            key: "id",
            header: "Payout",
            render: (p) => (
              <span className="font-mono text-xs text-slate-600">
                {p.id.slice(0, 8)}…
              </span>
            ),
          },
          {
            key: "net",
            header: "Net",
            render: (p) => formatMinor(Number(p.amount), p.currency ?? "UGX"),
          },
          {
            key: "payee",
            header: "Payee",
            render: (p) => p.payee_phone ?? "—",
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
            header: "Queued",
            render: (p) =>
              p.created_at
                ? new Date(p.created_at).toLocaleString("en-UG")
                : "—",
          },
          {
            key: "actions",
            header: "",
            render: (p) =>
              p.status === "SUCCESS" ? (
                <span className="text-xs text-slate-400">—</span>
              ) : (
                <button
                  type="button"
                  onClick={() => onExecutePayout(p.id)}
                  disabled={busy === `ex-${p.id}`}
                  className="text-sm font-medium text-wamu-700 hover:underline disabled:opacity-50"
                >
                  {busy === `ex-${p.id}` ? "…" : "Execute"}
                </button>
              ),
          },
        ]}
      />

      <h2 className="mb-3 mt-10 font-display text-lg font-semibold text-slate-900">
        Manual refunds (ops)
      </h2>
      <p className="mb-3 text-sm text-slate-500">
        Collection refunds where the MoMo reverse API failed — reverse in the
        provider portal, then mark handled offline.
      </p>
      <DataTable
        data={manualRefunds?.items ?? []}
        keyExtractor={(p) => p.id}
        emptyMessage="No manual refunds pending"
        columns={[
          {
            key: "id",
            header: "Payment",
            render: (p) => (
              <span className="font-mono text-xs text-slate-600">
                {p.id.slice(0, 8)}…
              </span>
            ),
          },
          {
            key: "amount",
            header: "Amount",
            render: (p) => formatMinor(Number(p.amount)),
          },
          {
            key: "provider",
            header: "Provider",
            render: (p) => p.provider ?? "—",
          },
          {
            key: "ref",
            header: "Provider ref",
            render: (p) => (
              <span className="font-mono text-xs">
                {p.provider_reference ?? "—"}
              </span>
            ),
          },
          {
            key: "detail",
            header: "Detail",
            render: (p) => (
              <span className="text-sm text-slate-600">
                {p.refund?.detail ?? p.refund?.reason ?? "manual_required"}
              </span>
            ),
          },
        ]}
      />

      <h2 className="mb-3 mt-10 font-display text-lg font-semibold text-slate-900">
        Rider fee queue
      </h2>
      <DataTable
        data={riderQueue?.items ?? []}
        keyExtractor={(p) => p.id}
        emptyMessage="No pending rider fee payouts"
        columns={[
          {
            key: "id",
            header: "Payout",
            render: (p) => (
              <span className="font-mono text-xs text-slate-600">
                {p.id.slice(0, 8)}…
              </span>
            ),
          },
          {
            key: "amount",
            header: "Fee",
            render: (p) => formatMinor(Number(p.amount)),
          },
          {
            key: "payee",
            header: "Payee",
            render: (p) => p.payee_phone,
          },
          {
            key: "status",
            header: "Status",
            render: (p) => <Badge status={p.status}>{p.status}</Badge>,
          },
          {
            key: "actions",
            header: "",
            render: (p) =>
              p.status === "SUCCESS" ? (
                <span className="text-xs text-slate-400">—</span>
              ) : (
                <button
                  type="button"
                  onClick={() => onExecuteRider(p.id)}
                  disabled={busy === `rid-${p.id}`}
                  className="text-sm font-medium text-wamu-700 hover:underline disabled:opacity-50"
                >
                  {busy === `rid-${p.id}` ? "…" : "Execute"}
                </button>
              ),
          },
        ]}
      />

      <div className="mb-3 mt-10 flex items-center justify-between gap-3">
        <div>
          <h2 className="font-display text-lg font-semibold text-slate-900">
            Owner commission
          </h2>
          <p className="text-sm text-slate-500">
            Available{" "}
            {owner
              ? formatMinor(owner.available_commission_minor)
              : "—"}
            {!owner?.owner_payout_phone_set
              ? " · set OWNER_PAYOUT_PHONE"
              : ""}
          </p>
        </div>
        <button
          type="button"
          onClick={onWithdrawCommission}
          disabled={
            !!busy ||
            !owner?.owner_payout_phone_set ||
            (owner?.available_commission_minor ?? 0) <= 0
          }
          className="rounded-lg bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800 disabled:opacity-50"
        >
          {busy === "owner" ? "…" : "Withdraw all"}
        </button>
      </div>
      <DataTable
        data={owner?.items ?? []}
        keyExtractor={(p) => p.id}
        emptyMessage="No owner withdrawals yet"
        columns={[
          {
            key: "id",
            header: "Payout",
            render: (p) => (
              <span className="font-mono text-xs text-slate-600">
                {p.id.slice(0, 8)}…
              </span>
            ),
          },
          {
            key: "amount",
            header: "Amount",
            render: (p) => formatMinor(p.amount_minor),
          },
          {
            key: "payee",
            header: "Payee",
            render: (p) => p.payee_phone,
          },
          {
            key: "status",
            header: "Status",
            render: (p) => <Badge status={p.status}>{p.status}</Badge>,
          },
          {
            key: "actions",
            header: "",
            render: (p) =>
              p.status === "SUCCESS" || p.status === "PROCESSING" ? (
                <span className="text-xs text-slate-400">—</span>
              ) : (
                <button
                  type="button"
                  onClick={() => onExecuteOwner(p.id)}
                  disabled={busy === `own-${p.id}`}
                  className="text-sm font-medium text-wamu-700 hover:underline disabled:opacity-50"
                >
                  {busy === `own-${p.id}` ? "…" : "Execute"}
                </button>
              ),
          },
        ]}
      />
    </div>
  );
}
