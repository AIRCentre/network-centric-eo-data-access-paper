# Option B — Cross-Site MinIO Replication Setup

This guide covers running a local MinIO instance and configuring
one-way bucket replication to the AIR Data Centre in the Azores.

## Overview

The test measures replication throughput, latency, and consistency
between your MinIO instance and the AIR Data Centre's 8-node
MinIO cluster. Objects written at your site replicate to the
Azores; the benchmark measures how fast and how reliably.

## Docker Compose Setup (Recommended)

Requires Docker and Docker Compose. A `docker-compose.yml` at the
repo root provides a local MinIO server and a devshell container
with `mc` pre-configured.

### Prerequisites

- Docker and Docker Compose installed.
- `AIRDC_ACCESS_KEY` and `AIRDC_SECRET_KEY` for the AIR Data Centre,
  provided by lead João Pinelo upon invitation.

### Quick start

```bash
# 1. Set up your .env with HOST_UID and HOST_GID from your shell.
./setup_env.sh

# 2. Edit .env to set SITE and AIRDC_ACCESS_KEY / AIRDC_SECRET_KEY.
${EDITOR:-vi} .env

# 3. Run the benchmark in one shot.
docker compose run --rm --user "$(id -u):$(id -g)" devshell ./scripts/run_replication.sh
```

Results land in `results/<your-site>/` on the host.

On startup the entrypoint automatically:
1. Configures `mc` aliases (`local` and `airdc`).
2. Creates the replication test bucket with versioning enabled.
3. Adds a one-way replication rule to the AIR Data Centre
   (using `mc replicate add --remote-bucket` with credentials
   embedded in the URL — no ARN needed).

The explicit `--user` flag is a belt-and-braces fix: some
podman-compose versions silently drop the `user:` directive from
`docker-compose.yml`, so passing the UID/GID on the command line
guarantees the container runs as your shell user. Docker users
won't strictly need it (the compose file's `user:` directive
already does the right thing) but it doesn't hurt either.

### Alternative: interactive devshell

For ad-hoc debugging or for verifying replication state
interactively, start the containers in the background and exec a
shell:

```bash
# Start MinIO and the devshell.
docker compose up -d

# Enter the devshell with explicit user.
docker compose exec --user "$(id -u):$(id -g)" devshell bash

# Inside the devshell, verify and run.
mc replicate status local/atlantic-cloud-replication-test
./scripts/run_replication.sh
```

### Restarting

After changing `.env`, recreate the containers to pick up changes:

```bash
docker compose down && docker compose up -d
```

`docker compose restart` does **not** re-read `env_file`.

### Stopping

```bash
docker compose down        # stop containers, keep data volume
docker compose down -v     # stop and remove MinIO data volume
```

### Notes

- The devshell is built from a local `Dockerfile` based on
  `debian:bookworm-slim` with `mc` and `curl` installed. Rebuild
  with `docker compose build devshell` after changing the Dockerfile.
- The repo root is bind-mounted at `/workspace` inside the
  devshell. Scripts resolve paths relative to this mount.
- The MinIO console is available at `http://localhost:9001`
  (login with `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD`).

## Rootless Podman compatibility

Rootless Podman (with or without the Docker CLI emulation, common
on RHEL / Rocky / AlmaLinux HPC hosts) has the same UID-alignment
need as Docker, but the failure mode is more confusing: the
bind-mounted `results/` directory looks present and readable from
inside the container (`ls` succeeds with sensible permissions),
but writes fail with `Permission denied` because the container's
namespace UID doesn't match the host UID that owns the directory.

Some podman-compose versions silently drop the `user:` directive
from `docker-compose.yml`, which means running `./setup_env.sh`
alone is not enough — the values are written to `.env` and then
ignored at runtime. The reliable fix is to pass `--user` on the
command line, as shown in the Quick start above:

```bash
docker compose run --rm --user "$(id -u):$(id -g)" devshell ./scripts/run_replication.sh
```

This works under both Docker and Podman regardless of how the
compose file is interpreted. No chown, overlay setup, or `:U`
volume flag is needed.

If your terminal reports `Executing external compose provider
"/usr/bin/podman-compose"`, you are in the Podman case.

## Manual Setup

If you prefer not to use Docker, follow the steps below.

### Prerequisites

- A Linux server (Rocky, Ubuntu, or Debian) with:
  - At least 1 available disk or partition for MinIO data.
  - Network access to the internet (outbound HTTPS on port 443).
  - Root or sudo access.
- The `mc` (MinIO Client) command-line tool.

### Step 1: Install MinIO

A single-node, single-drive installation is sufficient.
Full documentation:
<https://min.io/docs/minio/linux/operations/install-deploy-manage/deploy-minio-single-node-single-drive.html>

```bash
wget https://dl.min.io/server/minio/release/linux-amd64/minio
chmod +x minio
sudo mv minio /usr/local/bin/

sudo mkdir -p /data/minio

MINIO_ROOT_USER=minioadmin \
MINIO_ROOT_PASSWORD=minioadmin \
minio server /data/minio --console-address ":9001"
```

### Step 2: Install MinIO Client (mc)

```bash
wget https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x mc
sudo mv mc /usr/local/bin/

mc alias set local http://localhost:9000 minioadmin minioadmin
mc alias set airdc https://s3.ac-az1.aircentre.org ACCESS_KEY SECRET_KEY
```

Replace `ACCESS_KEY` and `SECRET_KEY` with the credentials
provided by lead João Pinelo upon invitation. **Do not commit credentials to Git.**

### Step 3: Create bucket and configure replication

```bash
mc mb local/atlantic-cloud-replication-test
mc version enable local/atlantic-cloud-replication-test

# Add replication rule (credentials embedded in URL, no ARN needed).
mc replicate add local/atlantic-cloud-replication-test \
    --remote-bucket 'https://ACCESS_KEY:SECRET_KEY@s3.ac-az1.aircentre.org/atlantic-cloud-replication-test' \
    --replicate "delete,delete-marker,existing-objects"
```

### Step 4: Verify replication

```bash
echo "replication test $(date)" | mc pipe local/atlantic-cloud-replication-test/test.txt
mc replicate status local/atlantic-cloud-replication-test
mc cat airdc/atlantic-cloud-replication-test/test.txt
```

### Step 5: Run the benchmark

```bash
./scripts/run_replication.sh
```

## Troubleshooting

- **Replication not starting:** check `mc replicate status` for
  errors. Common issues: versioning not enabled, network
  connectivity (outbound to `s3.ac-az1.aircentre.org:443`).
- **Slow replication:** expected for the first sync. Subsequent
  objects replicate incrementally.
- **Authentication errors:** verify credentials with `mc ls airdc/`.
- **`docker compose restart` not picking up `.env` changes:**
  use `docker compose down && docker compose up -d` instead.

## Contact

Contact lead João Pinelo for help with the MinIO setup.
