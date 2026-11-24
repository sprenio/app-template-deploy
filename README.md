# app-template-deploy

Universal zero-downtime Docker Compose and blue/green deployment repository for applications built from the Go/React template (`React`, `Go`, `MariaDB`, `Redis`, `RabbitMQ`).

This repository is designed to be cloned directly onto a production server (VPS). It contains only runtime deployment manifests and orchestration scripts — no application source code or build tools are required on the host.

---

## 1. Directory Structure

```text
app-template-deploy/
├── .env.example
├── .gitignore
├── README.md
├── deploy.sh
├── docker-compose.yml
├── db/
│   └── 00_create_db_changes.sql
└── nginx/
    ├── frontend-blue.conf
    ├── frontend-green.conf
    ├── router-blue.conf
    ├── router-green.conf
    └── router-active/
        └── default.conf
```

---

## 2. Architecture & Deployment Strategy

- **Images**: Pre-built Docker images hosted on GitHub Container Registry (GHCR), resolved dynamically from `GHCR_OWNER`, `APP_SLUG`, and the release `<tag>`:
  - `ghcr.io/<owner>/<slug>-backend-webserver:<tag>`
  - `ghcr.io/<owner>/<slug>-frontend:<tag>`
  - `ghcr.io/<owner>/<slug>-backend-consumer:<tag>`
  - `ghcr.io/<owner>/<slug>-backend-cron:<tag>`
  - `ghcr.io/<owner>/<slug>-db-migrator:<tag>`
- **Isolated Project & Network**: Each deployment uses its own Compose project name (`COMPOSE_PROJECT_NAME`, defaulting to `APP_SLUG`) and isolated internal bridge network (`app-internal` scoped to the project), so multiple template apps can run on the same VPS without colliding.
- **Blue / Green Deployment**: The web application runs in isolated slots (`blue` and `green`), toggled cleanly by a local Nginx router (`router`).
- **Database Migrations**: One-shot `db-migrator` container executes MariaDB migrations before traffic is routed to the new slot.
- **Singleton Workers**: Asynchronous workers (`consumer` and `cron`) are stopped and updated before traffic cutover to prevent dual processing.
- **Shared Infrastructure**: MariaDB, RabbitMQ, and Redis remain continuously running and are not restarted during regular releases.

---

## 3. Server Requirements

The VPS host must meet the following criteria:

- Docker Engine (v24+) & Docker Compose v2 (`docker compose`).
- Outbound network access to GitHub Container Registry (`ghcr.io`).
- Configured local `.env` file with `GHCR_OWNER`, `APP_SLUG`, service credentials, and storage paths (see `.env.example`).
- External Docker networks: `reverse-proxy` and `db-admin`.
- Sufficient persistent storage for databases, broker queues, and application logs.
Check the host architecture:

```bash
uname -m
docker info --format '{{.Architecture}}'
```

---

## 4. Initial Production Server Setup

Example assumed directory on the VPS: `/srv/<app-slug>` (for example, `/srv/my-app`).

### 4.1 Clone Repository

```bash
APP_DIR="/srv/<app-slug>"
sudo mkdir -p "\$APP_DIR"
sudo chown -R "\$USER":"$USER" "$APP_DIR"
git clone <app-template-deploy-repo-url> "\$APP_DIR"
cd "\$APP_DIR"
chmod +x deploy.sh
```

### 4.2 Configure Environment (`.env`)

Copy the example environment template and fill in all real production values, including `GHCR_OWNER` and `APP_SLUG` matching the application's release workflow:

```bash
cp .env.example .env
chmod 600 .env
nano .env
```

Ensure all paths defined for persistent data (such as `STORAGE_DIR`) are configured in `.env`. The deployment script automatically verifies, creates, and sets permissions on all storage directories (`STORAGE_DIR`, `DB_DATA_DIR`, `DB_LOGS_DIR`, `RABBITMQ_DATA_DIR`, `RABBITMQ_LOGS_DIR`, `REDIS_DATA_DIR`, `NGINX_LOGS_DIR`, `ASSETS_DIR`) during deployment.

### 4.3 Create External Docker Networks

Create the required external bridge networks if they do not already exist:

```bash
for network in reverse-proxy db-admin; do
  docker network inspect "$network" >/dev/null 2>&1 \
    || docker network create "$network"
done
```

> **Note**: An upstream edge proxy (e.g., system Nginx, Traefik, or Caddy) must connect to `reverse-proxy` and proxy requests to `<app-slug>-frontend:80` (the network alias registered by `router` on `reverse-proxy`).

### 4.4 Authenticate with GHCR

Generate a GitHub Personal Access Token (classic) with `read:packages` scope, then authenticate on the VPS:

```bash
echo "YOUR_GITHUB_TOKEN" | docker login ghcr.io \
  -u YOUR_GITHUB_USERNAME \
  --password-stdin
```

---

## 5. Deployment

### 5.1 First Deployment

Ensure your `.env` file is ready and networks are created, then run:

```bash
./deploy.sh v1.0.0
```

The script validates `GHCR_OWNER`, `APP_SLUG`, and the release tag format (`vX.Y.Z`), sets `IMAGE_PREFIX` and `COMPOSE_PROJECT_NAME`, initializes the router configuration for the initial slot (`blue`), and performs the deployment.

### 5.2 Subsequent Deployments

When a new version tag is published and images are ready in GHCR:

```bash
git pull
./deploy.sh v1.0.1
```

The script automatically:
1. Detects the currently active slot (`blue` or `green`) and targets the alternate one.
2. Ensures shared infrastructure (`db`, `rabbitmq`, `redis`) is healthy.
3. Pulls new release images from GHCR using `IMAGE_PREFIX` and the target tag.
4. Executes database migrations via `db-migrator`.
5. Starts the target backend and frontend containers.
6. Verifies HTTP health checks for the new slot.
7. Gracefully stops previous singleton workers and launches the new versions.
8. Safely reloads the Nginx router to direct incoming traffic to the new slot.
9. Records the new active slot into `nginx/active-slot`.
10. Shuts down the previous application slot containers.

---

## 6. Operations & Troubleshooting

Run all commands from the `/srv/<app-slug>` repository root.

### View Service Status

```bash
docker compose ps
```

### Active Slot

```bash
cat nginx/active-slot
```

### Inspect Logs

```bash
# Web application (replace blue with green if green is active)
docker compose logs -f backend-blue
docker compose logs -f frontend-blue

# Workers
docker compose logs -f consumer
docker compose logs -f cron

# Router
docker compose logs -f router

# Infrastructure
docker compose logs -f db rabbitmq redis
```

### Test Router Configuration

```bash
docker compose exec router nginx -t
```

---

## 7. Safety Rules

- **Never** run `docker compose down -v` in production (this will destroy persistent volumes).
- **Never** commit `.env` or credentials into Git.
- Always ensure database migrations are backwards-compatible with the currently running application slot before deploying.
- Keep previous release images cached until the new deployment has been verified in production.
