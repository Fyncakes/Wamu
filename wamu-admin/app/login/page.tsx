"use client";

import { FormEvent, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { api, ApiError } from "@/lib/api";
import { clearToken, getToken, setToken } from "@/lib/auth";

const PHONE_REGEX = /^\+256[0-9]{9}$/;
const DEMO_ADMIN_PHONE = "+256700000001";

export default function LoginPage() {
  const router = useRouter();
  const [phone, setPhone] = useState(DEMO_ADMIN_PHONE);
  const [otp, setOtp] = useState("");
  const [step, setStep] = useState<"phone" | "otp">("phone");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [message, setMessage] = useState<string | null>(null);

  useEffect(() => {
    if (getToken()) {
      router.replace("/");
    }
  }, [router]);

  async function handleRequestOtp(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setMessage(null);

    if (!PHONE_REGEX.test(phone)) {
      setError("Enter a valid Uganda number: +256 followed by 9 digits.");
      return;
    }

    setLoading(true);

    try {
      const res = await api.auth.requestOtp(phone);
      const hint = res.mock_hint
        ? ` Demo OTP: ${res.mock_hint}`
        : "";
      setMessage((res.message ?? "OTP sent to your phone.") + hint);
      setStep("otp");
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Failed to send OTP");
    } finally {
      setLoading(false);
    }
  }

  async function handleVerifyOtp(e: FormEvent) {
    e.preventDefault();
    setLoading(true);
    setError(null);

    try {
      const tokens = await api.auth.verifyOtp(phone, otp);

      if (tokens.user?.role !== "ADMIN") {
        clearToken();
        setError("This account is not an admin. Use the bootstrap admin phone.");
        return;
      }

      setToken(tokens.access_token);
      router.push("/");
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Invalid OTP");
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="flex min-h-screen">
      <div className="hidden w-1/2 bg-wamu-700 lg:flex lg:flex-col lg:justify-between lg:p-12">
        <div>
          <div className="flex h-12 w-12 items-center justify-center rounded-2xl bg-white/10 font-display text-2xl font-bold text-white">
            W
          </div>
          <h1 className="mt-8 font-display text-4xl font-semibold leading-tight text-white">
            WAMU Admin
          </h1>
          <p className="mt-4 max-w-md text-lg text-wamu-100">
            Manage users, verify businesses, moderate content, and monitor
            marketplace health across Uganda.
          </p>
        </div>
        <p className="text-sm text-wamu-200">
          Connect. Discover. Do More.
        </p>
      </div>

      <div className="flex flex-1 items-center justify-center px-6 py-12">
        <div className="w-full max-w-md">
          <div className="mb-8 lg:hidden">
            <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-wamu-600 font-display text-lg font-bold text-white">
              W
            </div>
            <h1 className="mt-4 font-display text-2xl font-semibold text-slate-900">
              WAMU Admin
            </h1>
          </div>

          <div className="rounded-2xl border border-slate-200 bg-white p-8 shadow-sm">
            <h2 className="font-display text-xl font-semibold text-slate-900">
              {step === "phone" ? "Admin sign in" : "Enter verification code"}
            </h2>
            <p className="mt-1 text-sm text-slate-500">
              {step === "phone"
                ? "Sign in with your admin phone number. OTP is sent via SMS (mock mode shows the code here)."
                : `Code sent to ${phone}`}
            </p>

            {error && (
              <div className="mt-4 rounded-lg bg-red-50 px-4 py-3 text-sm text-red-700">
                {error}
              </div>
            )}
            {message && (
              <div className="mt-4 rounded-lg bg-wamu-50 px-4 py-3 text-sm text-wamu-800">
                {message}
              </div>
            )}

            {step === "phone" ? (
              <form onSubmit={handleRequestOtp} className="mt-6 space-y-4">
                <div>
                  <label
                    htmlFor="phone"
                    className="block text-sm font-medium text-slate-700"
                  >
                    Phone number
                  </label>
                  <input
                    id="phone"
                    type="tel"
                    required
                    value={phone}
                    onChange={(e) => setPhone(e.target.value)}
                    placeholder={DEMO_ADMIN_PHONE}
                    className="mt-1 block w-full rounded-lg border border-slate-300 px-4 py-2.5 text-slate-900 shadow-sm outline-none ring-wamu-500 focus:border-wamu-500 focus:ring-2"
                  />
                  <p className="mt-1.5 text-xs text-slate-400">
                    Demo admin: {DEMO_ADMIN_PHONE} (first sign-in creates an
                    admin account)
                  </p>
                </div>
                <button
                  type="submit"
                  disabled={loading}
                  className="w-full rounded-lg bg-wamu-600 px-4 py-2.5 text-sm font-semibold text-white transition-colors hover:bg-wamu-700 disabled:opacity-60"
                >
                  {loading ? "Sending..." : "Send OTP"}
                </button>
              </form>
            ) : (
              <form onSubmit={handleVerifyOtp} className="mt-6 space-y-4">
                <div>
                  <label
                    htmlFor="otp"
                    className="block text-sm font-medium text-slate-700"
                  >
                    One-time password
                  </label>
                  <input
                    id="otp"
                    type="text"
                    required
                    inputMode="numeric"
                    maxLength={8}
                    value={otp}
                    onChange={(e) => setOtp(e.target.value)}
                    placeholder="123456"
                    className="mt-1 block w-full rounded-lg border border-slate-300 px-4 py-2.5 text-center text-lg tracking-widest text-slate-900 shadow-sm outline-none ring-wamu-500 focus:border-wamu-500 focus:ring-2"
                  />
                </div>
                <button
                  type="submit"
                  disabled={loading}
                  className="w-full rounded-lg bg-wamu-600 px-4 py-2.5 text-sm font-semibold text-white transition-colors hover:bg-wamu-700 disabled:opacity-60"
                >
                  {loading ? "Verifying..." : "Verify & sign in"}
                </button>
                <button
                  type="button"
                  onClick={() => {
                    setStep("phone");
                    setOtp("");
                    setError(null);
                    setMessage(null);
                  }}
                  className="w-full text-sm font-medium text-slate-500 hover:text-slate-700"
                >
                  Use a different number
                </button>
              </form>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
