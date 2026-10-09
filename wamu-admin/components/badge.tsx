const variants: Record<string, string> = {
  default: "bg-slate-100 text-slate-700",
  success: "bg-emerald-50 text-emerald-800 ring-emerald-600/20",
  warning: "bg-amber-50 text-amber-800 ring-amber-600/20",
  danger: "bg-red-50 text-red-800 ring-red-600/20",
  info: "bg-sky-50 text-sky-800 ring-sky-600/20",
};

const statusMap: Record<string, keyof typeof variants> = {
  ACTIVE: "success",
  VERIFIED: "success",
  OPEN: "warning",
  PENDING: "warning",
  UNVERIFIED: "default",
  SUSPENDED: "danger",
  RESOLVED: "success",
  DISMISSED: "default",
  COMPLETED: "success",
  SUCCESS: "success",
  CANCELLED: "danger",
  FAILED: "danger",
  PAID: "success",
  PROCESSING: "info",
};

interface BadgeProps {
  children: React.ReactNode;
  variant?: keyof typeof variants;
  status?: string;
}

export function Badge({ children, variant, status }: BadgeProps) {
  const resolved =
    variant ?? (status ? statusMap[status.toUpperCase()] : undefined) ?? "default";

  return (
    <span
      className={`inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium ring-1 ring-inset ${variants[resolved]}`}
    >
      {children}
    </span>
  );
}
