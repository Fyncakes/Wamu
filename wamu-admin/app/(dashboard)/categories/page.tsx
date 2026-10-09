"use client";

import { api, unwrapItems } from "@/lib/api";
import { useAsyncData } from "@/lib/hooks";
import { Badge } from "@/components/badge";
import { DataTable } from "@/components/data-table";
import { LoadingSpinner } from "@/components/loading-spinner";
import { PageHeader } from "@/components/page-header";

export default function CategoriesPage() {
  const { data, error, loading } = useAsyncData(async () => {
    const res = await api.admin.getCategories();
    return unwrapItems(res);
  });

  if (loading) return <LoadingSpinner />;

  const categories = data ?? [];

  return (
    <div>
      <PageHeader
        title="Categories"
        description="Marketplace categories for business discovery"
      />

      {error && (
        <div className="mb-6 rounded-lg bg-red-50 px-4 py-3 text-sm text-red-700">
          {error}
        </div>
      )}

      <DataTable
        data={categories}
        keyExtractor={(c) => c.id}
        emptyMessage="No categories found"
        columns={[
          {
            key: "name",
            header: "Name",
            render: (c) => (
              <div className="flex items-center gap-2">
                {c.icon_url ? (
                  // eslint-disable-next-line @next/next/no-img-element
                  <img
                    src={c.icon_url}
                    alt=""
                    className="h-6 w-6 rounded object-cover"
                  />
                ) : c.icon ? (
                  <span>{c.icon}</span>
                ) : null}
                <span className="font-medium text-slate-900">{c.name}</span>
              </div>
            ),
          },
          {
            key: "slug",
            header: "Slug",
            render: (c) => (
              <span className="font-mono text-xs text-slate-500">
                {c.slug ?? "—"}
              </span>
            ),
          },
          {
            key: "businesses",
            header: "Businesses",
            render: (c) =>
              c.business_count != null ? String(c.business_count) : "—",
          },
          {
            key: "status",
            header: "Status",
            render: (c) => (
              <Badge variant={c.is_active === false ? "default" : "success"}>
                {c.is_active === false ? "Inactive" : "Active"}
              </Badge>
            ),
          },
        ]}
      />
    </div>
  );
}
