# CLAUDE.md — mirai-docker

Context file for LLM assistants working in this repository.

---

## What this repo is

A minimal Docker image that packages the [`mirai`](https://shikokuchuo.net/mirai/) R package for async/parallel R evaluation. The image is built on `rocker/r-ver` (bare R, no RStudio, no tidyverse).

---

## Repository structure

```
.
├── Dockerfile                        # Single-stage build: installs mirai, purges cmake
├── worker.R                          # Worker entrypoint: connects to dispatcher, retries, exits cleanly
├── .dockerignore
├── .env                              # MIRAI_PORT, MIRAI_WORKERS, MIRAI_API_PORT (not committed)
├── .env.example                      # Reference copy of .env
├── docker-compose_example.yml        # mirai-api service only (workers are started on demand via API)
├── test_workers.R                    # Live integration test for a running worker pool
├── api/
│   ├── Dockerfile                    # API image: rocker/r-ver + plumber + curl R package
│   └── plumber.R                     # Plumber API: /workers/start, /workers/stop, /workers, /debug
├── R/
│   └── workers.R                     # R helpers: start_workers(), stop_workers(), list_workers()
├── .github/
│   └── workflows/
│       └── docker-build.yml          # Builds and pushes both images to ghcr.io on push to main
├── README.md
└── CLAUDE.md                         # This file
```

---

## Key design decisions

### Your R session is the dispatcher

mirai does not have a standalone dispatcher process. `daemons(url = "tcp://0.0.0.0:port")` makes the **calling R session** listen for worker connections on that port. Workers dial in using `daemon("tcp://host:port")`.

Do not create a separate dispatcher container. It will not work — mirai's dispatcher is tightly coupled to the R session that created it, and there is no public API to run it as an independent service.

### MIRAI_HOST is a runtime variable, not a config file setting

`MIRAI_HOST` is the IP of the machine running the R session (the dispatcher). This changes depending on which machine the user is working from, so it must be passed at runtime. It is intentionally absent from `.env`. Workers fail immediately with a clear error if it is not set.

### Single-stage Dockerfile (worker image)

A two-stage build was attempted (builder copies R library to runtime stage) but caused `nanonext` shared libraries to be missing at runtime. Single stage with `apt purge cmake` post-install is the correct approach.

### worker.R is baked into the worker image

The worker daemon logic lives in `worker.R` and is `COPY`'d into the image at `/worker.R`. The API starts workers by running `Rscript /worker.R` — no inline `-e` code is passed through the shell. This avoids shell escaping issues with R code containing `(`, `{`, and other shell-special characters.

### API uses Docker Engine HTTP API, not the Docker CLI

The API container manages workers by calling the Docker daemon's REST API directly over the mounted Unix socket (`/var/run/docker.sock`) using the `curl` R package (`new_handle(unix_socket_path=...) + curl_fetch_memory()`).

Two approaches were tried and discarded:
- `system2("docker", ...)` — the Docker CLI (`docker.io`, `docker-ce-cli`) triggers ENOSYS ("Function not implemented") on TrueNAS SCALE's kernel when run inside a container.
- `system2("curl", ...)` — the system `curl` binary received argument splitting: `-H "Content-Type: application/json"` was split at the space, sending an empty Content-Type and causing a 400 error.

The `curl` R package wraps libcurl directly — no subprocess, no shell, no argument escaping. It supports Unix domain sockets via `CURLOPT_UNIX_SOCKET_PATH`.

### API pulls images before creating containers

The Docker Engine API's `POST /containers/create` does not auto-pull images (unlike `docker run`). The API calls `POST /images/create?fromImage=<image>` before the worker loop to ensure the image is present locally. This is a no-op if the image is already cached.

### Base image: `rocker/r-ver`

Chosen over `r-base` (Docker Hub) and other rocker variants (`rocker/rstudio`, `rocker/tidyverse`) because it is the smallest official R image with a reproducible R version pin and no GUI tooling.

### Package installation in API image

The API image uses `pak` from Posit Package Manager (P3M) noble binaries. `rocker/r-ver:4.4.2` is Ubuntu 24.04 (Noble) — using the jammy P3M URL causes compile failures due to missing `libicu70`. Install `pak` from P3M first, then use `pak::pkg_install()` for other packages.

---

## mirai package overview

Key functions:
- `daemons(url = "tcp://0.0.0.0:port")` — make this R session listen for worker connections
- `mirai(expr, ...)` — submit async expression, returns mirai object
- `m[]` — collect result (blocks until ready)
- `daemon(url)` — connect this R process to a dispatcher as a worker (blocks until dispatcher closes)
- `daemons(0)` — shut down all daemons (workers exit with code 0)
- `status()` — show connected worker count and task queue state
- `unresolved(m)` — non-blocking check if result is ready
- `is_mirai_error(x)` — check if a task result is an error (use this, not `inherits(x, "mirai_error")`)

Transport is NNG (via `nanonext`). No forking — works on Windows.

---

## Worker connection flow

```
User's R session (any machine)
  └─ daemons(url = "tcp://0.0.0.0:5555")     ← listens
        ▲            ▲            ▲
   worker-1      worker-2     worker-3        ← Docker containers on TrueNAS
   daemon("tcp://192.168.2.4:5555")           ← workers dial out to dispatcher IP
```

Workers dial the user's machine IP. The user's machine must have port 5555 reachable from wherever the workers run.

---

## Worker management API

A Plumber API (`api/plumber.R`) runs as a container on the worker host with the Docker socket mounted. It starts/stops worker containers on demand in response to HTTP calls from R sessions.

- Workers are started via the Docker Engine HTTP API with `AutoRemove: true` — containers are automatically removed when they exit.
- Workers exit cleanly (code 0) when the dispatcher calls `daemons(0)`. `restart: on-failure` does not trigger on clean exits, so workers don't respawn after the session ends.
- `R/workers.R` provides `start_workers()`, `stop_workers()`, `list_workers()` — source it in any R session.
- `MIRAI_API_HOST` and `MIRAI_API_PORT` env vars control where `R/workers.R` points. Defaults: `192.168.2.66:8080`.
- All API responses include `received_at` (UTC ISO timestamp) and `from` (caller IP).
- Every request is logged to stdout: `[timestamp] METHOD /path from IP`.

### Endpoints

| Method | Path | Description |
|---|---|---|
| `POST` | `/workers/start` | Pull image if needed, start n workers |
| `POST` | `/workers/stop` | Stop all workers for a dispatcher |
| `GET` | `/workers` | List running worker containers |
| `GET` | `/debug` | Test Docker socket; attempt a container create and return raw response |

---

## Common tasks

### Update R version
Change the `FROM rocker/r-ver:<version>` tag in `Dockerfile`. Update the P3M URL codename in `api/Dockerfile` if the Ubuntu base version changes (4.4.2 → Noble/24.04).

### Add R packages to the worker image
Add to the `RUN Rscript -e "install.packages(...)"` line in `Dockerfile`. Packages install at build time with cmake available.

### Add R packages to the API image
Add to `pak::pkg_install(c('plumber', 'curl', ...))` in `api/Dockerfile`. pak handles system dependencies automatically.

### Test against a live worker pool

1. Edit the config block at the top of `test_workers.R`
2. In your R session: `source("test_workers.R")` — it starts the dispatcher, requests workers via API, and runs all tests

### Trigger a manual CI build
Use `workflow_dispatch` from the GitHub Actions UI, or push any change to `Dockerfile` or `api/Dockerfile`.

---

## What to avoid

- Do not add a dispatcher container. mirai's dispatcher IS the calling R session — a separate container cannot serve this role.
- Do not put `MIRAI_HOST` in `.env`. It is machine-specific and must be set at runtime.
- Do not use `daemons(0)` in any container entrypoint or startup command — it is the shutdown signal and will immediately terminate any connected workers.
- Do not use `rocker/rstudio` or `rocker/tidyverse` as the base — unnecessary bloat.
- Do not install packages in a separate runtime stage — build tooling (cmake) is required and not present there.
- Do not pin `libssl-dev` to a specific version — let apt resolve it.
- Do not use the Docker CLI (`docker.io` or `docker-ce-cli`) inside the API container on TrueNAS SCALE — it triggers ENOSYS. Use the Docker Engine HTTP API via the `curl` R package instead.
- Do not pass inline R code via `system2("docker", c(..., "Rscript", "-e", code))` — shell characters in R code cause syntax errors. Put the code in a `.R` file baked into the image.
- Do not use `system2("curl", c("-H", "Content-Type: application/json", ...))` — the space in the header value causes argument splitting. Use the `curl` R package instead.
- Do not use `inherits(result, "mirai_error")` to check task errors — use `is_mirai_error(result)`.
