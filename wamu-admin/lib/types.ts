export interface AdminStats {
  users: number;
  businesses: number;
  orders: number;
  payments: number;
  riders?: number;
  riders_pending?: number;
  riders_approved?: number;
  revenue_ugx?: number;
  platform_fee_ugx?: number;
  payout_net_ugx?: number;
  successful_payouts?: number;
  pending_verifications?: number;
  open_reports?: number;
  open_disputes?: number;
  orders_by_status?: Record<string, number>;
  payments_by_status?: Record<string, number>;
}

export interface MerchantPayout {
  id: string;
  payment_id: string;
  order_id: string;
  business_id: string;
  amount: number;
  platform_fee?: number;
  fee_bps?: number;
  currency?: string;
  provider?: string;
  provider_reference?: string | null;
  payee_phone?: string;
  status: string;
  created_at?: string;
}

export interface User {
  id: string;
  phone: string;
  email?: string | null;
  role?: string;
  status: string;
  created_at?: string;
  profile?: {
    first_name?: string;
    last_name?: string;
    username?: string;
  };
}

export interface Business {
  id: string;
  name: string;
  category?: string;
  location?: { city?: string; address_line?: string; district?: string };
  logo_url?: string;
  phone?: string;
  verification_status: "UNVERIFIED" | "PENDING" | "VERIFIED" | "SUSPENDED";
  rating?: number;
  review_count?: number;
  created_at?: string;
}

export interface Order {
  id: string;
  status: string;
  total_amount: number;
  total?: number;
  currency?: string;
  customer_id?: string;
  business_id?: string;
  business_name?: string;
  created_at?: string;
}

export interface Payment {
  id: string;
  order_id?: string;
  amount: number;
  currency?: string;
  status: string;
  provider?: string;
  created_at?: string;
}

export interface Category {
  id: string;
  name: string;
  slug?: string;
  icon?: string;
  icon_url?: string;
  is_active?: boolean;
  business_count?: number;
}

export interface Report {
  id: string;
  target_type: string;
  target_id: string;
  reason: string;
  status: "OPEN" | "RESOLVED" | "DISMISSED";
  reporter_id?: string;
  created_at?: string;
}

export interface OrderDispute {
  id: string;
  order_id: string;
  customer_id: string;
  reason: string;
  description?: string | null;
  status: string;
  resolution_note?: string | null;
  resolved_by_id?: string | null;
  resolved_at?: string | null;
  created_at?: string;
}

export interface HealthStatus {
  status: string;
  version?: string;
  uptime_seconds?: number;
  database?: { status: string; latency_ms?: number };
  redis?: { status: string; latency_ms?: number };
}

export interface RailsReadiness {
  environment?: string;
  payment_mock_auto_success?: boolean;
  otp_mock_mode?: boolean;
  ready_for_live_otp?: boolean;
  ready_for_momo_sandbox?: boolean;
  mtn_collections_configured?: boolean;
  airtel_collections_configured?: boolean;
  fcm_server_key_set?: boolean;
  sms_provider_configured?: boolean;
  turn_configured?: boolean;
  turn_urls_look_local?: boolean;
  [key: string]: unknown;
}

export interface PaginatedResponse<T> {
  items: T[];
  total?: number;
  page?: number;
  page_size?: number;
}

export interface AuthTokens {
  access_token: string;
  refresh_token?: string;
  token_type: string;
  user?: { id: string; phone: string; role: string };
}
