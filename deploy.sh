#!/usr/bin/env bash
set -Eeuo pipefail

# Usage: ./deploy.sh v1.2.3

TAG="${1:?Usage: ./deploy.sh v1.2.3}"

if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Invalid release tag: $TAG"
    echo "Expected format: v1.2.3"
    exit 1
fi

# Always run from the docker directory.
cd "$(dirname "$0")"

COMPOSE_FILE="docker-compose.yml"
ENV_FILE=".env"

NGINX_DIR="nginx"
ACTIVE_CONFIG="$NGINX_DIR/router-active/default.conf"
ACTIVE_SLOT_FILE="$NGINX_DIR/active-slot"

export IMAGE_TAG="$TAG"

WORKERS_SWITCHED=0
OLD_WORKER_TAG=""

compose() {
    docker compose \
        -f "$COMPOSE_FILE" \
        --env-file "$ENV_FILE" \
        "$@"
}

log() {
    echo
    echo "==> $*"
}

fail() {
    echo
    echo "ERROR: $*"
    exit 1
}

resolve_env_path() {
    local target="$1"
    local line
    line="$(grep -E "^[[:space:]]*${target}=" "$ENV_FILE" | tail -n 1 || true)"
    [[ -n "$line" ]] || return 0
    local val="${line#*=}"
    val="$(echo "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")"

    local depth=0
    while [[ "$val" =~ \$\{?([A-Za-z0-9_]+)\}? ]] && [ $depth -lt 5 ]; do
        local ref="${BASH_REMATCH[1]}"
        local ref_val
        ref_val="$(resolve_env_path "$ref")"
        val="${val//\$\{$ref\}/$ref_val}"
        val="${val//\$$ref/$ref_val}"
        depth=$((depth + 1))
    done
    echo "$val"
}

# ---------------------------------------------------------------------------
# Determine deployment slots
# ---------------------------------------------------------------------------

OLD_SLOT=""

if [[ -f "$ACTIVE_SLOT_FILE" ]]; then
    OLD_SLOT="$(tr -d '[:space:]' < "$ACTIVE_SLOT_FILE")"

    [[ "$OLD_SLOT" == "blue" || "$OLD_SLOT" == "green" ]] \
        || fail "Invalid active slot: $OLD_SLOT"

    if [[ "$OLD_SLOT" == "blue" ]]; then
        TARGET_SLOT="green"
    else
        TARGET_SLOT="blue"
    fi
else
    TARGET_SLOT="blue"
fi

log "Release: $TAG"
log "Previous slot: ${OLD_SLOT:-none}"
log "Target slot: $TARGET_SLOT"

# ---------------------------------------------------------------------------
# Validate deployment files and registry / project variables
# ---------------------------------------------------------------------------

[[ -f "$COMPOSE_FILE" ]] || fail "Missing $COMPOSE_FILE"
[[ -f "$ENV_FILE" ]] || fail "Missing $ENV_FILE"
[[ -f "$NGINX_DIR/router-blue.conf" ]] || fail "Missing router router-blue.conf"
[[ -f "$NGINX_DIR/router-green.conf" ]] || fail "Missing router router-green.conf"

GHCR_OWNER_VAL="$(resolve_env_path "GHCR_OWNER")"
APP_SLUG_VAL="$(resolve_env_path "APP_SLUG")"
PROJECT_NAME_VAL="$(resolve_env_path "COMPOSE_PROJECT_NAME")"

[[ -n "$GHCR_OWNER_VAL" ]] || fail "Missing required variable in $ENV_FILE: GHCR_OWNER"
[[ -n "$APP_SLUG_VAL" ]] || fail "Missing required variable in $ENV_FILE: APP_SLUG"

OWNER_LOWER="$(printf '%s' "$GHCR_OWNER_VAL" | tr '[:upper:]' '[:lower:]')"
SLUG_LOWER="$(printf '%s' "$APP_SLUG_VAL" | tr '[:upper:]' '[:lower:]')"

export IMAGE_PREFIX="ghcr.io/${OWNER_LOWER}/${SLUG_LOWER}"
export APP_SLUG="$SLUG_LOWER"
export COMPOSE_PROJECT_NAME="${PROJECT_NAME_VAL:-$SLUG_LOWER}"

log "Image prefix: $IMAGE_PREFIX"
log "Compose project: $COMPOSE_PROJECT_NAME"

# Initialize active router configuration on first deployment if missing
if [[ ! -f "$ACTIVE_CONFIG" ]]; then
    log "Initializing active router configuration for initial deployment: $TARGET_SLOT"
    mkdir -p "$(dirname "$ACTIVE_CONFIG")"
    cp "$NGINX_DIR/router-$TARGET_SLOT.conf" "$ACTIVE_CONFIG"
fi

# ---------------------------------------------------------------------------
# Ensure persistent storage directories exist with appropriate permissions
# ---------------------------------------------------------------------------

REQUIRED_STORAGE_VARS=(
    STORAGE_DIR
    DB_DATA_DIR
    DB_LOGS_DIR
    RABBITMQ_DATA_DIR
    RABBITMQ_LOGS_DIR
    NGINX_LOGS_DIR
    REDIS_DATA_DIR
    ASSETS_DIR
)

for var_name in "${REQUIRED_STORAGE_VARS[@]}"; do
    resolved_path="$(resolve_env_path "$var_name")"
    [[ -n "$resolved_path" ]] || fail "Missing required directory variable in $ENV_FILE: $var_name"

    if [[ ! -d "$resolved_path" ]]; then
        log "Creating storage directory for $var_name: $resolved_path"
        mkdir -p "$resolved_path"
    fi

    # Handle permissions and ownership based on the directory type
    case "$var_name" in
        DB_DATA_DIR)
            # MariaDB container internal process (usually UID/GID 999) needs ownership of its data directory
            sudo chown -R 999:999 "$resolved_path" 2>/dev/null || true
            chmod 700 "$resolved_path" 2>/dev/null || true
            ;;
        RABBITMQ_DATA_DIR|REDIS_DATA_DIR)
            # Sensitive data directories get strict 700 permissions
            chmod 700 "$resolved_path" 2>/dev/null || true
            ;;
        *)
            # Shared logs and assets get 750 permissions
            chmod 750 "$resolved_path" 2>/dev/null || true
            ;;
    esac
done

# Validate Compose configuration before making changes.
log "Validating Docker Compose configuration"
compose config -q

# ---------------------------------------------------------------------------
# Rollback helpers
# ---------------------------------------------------------------------------

rollback_workers() {
    log "Rolling back background workers"

    compose stop consumer cron || true

    if [[ -n "$OLD_WORKER_TAG" ]]; then
        log "Restoring worker image tag: $OLD_WORKER_TAG"

        IMAGE_TAG="$OLD_WORKER_TAG" \
            compose up -d --no-deps consumer cron || true
    else
        log "No previous worker version available"
    fi
}

rollback_router_config() {
    local backup="$1"

    log "Restoring previous router configuration"

    cp "$backup" "$ACTIVE_CONFIG"

    if compose exec -T router nginx -t; then
        compose exec -T router nginx -s reload || \
            compose restart router || true
    else
        compose restart router || true
    fi
}

# ---------------------------------------------------------------------------
# Start shared infrastructure
# These services are not restarted during normal deployments.
# ---------------------------------------------------------------------------

log "Starting shared infrastructure"

compose up -d db rabbitmq redis

# ---------------------------------------------------------------------------
# Wait for MariaDB
# ---------------------------------------------------------------------------

log "Waiting for MariaDB to become healthy"

DB_ID="$(compose ps -q db)"
[[ -n "$DB_ID" ]] || fail "MariaDB container was not created"

DB_READY=0

for attempt in $(seq 1 60); do
    DB_STATUS="$(docker inspect \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        "$DB_ID")"

    if [[ "$DB_STATUS" == "healthy" ]]; then
        DB_READY=1
        break
    fi

    if [[ "$DB_STATUS" == "unhealthy" || "$DB_STATUS" == "exited" ]]; then
        fail "MariaDB is $DB_STATUS"
    fi

    sleep 2
done

[[ "$DB_READY" == "1" ]] || fail "MariaDB did not become healthy in time"

# ---------------------------------------------------------------------------
# Wait for RabbitMQ
# ---------------------------------------------------------------------------

log "Waiting for RabbitMQ"

RABBITMQ_READY=0

for attempt in $(seq 1 60); do
    if compose exec -T rabbitmq rabbitmq-diagnostics -q ping >/dev/null 2>&1; then
        RABBITMQ_READY=1
        break
    fi

    sleep 2
done

[[ "$RABBITMQ_READY" == "1" ]] || fail "RabbitMQ did not become ready in time"

# ---------------------------------------------------------------------------
# Wait for Redis
# ---------------------------------------------------------------------------

log "Waiting for Redis"

REDIS_READY=0

for attempt in $(seq 1 30); do
    if compose exec -T redis redis-cli ping 2>/dev/null | grep -q PONG; then
        REDIS_READY=1
        break
    fi

    sleep 2
done

[[ "$REDIS_READY" == "1" ]] || fail "Redis did not become ready in time"

# ---------------------------------------------------------------------------
# Detect currently installed worker version
# ---------------------------------------------------------------------------

log "Detecting previous worker version"

for service in consumer cron; do
    CONTAINER_ID="$(compose ps -a -q "$service" | head -n 1)"

    if [[ -n "$CONTAINER_ID" ]]; then
        IMAGE_NAME="$(docker inspect \
            --format '{{.Config.Image}}' "$CONTAINER_ID")"

        if [[ -n "$IMAGE_NAME" ]]; then
            OLD_WORKER_TAG="${IMAGE_NAME##*:}"
            break
        fi
    fi
done

if [[ -n "$OLD_WORKER_TAG" ]]; then
    log "Previous worker tag: $OLD_WORKER_TAG"
else
    log "No previous worker containers found"
fi

# ---------------------------------------------------------------------------
# Pull release images
# ---------------------------------------------------------------------------

log "Pulling application images for $TARGET_SLOT"

compose --profile "$TARGET_SLOT" pull \
    "backend-$TARGET_SLOT" \
    "frontend-$TARGET_SLOT"

log "Pulling worker and migration images"

compose pull consumer cron
compose --profile deploy pull db-migrator

# ---------------------------------------------------------------------------
# Run database migrations
# ---------------------------------------------------------------------------

log "Running database migrations"

compose --profile deploy run --rm --no-deps db-migrator \
    || fail "Database migrations failed. Deployment aborted."

# ---------------------------------------------------------------------------
# Start the target application slot
# ---------------------------------------------------------------------------

log "Starting backend and frontend: $TARGET_SLOT"

compose --profile "$TARGET_SLOT" up -d --no-deps \
    "backend-$TARGET_SLOT" \
    "frontend-$TARGET_SLOT" \
    || fail "Could not start target application slot"

# ---------------------------------------------------------------------------
# Wait for frontend and backend health
# ---------------------------------------------------------------------------

log "Waiting for target frontend and backend health"

FRONTEND_READY=0

for attempt in $(seq 1 30); do
    if compose exec -T "frontend-$TARGET_SLOT" \
        wget -q -O /dev/null http://127.0.0.1/ \
        && compose exec -T "frontend-$TARGET_SLOT" \
        wget -q -O /dev/null http://127.0.0.1/api/health; then

        FRONTEND_READY=1
        break
    fi

    sleep 2
done

[[ "$FRONTEND_READY" == "1" ]] || \
    fail "Target frontend or backend health check failed"

# ---------------------------------------------------------------------------
# Switch singleton workers
# Never run old and new worker versions simultaneously.
# ---------------------------------------------------------------------------

log "Stopping previous workers"

compose stop consumer cron || true

log "Starting workers for release $TAG"

if ! compose up -d --no-deps consumer cron; then
    rollback_workers
    fail "Could not start new workers"
fi

WORKERS_SWITCHED=1

# Give workers time to start and detect immediate crashes.
log "Checking worker startup"

WORKERS_READY=1

for attempt in $(seq 1 10); do
    for service in consumer cron; do
        CONTAINER_ID="$(compose ps -q "$service")"

        if [[ -z "$CONTAINER_ID" ]]; then
            WORKERS_READY=0
            break
        fi

        STATUS="$(docker inspect \
            --format '{{.State.Status}}' "$CONTAINER_ID")"

        if [[ "$STATUS" != "running" ]]; then
            WORKERS_READY=0
            break
        fi
    done

    [[ "$WORKERS_READY" == "1" ]] && break

    sleep 2
    WORKERS_READY=1
done

if [[ "$WORKERS_READY" != "1" ]]; then
    rollback_workers
    WORKERS_SWITCHED=0
    fail "New workers failed to start. Previous workers restored."
fi

# ---------------------------------------------------------------------------
# Switch router to the new application slot
# ---------------------------------------------------------------------------

log "Preparing router switch to $TARGET_SLOT"

BACKUP_CONFIG="$(mktemp "$NGINX_DIR/default.conf.backup.XXXXXX")"
cp "$ACTIVE_CONFIG" "$BACKUP_CONFIG"

TEMP_CONFIG="$(mktemp "$NGINX_DIR/router-active/default.conf.tmp.XXXXXX")"
cp "$NGINX_DIR/router-$TARGET_SLOT.conf" "$TEMP_CONFIG"
mv "$TEMP_CONFIG" "$ACTIVE_CONFIG"

log "Ensuring router is running"

if ! compose up -d router; then
    rollback_router_config "$BACKUP_CONFIG"
    rollback_workers
    WORKERS_SWITCHED=0
    rm -f "$BACKUP_CONFIG"
    fail "Could not start router"
fi

log "Validating new router configuration"

if ! compose exec -T router nginx -t; then
    rollback_router_config "$BACKUP_CONFIG"
    rollback_workers
    WORKERS_SWITCHED=0
    rm -f "$BACKUP_CONFIG"
    fail "Router configuration is invalid. Previous configuration restored."
fi

log "Reloading router"

if ! compose exec -T router nginx -s reload; then
    rollback_router_config "$BACKUP_CONFIG"
    rollback_workers
    WORKERS_SWITCHED=0
    rm -f "$BACKUP_CONFIG"
    fail "Router reload failed. Previous configuration restored."
fi

# ---------------------------------------------------------------------------
# Record active slot
# ---------------------------------------------------------------------------

log "Recording active slot"

mkdir -p "$(dirname "$ACTIVE_SLOT_FILE")"

TEMP_SLOT_FILE="$(mktemp "$(dirname "$ACTIVE_SLOT_FILE")/active-slot.tmp.XXXXXX")"
printf '%s\n' "$TARGET_SLOT" > "$TEMP_SLOT_FILE"
mv "$TEMP_SLOT_FILE" "$ACTIVE_SLOT_FILE"

rm -f "$BACKUP_CONFIG"

# ---------------------------------------------------------------------------
# Stop previous application slot
# ---------------------------------------------------------------------------

if [[ -n "$OLD_SLOT" ]]; then
    log "Stopping previous application slot: $OLD_SLOT"

    compose --profile "$OLD_SLOT" stop \
        "frontend-$OLD_SLOT" \
        "backend-$OLD_SLOT" || true
fi

WORKERS_SWITCHED=0

# ---------------------------------------------------------------------------
# Deployment complete
# ---------------------------------------------------------------------------

log "Deployment completed successfully"

echo
echo "Release:       $TAG"
echo "Active slot:   $TARGET_SLOT"
echo "Previous slot: ${OLD_SLOT:-none}"
echo
echo "Shared infrastructure was left running."