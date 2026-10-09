interface StatsCardProps {
  label: string;
  value: string | number;
  hint?: string;
  icon?: React.ReactNode;
}

export function StatsCard({ label, value, hint, icon }: StatsCardProps) {
  return (
    <div className="rounded-2xl border border-slate-200/80 bg-white p-6 shadow-sm">
      <div className="flex items-start justify-between gap-4">
        <div>
          <p className="text-sm font-medium text-slate-500">{label}</p>
          <p className="mt-2 font-display text-3xl font-semibold text-slate-900">
            {value}
          </p>
          {hint && <p className="mt-1 text-xs text-slate-400">{hint}</p>}
        </div>
        {icon && (
          <div className="flex h-11 w-11 items-center justify-center rounded-xl bg-wamu-50 text-wamu-700">
            {icon}
          </div>
        )}
      </div>
    </div>
  );
}
