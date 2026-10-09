"use client";

export function Header({ onMenuClick }: { onMenuClick?: () => void }) {
  return (
    <header className="sticky top-0 z-10 border-b border-slate-200 bg-white/90 backdrop-blur">
      <div className="flex h-14 items-center justify-between gap-3 px-4 sm:px-6">
        <div className="flex min-w-0 items-center gap-2">
          {onMenuClick ? (
            <button
              type="button"
              onClick={onMenuClick}
              className="rounded-lg p-2 text-slate-700 hover:bg-slate-100 md:hidden"
              aria-label="Open menu"
            >
              <span className="block text-lg leading-none">☰</span>
            </button>
          ) : null}
          <p className="truncate text-sm text-slate-500">
            Connect. Discover. Do More.
          </p>
        </div>
        <div className="flex shrink-0 items-center gap-2">
          <span className="inline-flex h-2 w-2 rounded-full bg-emerald-500" />
          <span className="text-xs font-medium text-slate-600">Admin</span>
        </div>
      </div>
    </header>
  );
}
