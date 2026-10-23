# MTN-first launch on DigitalOcean

Deploy the **Wamu API** on a single **Droplet** (Docker Compose). Same shape as Hetzner: fixed public IPv4 for **MTN MoMo** sandbox callbacks and portal allowlisting. **Airtel** stays deferred — [`AIRTEL_PORTAL_CHECKLIST.md`](./AIRTEL_PORTAL_CHECKLIST.md).

## Quick path

1. Create a DigitalOcean account and a **Droplet** (Ubuntu 24.04, **2 GB RAM** recommended — `s-1vcpu-2gb`).
2. Follow **[`infrastructure/digitalocean/README.md`](../infrastructure/digitalocean/README.md)**.
3. Generate secrets: `./infrastructure/digitalocean/bootstrap_env.sh` → copy to `.env.do` on the server.
4. Deploy: `DO_HOST=root@DROPLET_IP ./infrastructure/digitalocean/deploy.sh`
5. DNS: `api.wamu.ug` A record → droplet IP; set `PUBLIC_API_BASE=https://api.wamu.ug`.
6. Flutter: `--dart-define=API_BASE_URL=https://api.wamu.ug`

MTN sandbox: [`MTN_RAILWAY_LAUNCH.md`](./MTN_RAILWAY_LAUNCH.md) steps apply — use droplet **egress IP** in MoMo portal instead of Railway hostname.

## Admin website (`wamu-admin`)

Not included in the default Compose stack. Options:

- **Later:** second small Droplet or DO App Platform static/Node service for `wamu-admin` with `NEXT_PUBLIC_API_URL`.
- **Now:** use the mobile app + API; admin can run locally against the public API.
