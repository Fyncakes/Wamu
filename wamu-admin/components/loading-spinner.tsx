export function LoadingSpinner({ label = "Loading..." }: { label?: string }) {
  return (
    <div className="flex flex-col items-center justify-center gap-3 py-16">
      <div className="h-8 w-8 animate-spin rounded-full border-2 border-wamu-200 border-t-wamu-600" />
      <p className="text-sm text-slate-500">{label}</p>
    </div>
  );
}
