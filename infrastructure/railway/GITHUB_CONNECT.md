# Railway ↔ GitHub (when repo does not show)

Your repo on GitHub is **`Fyncakes/Wamu`** (capital **W** only). Search for **`Wamu`** or **`Fyncakes/Wamu`**, not “WAMU”.

## Fix A — “Configure GitHub App” loop or empty repo list

Do these in order (use the **same GitHub user** that owns `Fyncakes/Wamu`):

1. **Install / configure the Railway GitHub App**  
   Open [github.com/settings/installations](https://github.com/settings/installations) → find **Railway** → **Configure**.  
   Under **Repository access**, choose **All repositories** (easiest) or **Only select repositories** and add **`Wamu`**.  
   Click **Save**.

2. **Railway account integration**  
   Open [railway.com/account](https://railway.com/account) → **Account Integrations** → **GitHub**.  
   If it looks stuck: **Disconnect**, then **Connect** again and approve GitHub.

3. **OAuth org access (if you use orgs later)**  
   [github.com/settings/applications](https://github.com/settings/applications) → **Authorized OAuth Apps** → **Railway** → grant access to **Fyncakes** if prompted.

4. **Pick the repo in Railway**  
   [Dashboard](https://railway.com/dashboard) → **New** → **GitHub Repository** (or **New Project** → **Deploy from GitHub repo**).  
   Search **`Wamu`** → click **Refresh** (top of repo list) if empty.  
   Select **`Fyncakes/Wamu`**.

5. **Monorepo root directory** (after service is created)  
   Service → **Settings** → **Source** → **Root Directory** → `wamu-backend` → redeploy.

## Fix B — UI quirk (repo list shows but won’t connect)

Some users report needing to **click and hold** on the repo row, or click once and wait, instead of double-clicking. If one click sends you back to “Configure GitHub App”, redo Fix A step 1–2, then **Refresh** the repo list.

## Fix C — Deploy without GitHub (works when App sync is broken)

From your PC (repo already pushed):

```bash
cd wamu-backend
npx @railway/cli login          # opens browser
railway init                    # create/link project
railway add --database postgres
railway add --database redis
railway up                      # builds Dockerfile locally and deploys
```

Then in the dashboard: **Generate domain**, paste variables from `infrastructure/railway/.env.railway.generated`, fix `DATABASE_URL` to `postgresql+asyncpg://…`, add a second service for the worker (or run worker via duplicated service + `worker-beat` command). See [README.md](./README.md).

## What to tell support / the agent

Reply with:

- Exact screen text (e.g. “Configure GitHub App”, “No repositories found”, “Repo not found”).
- GitHub username logged into Railway (must be **Fyncakes** or a collaborator with deploy rights).
- Screenshot of [GitHub → Railway App → Repository access](https://github.com/settings/installations) showing **Wamu** allowed.

Railway help: [Central Station](https://station.railway.com/) — stale repo cache sometimes needs a refresh on their side after you fix GitHub App access.
