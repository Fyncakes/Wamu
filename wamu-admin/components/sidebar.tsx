"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { clearToken } from "@/lib/auth";

const navItems = [
  { href: "/", label: "Dashboard", icon: "◫" },
  { href: "/users", label: "Users", icon: "◎" },
  { href: "/businesses", label: "Businesses", icon: "▣" },
  { href: "/riders", label: "Riders", icon: "🛵" },
  { href: "/orders", label: "Orders", icon: "▤" },
  { href: "/payments", label: "Payments", icon: "◈" },
  { href: "/payouts", label: "Payouts", icon: "⇢" },
  { href: "/deliveries", label: "Deliveries", icon: "📦" },
  { href: "/categories", label: "Categories", icon: "▦" },
  { href: "/reports", label: "Reports", icon: "⚑" },
  { href: "/disputes", label: "Disputes", icon: "⚖" },
  { href: "/fraud", label: "Fraud / security", icon: "🛡" },
  { href: "/notifications", label: "Notifications", icon: "🔔" },
  { href: "/videos", label: "Short videos", icon: "▶" },
  { href: "/audit-logs", label: "Audit logs", icon: "📋" },
  { href: "/health", label: "System Health", icon: "♥" },
];

function NavLinks({
  onNavigate,
}: {
  onNavigate?: () => void;
}) {
  const pathname = usePathname();

  return (
    <nav className="flex-1 space-y-1 overflow-y-auto px-3 py-4">
      {navItems.map((item) => {
        const active =
          item.href === "/"
            ? pathname === "/"
            : pathname.startsWith(item.href);

        return (
          <Link
            key={item.href}
            href={item.href}
            onClick={onNavigate}
            className={`flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-medium transition-colors ${
              active
                ? "bg-wamu-50 text-wamu-800"
                : "text-slate-600 hover:bg-slate-50 hover:text-slate-900"
            }`}
          >
            <span className="text-base opacity-70">{item.icon}</span>
            {item.label}
          </Link>
        );
      })}
    </nav>
  );
}

export function Sidebar({
  mobileOpen = false,
  onClose,
}: {
  mobileOpen?: boolean;
  onClose?: () => void;
}) {
  const router = useRouter();

  function handleLogout() {
    clearToken();
    router.push("/login");
  }

  const panel = (
    <aside className="flex h-full w-64 shrink-0 flex-col border-r border-slate-200 bg-white">
      <div className="border-b border-slate-200 px-6 py-5">
        <div className="flex items-center justify-between gap-3">
          <div className="flex items-center gap-3">
            <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-wamu-600 font-display text-lg font-bold text-white">
              W
            </div>
            <div>
              <p className="font-display text-lg font-semibold text-slate-900">
                WAMU
              </p>
              <p className="text-xs text-slate-500">Uganda Admin</p>
            </div>
          </div>
          {onClose ? (
            <button
              type="button"
              onClick={onClose}
              className="rounded-lg p-2 text-slate-500 hover:bg-slate-100 md:hidden"
              aria-label="Close menu"
            >
              ✕
            </button>
          ) : null}
        </div>
      </div>

      <NavLinks onNavigate={onClose} />

      <div className="border-t border-slate-200 p-4">
        <button
          type="button"
          onClick={handleLogout}
          className="w-full rounded-lg px-3 py-2 text-left text-sm font-medium text-slate-600 transition-colors hover:bg-red-50 hover:text-red-700"
        >
          Sign out
        </button>
      </div>
    </aside>
  );

  return (
    <>
      {/* Desktop */}
      <div className="hidden md:flex md:h-full">{panel}</div>

      {/* Mobile drawer */}
      {mobileOpen ? (
        <div className="fixed inset-0 z-40 md:hidden">
          <button
            type="button"
            className="absolute inset-0 bg-slate-900/40"
            aria-label="Close menu backdrop"
            onClick={onClose}
          />
          <div className="absolute inset-y-0 left-0 shadow-xl">{panel}</div>
        </div>
      ) : null}
    </>
  );
}
