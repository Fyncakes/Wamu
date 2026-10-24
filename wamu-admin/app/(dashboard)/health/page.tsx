"use client";

import { useCallback, useState } from "react";
import { api } from "@/lib/api";
import { useAsyncData } from "@/lib/hooks";
import type { RailsReadiness } from "@/lib/types";
import { Badge } from "@/components/badge";
import { LoadingSpinner } from "@/components/loading-spinner";
import { PageHeader } from "@/components/page-header";

function StatusCard({
  label,
  status,
  detail,
  tone,
}: {
  label: string;
  status: string;
  detail?: string;
  tone?: "success" | "warning" | "danger";
}) {
  const healthy =
    status.toLowerCase() === "ok" ||
    status.toLowerCase() === "healthy" ||
    status.toLowerCase() === "ready" ||
    status.toLowerCase() === "set" ||
    status.toLowerCase() === "off";
  const variant = tone ?? (healthy ? "success" : "danger");

  return (
    <div className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
      <div className="flex items-center justify-between">
        <h3 className="font-display text-lg font-semibold text-slate-900">
          {label}
        </h3>
        <Badge variant={variant}>{status}</Badge>
      </div>
      {detail && <p className="mt-2 text-sm text-slate-500">{detail}</p>}
    </div>
  );
}

function railFlag(on: boolean | undefined): string {
  return on ? "ready" : "not ready";
}

export default function HealthPage() {
  const [refreshKey, setRefreshKey] = useState(0);
  const [lastChecked, setLastChecked] = useState<Date | null>(null);

  const fetchHealth = useCallback(async () => {
    const [health, rails] = await Promise.all([
      api.health.getStatus(),
      api.health.getRails().catch(() => null as RailsReadiness | null),
    ]);
    setLastChecked(new Date());
    return { health, rails };
  }, []);

  const { data, error, loading } = useAsyncData(fetchHealth, [refreshKey]);
  const health = data?.health;
  const rails = data?.rails;
  const momoOtp = health?.payment_momo_otp ?? rails?.payment_momo_otp;

  function handleRefresh() {
    setRefreshKey((k) => k + 1);
  }

  return (
    <div>
      <PageHeader
        title="System Health"
        description="Backend API, database, cache, and private-beta rails"
        action={
          <button
            type="button"
            onClick={handleRefresh}
            disabled={loading}
            className="rounded-lg bg-wamu-600 px-4 py-2 text-sm font-semibold text-white hover:bg-wamu-700 disabled:opacity-60"
          >
            Refresh
          </button>
        }
      />

      {error && (
        <div className="mb-6 rounded-lg bg-red-50 px-4 py-3 text-sm text-red-700">
          {error}
        </div>
      )}

      {loading && !health ? (
        <LoadingSpinner label="Running health checks..." />
      ) : (
        <>
          {lastChecked && (
            <p className="mb-6 text-sm text-slate-500">
              Last checked: {lastChecked.toLocaleString("en-UG")}
            </p>
          )}

          <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
            <StatusCard
              label="API"
              status={health?.status ?? "unknown"}
              detail={
                health?.version
                  ? `Version ${health.version}`
                  : health?.uptime_seconds
                    ? `Uptime: ${Math.floor(health.uptime_seconds / 60)} min`
                    : undefined
              }
            />
            <StatusCard
              label="Database"
              status={health?.database?.status ?? "unknown"}
              detail={
                health?.database?.latency_ms != null
                  ? `Latency: ${health.database.latency_ms}ms`
                  : undefined
              }
            />
            <StatusCard
              label="Redis"
              status={health?.redis?.status ?? "unknown"}
              detail={
                health?.redis?.latency_ms != null
                  ? `Latency: ${health.redis.latency_ms}ms`
                  : undefined
              }
            />
          </div>

          {rails && (
            <div className="mt-8">
              <h2 className="font-display mb-4 text-xl font-semibold text-slate-900">
                Private-beta rails
              </h2>
              <p className="mb-4 text-sm text-slate-500">
                From <code className="text-xs">GET /health/rails</code> — env{" "}
                {String(rails.environment ?? "—")}
                {rails.otp_mock_mode ? " · OTP mock on" : ""}
                {rails.payment_mock_auto_success ? " · MoMo mock auto-success" : ""}
                {momoOtp === false ? " · MTN payment code off" : ""}
                {momoOtp === true ? " · MTN payment code on" : ""}
              </p>
              <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
                <StatusCard
                  label="MTN payment code"
                  status={momoOtp == null ? "unknown" : momoOtp ? "on" : "off"}
                  tone={momoOtp == null ? "warning" : momoOtp ? "warning" : "success"}
                  detail={
                    momoOtp
                      ? "Checkout asks for a Wamu SMS code before the MTN payment finishes."
                      : momoOtp === false
                        ? rails?.mtn_collections_configured
                          ? "Checkout sends the payment to MTN. The extra Wamu SMS code stays off, and the MTN collection keys are set."
                          : "The extra Wamu SMS code stays off. Add the MTN collection keys before a live debit."
                        : "The server did not report this flag."
                  }
                />
                <StatusCard
                  label="Live SMS OTP"
                  status={railFlag(!!rails.ready_for_live_otp)}
                  detail={
                    rails.sms_provider_configured
                      ? "Africa's Talking credentials set"
                      : "Set AFRICASTALKING_* and OTP_MOCK_MODE=false"
                  }
                />
                <StatusCard
                  label="MoMo sandbox"
                  status={railFlag(!!rails.ready_for_momo_sandbox)}
                  detail={
                    rails.ready_for_momo_sandbox
                      ? "MTN sandbox can take a payment."
                      : rails.mtn_collections_configured
                        ? "MTN collection keys are set. Sandbox ready stays off while payment mock auto-success is on."
                        : "Add the MTN collection keys and turn off payment mock auto-success."
                  }
                />
                <StatusCard
                  label="Live disbursement"
                  status={railFlag(!!rails.ready_for_live_disbursement)}
                  detail={
                    rails.ready_for_live_disbursement
                      ? "Keys + public PUBLIC_API_BASE — Execute from Reconciliation"
                      : rails.mtn_disbursement_configured ||
                          rails.airtel_disbursement_configured
                        ? "Need public PUBLIC_API_BASE + mock off + webhook secret"
                        : "Waiting on MTN_DISBURSEMENT_* / AIRTEL_* credentials"
                  }
                />
                <StatusCard
                  label="FCM push"
                  status={rails.fcm_server_key_set ? "set" : "not set"}
                  detail="FCM_SERVER_KEY + flutterfire configure on devices"
                />
                <StatusCard
                  label="Airtel collections"
                  status={rails.airtel_collections_configured ? "set" : "not set"}
                  detail="Optional second rail"
                />
                <StatusCard
                  label="TURN / calls"
                  status={railFlag(!!rails.turn_configured && !rails.turn_urls_look_local)}
                  detail={
                    rails.turn_urls_look_local
                      ? "TURN looks like localhost — phones need public host"
                      : rails.turn_configured
                        ? "TURN credentials present"
                        : "Optional for WebRTC"
                  }
                />
              </div>
            </div>
          )}
        </>
      )}
    </div>
  );
}
