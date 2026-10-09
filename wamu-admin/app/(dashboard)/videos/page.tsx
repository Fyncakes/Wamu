"use client";

import { useCallback, useEffect, useState } from "react";
import { api } from "@/lib/api";
import { PageHeader } from "@/components/page-header";
import { LoadingSpinner } from "@/components/loading-spinner";

type Retention = {
  archive_after_days: number;
  purge_after_days: number;
};

export default function VideosSettingsPage() {
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [running, setRunning] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [message, setMessage] = useState<string | null>(null);
  const [archiveDays, setArchiveDays] = useState(180);
  const [purgeDays, setPurgeDays] = useState(365);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const data = await api.admin.getVideoRetention();
      setArchiveDays(data.archive_after_days);
      setPurgeDays(data.purge_after_days);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to load settings");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  async function handleSave(e: React.FormEvent) {
    e.preventDefault();
    setSaving(true);
    setMessage(null);
    setError(null);
    try {
      const body: Retention = {
        archive_after_days: Number(archiveDays),
        purge_after_days: Number(purgeDays),
      };
      const saved = await api.admin.putVideoRetention(body);
      setArchiveDays(saved.archive_after_days);
      setPurgeDays(saved.purge_after_days);
      setMessage("Retention settings saved.");
    } catch (err) {
      setError(err instanceof Error ? err.message : "Save failed");
    } finally {
      setSaving(false);
    }
  }

  async function handleRunLifecycle() {
    setRunning(true);
    setMessage(null);
    setError(null);
    try {
      const result = await api.admin.runVideoLifecycle();
      setMessage(
        `Lifecycle run complete — archived ${result.archived}, permanently deleted ${result.purged}.`,
      );
    } catch (err) {
      setError(err instanceof Error ? err.message : "Lifecycle run failed");
    } finally {
      setRunning(false);
    }
  }

  return (
    <div>
      <PageHeader
        title="Short videos"
        description="Age-based retention: Active → Archived → Permanently deleted. Never based on low views or likes."
      />

      {loading ? (
        <LoadingSpinner />
      ) : (
        <div className="mx-auto max-w-xl space-y-6">
          {error && (
            <div className="rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800">
              {error}
            </div>
          )}
          {message && (
            <div className="rounded-xl border border-emerald-200 bg-emerald-50 px-4 py-3 text-sm text-emerald-800">
              {message}
            </div>
          )}

          <form
            onSubmit={handleSave}
            className="space-y-4 rounded-2xl border border-slate-200 bg-white p-6 shadow-sm"
          >
            <h2 className="font-display text-lg font-semibold text-slate-900">
              Retention period
            </h2>
            <p className="text-sm text-slate-500">
              New merchant clips get time to reach customers. Archiving only
              starts after the age threshold below.
            </p>
            <label className="block text-sm font-medium text-slate-700">
              Archive after (days)
              <input
                type="number"
                min={30}
                max={730}
                value={archiveDays}
                onChange={(e) => setArchiveDays(Number(e.target.value))}
                className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2"
              />
            </label>
            <label className="block text-sm font-medium text-slate-700">
              Permanently delete archived after (days)
              <input
                type="number"
                min={60}
                max={1825}
                value={purgeDays}
                onChange={(e) => setPurgeDays(Number(e.target.value))}
                className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2"
              />
            </label>
            <button
              type="submit"
              disabled={saving}
              className="rounded-lg bg-wamu-600 px-4 py-2 text-sm font-semibold text-white hover:bg-wamu-700 disabled:opacity-60"
            >
              {saving ? "Saving…" : "Save settings"}
            </button>
          </form>

          <div className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
            <h2 className="font-display text-lg font-semibold text-slate-900">
              Run lifecycle now
            </h2>
            <p className="mt-1 text-sm text-slate-500">
              Also runs nightly via Celery. Use this to apply retention
              immediately.
            </p>
            <button
              type="button"
              onClick={handleRunLifecycle}
              disabled={running}
              className="mt-4 rounded-lg border border-slate-300 px-4 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-50 disabled:opacity-60"
            >
              {running ? "Running…" : "Run archive / purge"}
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
