"use client";

import { useState } from "react";
import { api, unwrapItems } from "@/lib/api";
import { useAsyncData } from "@/lib/hooks";
import { DataTable } from "@/components/data-table";
import { LoadingSpinner } from "@/components/loading-spinner";
import { PageHeader } from "@/components/page-header";

type NotifRow = {
  id: string;
  user_id: string;
  type: string;
  title: string;
  body: string;
  created_at?: string;
};

export default function AdminNotificationsPage() {
  const [tick, setTick] = useState(0);
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [audience, setAudience] = useState("ALL");
  const [busy, setBusy] = useState(false);

  const { data, error, loading } = useAsyncData(async () => {
    const res = await api.admin.getNotifications();
    return unwrapItems(res as NotifRow[] | { items?: NotifRow[] });
  }, [tick]);

  async function broadcast() {
    if (!title.trim() || !body.trim()) return;
    setBusy(true);
    try {
      const res = await api.admin.broadcastNotification({
        title: title.trim(),
        body: body.trim(),
        audience,
      });
      alert(`Sent to ${res.sent} users (${res.audience})`);
      setTitle("");
      setBody("");
      setTick((t) => t + 1);
    } catch (e) {
      alert(e instanceof Error ? e.message : "Broadcast failed");
    } finally {
      setBusy(false);
    }
  }

  if (loading && !data) return <LoadingSpinner />;
  const rows = (data ?? []) as NotifRow[];

  return (
    <div>
      <PageHeader title="Notifications" description="In-app alerts and admin broadcasts" />
      {error && <p className="mb-4 text-sm text-red-600">{error}</p>}

      <div className="mb-8 rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
        <h2 className="mb-3 font-display text-lg font-semibold">Broadcast</h2>
        <div className="grid gap-3 sm:grid-cols-2">
          <input
            className="rounded-lg border border-slate-300 px-3 py-2 text-sm"
            placeholder="Title"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
          />
          <select
            className="rounded-lg border border-slate-300 px-3 py-2 text-sm"
            value={audience}
            onChange={(e) => setAudience(e.target.value)}
          >
            <option value="ALL">All users</option>
            <option value="BUSINESSES">Business owners</option>
            <option value="RIDERS">Riders</option>
          </select>
        </div>
        <textarea
          className="mt-3 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm"
          rows={3}
          placeholder="Message body"
          value={body}
          onChange={(e) => setBody(e.target.value)}
        />
        <button
          type="button"
          disabled={busy}
          onClick={broadcast}
          className="mt-3 rounded-lg bg-wamu-600 px-4 py-2 text-sm font-medium text-white hover:bg-wamu-700 disabled:opacity-50"
        >
          {busy ? "Sending…" : "Send broadcast"}
        </button>
      </div>

      <DataTable
        data={rows}
        keyExtractor={(r) => r.id}
        columns={[
          { key: "when", header: "When", render: (r) => r.created_at ?? "—" },
          { key: "type", header: "Type", render: (r) => r.type },
          { key: "title", header: "Title", render: (r) => r.title },
          { key: "body", header: "Body", render: (r) => r.body },
          {
            key: "user",
            header: "User",
            render: (r) => r.user_id.slice(0, 8),
          },
        ]}
      />
    </div>
  );
}
