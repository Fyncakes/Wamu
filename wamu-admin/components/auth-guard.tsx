"use client";

import { useEffect, useSyncExternalStore } from "react";
import { useRouter } from "next/navigation";
import { isAuthenticated } from "@/lib/auth";
import { LoadingSpinner } from "./loading-spinner";

function subscribe() {
  return () => {};
}

function getAuthSnapshot() {
  return isAuthenticated();
}

function getServerSnapshot() {
  return false;
}

export function AuthGuard({ children }: { children: React.ReactNode }) {
  const router = useRouter();
  const authed = useSyncExternalStore(
    subscribe,
    getAuthSnapshot,
    getServerSnapshot,
  );

  useEffect(() => {
    if (!authed) {
      router.replace("/login");
    }
  }, [authed, router]);

  if (!authed) {
    return <LoadingSpinner label="Checking session..." />;
  }

  return <>{children}</>;
}
