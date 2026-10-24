"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { isAuthenticated } from "@/lib/auth";
import { LoadingSpinner } from "./loading-spinner";

export function AuthGuard({ children }: { children: React.ReactNode }) {
  const router = useRouter();
  const [ready, setReady] = useState(false);
  const [authed, setAuthed] = useState(false);

  useEffect(() => {
    const ok = isAuthenticated();
    setAuthed(ok);
    setReady(true);
    if (!ok) router.replace("/login");
  }, [router]);

  if (!ready || !authed) {
    return <LoadingSpinner label="Checking session..." />;
  }

  return <>{children}</>;
}
