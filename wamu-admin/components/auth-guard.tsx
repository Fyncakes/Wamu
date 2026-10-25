"use client";

import { useEffect, useState } from "react";
import { isAuthenticated } from "@/lib/auth";
import { LoadingSpinner } from "./loading-spinner";

export function AuthGuard({ children }: { children: React.ReactNode }) {
  const [authed, setAuthed] = useState(false);

  useEffect(() => {
    if (isAuthenticated()) {
      setAuthed(true);
      return;
    }
    window.location.replace("/login");
  }, []);

  if (!authed) {
    return <LoadingSpinner label="Opening sign in..." />;
  }

  return <>{children}</>;
}
