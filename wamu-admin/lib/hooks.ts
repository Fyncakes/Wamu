"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { ApiError } from "./api";

interface AsyncState<T> {
  data: T | null;
  error: string | null;
  loading: boolean;
}

/**
 * Fetch data once (and when deps change). Optionally poll every `refreshIntervalMs`
 * so admin queues stay near real-time during live demos.
 */
export function useAsyncData<T>(
  fetcher: () => Promise<T>,
  deps: unknown[] = [],
  refreshIntervalMs = 0,
): AsyncState<T> {
  const router = useRouter();
  const [state, setState] = useState<AsyncState<T>>({
    data: null,
    error: null,
    loading: true,
  });

  useEffect(() => {
    let cancelled = false;

    const run = (showLoading: boolean) => {
      if (showLoading) {
        setState((prev) => ({ ...prev, loading: prev.data == null, error: null }));
      }
      fetcher()
        .then((data) => {
          if (!cancelled) {
            setState({ data, error: null, loading: false });
          }
        })
        .catch((err: unknown) => {
          if (!cancelled) {
            if (err instanceof ApiError && err.status === 401) {
              router.push("/login");
              return;
            }
            const message =
              err instanceof Error ? err.message : "Request failed";
            setState((prev) => ({
              data: prev.data,
              error: message,
              loading: false,
            }));
          }
        });
    };

    run(true);
    let timer: ReturnType<typeof setInterval> | undefined;
    if (refreshIntervalMs > 0) {
      timer = setInterval(() => run(false), refreshIntervalMs);
    }

    return () => {
      cancelled = true;
      if (timer) clearInterval(timer);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);

  return state;
}
