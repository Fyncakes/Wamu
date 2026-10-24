export function BrandMark({ className = "h-10 w-10 rounded-xl" }: { className?: string }) {
  return (
    <img
      src="/wamu-icon.png"
      alt="Wamu"
      className={`${className} object-cover`}
    />
  );
}
