"use client";

import { useState } from "react";
import { api, unwrapItems } from "@/lib/api";
import type { User } from "@/lib/types";
import { useAsyncData } from "@/lib/hooks";
import { Badge } from "@/components/badge";
import { DataTable } from "@/components/data-table";
import { LoadingSpinner } from "@/components/loading-spinner";
import { PageHeader } from "@/components/page-header";

function displayName(user: User): string {
  const profile = user.profile;
  if (profile?.first_name || profile?.last_name) {
    return [profile.first_name, profile.last_name].filter(Boolean).join(" ");
  }
  return profile?.username ?? user.phone;
}

export default function UsersPage() {
  const [busyId, setBusyId] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const { data, error, loading } = useAsyncData(async () => {
    const res = await api.admin.getUsers();
    return unwrapItems(res);
  }, [tick]);

  if (loading && !data) return <LoadingSpinner />;

  const users = data ?? [];

  async function toggleStatus(user: User) {
    setBusyId(user.id);
    try {
      if (user.status === "SUSPENDED") {
        await api.admin.activateUser(user.id);
      } else {
        await api.admin.suspendUser(user.id);
      }
      setTick((t) => t + 1);
    } catch (e) {
      console.error(e);
      alert(e instanceof Error ? e.message : "Failed to update user");
    } finally {
      setBusyId(null);
    }
  }

  return (
    <div>
      <PageHeader
        title="Users"
        description="Manage registered WAMU customer and business accounts"
      />

      {error && (
        <div className="mb-6 rounded-lg bg-red-50 px-4 py-3 text-sm text-red-700">
          {error}
        </div>
      )}

      <DataTable
        data={users}
        keyExtractor={(u) => u.id}
        emptyMessage="No users found"
        columns={[
          {
            key: "name",
            header: "Name",
            render: (u) => (
              <span className="font-medium text-slate-900">{displayName(u)}</span>
            ),
          },
          {
            key: "phone",
            header: "Phone",
            render: (u) => u.phone,
          },
          {
            key: "email",
            header: "Gmail / Email",
            render: (u) => u.email ?? "—",
          },
          {
            key: "role",
            header: "Role",
            render: (u) => (
              <Badge status={u.role ?? "CUSTOMER"}>
                {(u.role ?? "CUSTOMER").toUpperCase()}
              </Badge>
            ),
          },
          {
            key: "status",
            header: "Status",
            render: (u) => <Badge status={u.status}>{u.status}</Badge>,
          },
          {
            key: "created",
            header: "Joined",
            render: (u) =>
              u.created_at
                ? new Date(u.created_at).toLocaleDateString("en-UG")
                : "—",
          },
          {
            key: "actions",
            header: "Actions",
            render: (u) => (
              <button
                type="button"
                disabled={busyId === u.id}
                onClick={() => toggleStatus(u)}
                className="rounded border border-slate-300 px-2 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50"
              >
                {u.status === "SUSPENDED" ? "Activate" : "Suspend"}
              </button>
            ),
          },
        ]}
      />
    </div>
  );
}
