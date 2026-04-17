# mirai-docker

A minimal Docker image for the [`mirai`](https://shikokuchuo.net/mirai/) R package — a lightweight, low-latency async evaluation framework built on [NNG (Nanomsg Next Generation)](https://nng.nanomsg.org/).

---

## Overview

`mirai` ("future" in Japanese, 未来) provides a clean interface for asynchronous and parallel R evaluation. Unlike heavier frameworks such as `future` or `parallel`, `mirai` is designed around a minimal footprint and high throughput, using NNG as its transport layer rather than forking or socket abstractions built on POSIX primitives.

This image packages `mirai` and its dependency `nanonext` into a `rocker/r-ver` base — the leanest official R Docker image.

---

## How mirai networking works

**Your R session is the dispatcher.** When you call `daemons(url = "tcp://0.0.0.0:port")`, your R session begins listening for worker connections on that port. Workers dial in and wait for tasks. There is no separate dispatcher process.

```
Your R session (Positron / RStudio / script)
  └─ daemons(url = "tcp://0.0.0.0:5555")   ← listens on port 5555
        ▲           ▲           ▲
    worker-1    worker-2    worker-3        ← Docker containers on any machine
```

Workers can run on the same machine or on any machine that can reach your R session over the network.

---

## Images

| Image | Description |
|---|---|
| `ghcr.io/ryanscharf/mirai-docker:latest` | Worker image — runs `daemon()` and connects to a dispatcher |
| `ghcr.io/ryanscharf/mirai-docker-api:latest` | API image — Plumber API to manage worker containers on demand |

Both are built automatically on every push to `main` via GitHub Actions.

---

## Worker Management API

A Plumber API runs as a container on your worker host (e.g. TrueNAS). It exposes endpoints to start, stop, and list worker containers on demand from any R session — no SSH or manual Docker commands needed.

The API talks to the Docker daemon directly via its HTTP API over the mounted Unix socket (`/var/run/docker.sock`), using the `curl` R package. Every request is logged to stdout with a UTC timestamp and the caller's IP.

### Deploy the API (on TrueNAS)

```bash
docker compose -f docker-compose_example.yml up -d mirai-api
```

### Use from R (Positron or any IDE)

```r
library(mirai)
source("R/workers.R")   # loads start_workers(), stop_workers(), list_workers()

Sys.setenv(MIRAI_API_HOST = "192.168.2.66", MIRAI_API_PORT = "8089")

daemons(url = "tcp://0.0.0.0:5555")     # your session listens for workers
start_workers("192.168.2.4", n = 4)     # API starts 4 workers pointing at you
# Started 4 worker(s) -> 192.168.2.4:5555

status()                                 # confirm connections

# ... do work ...

daemons(0)                               # signals workers to exit (auto-removed)
stop_workers("192.168.2.4")             # cleanup any that didn't exit cleanly
# Stopped 4 worker(s) for 192.168.2.4:5555
```

Multiple R sessions can each request their own workers simultaneously — they're isolated by container name (`mirai-worker-<ip>-<port>-<n>`).

### API endpoints

| Method | Path | Body | Description |
|---|---|---|---|
| `POST` | `/workers/start` | `{dispatcher, n, port}` | Pull image if needed, start n workers pointing at dispatcher |
| `POST` | `/workers/stop` | `{dispatcher, port}` | Stop all workers for a dispatcher |
| `GET` | `/workers` | — | List all running worker containers |
| `GET` | `/debug` | — | Test Docker socket connectivity and attempt a create |

All responses include `received_at` (UTC timestamp) and `from` (caller IP).

### API container logs

```
[2026-04-17T12:22:18Z] POST /workers/start from 192.168.2.4
  dispatcher=192.168.2.4  n=4  port=5555  image=ghcr.io/ryanscharf/mirai-docker:latest
  started mirai-worker-192-168-2-4-5555-1
  started mirai-worker-192-168-2-4-5555-2
  ...
[2026-04-17T12:22:23Z] POST /workers/stop from 192.168.2.4
  stopped 413f73ce4c6a...
```

---

## Quick Start

### 1. Start your R session as the dispatcher

```r
library(mirai)
source("R/workers.R")

Sys.setenv(MIRAI_API_HOST = "192.168.2.66", MIRAI_API_PORT = "8089")
daemons(url = "tcp://0.0.0.0:5555")
```

Your session is now listening for workers on port 5555.

### 2. Start workers via the API

```r
start_workers("192.168.2.4", n = 4)
# Started 4 worker(s) -> 192.168.2.4:5555
```

`"192.168.2.4"` is the LAN IP of the machine running your R session (the dispatcher). Workers connect back to this address.

### 3. Check status

```r
status()
#> $connections
#> [1] 4
```

### 4. Submit work

```r
m <- mirai(Sys.getenv("HOSTNAME"))
m[]  # returns the worker container's hostname

jobs <- lapply(1:20, \(x) mirai(x^2, x = x))
unlist(lapply(jobs, `[]`))
```

### 5. Clean up

```r
daemons(0)               # dispatcher closes — workers exit cleanly (auto-removed via --rm)
stop_workers("192.168.2.4")   # belt-and-suspenders for any that didn't exit
```

---

## Testing

`test_workers.R` runs a full integration test against a live worker pool. Edit the config block at the top to match your environment, then:

```r
source("test_workers.R")
```

Tests:
1. **Smoke test** — each worker reports its hostname
2. **Parallel computation** — 20 tasks (`x^2`) distributed across workers
3. **Parallelism timing** — 4 × 1s sleeps should complete in ~1s total
4. **Error handling** — workers survive and recover from a task that calls `stop()`

---

## Configuration

Variables are set in `.env` (copy from `.env.example`):

| Variable | Default | Description |
|---|---|---|
| `MIRAI_PORT` | `5555` | Port the dispatcher listens on and workers dial to |
| `MIRAI_WORKERS` | `4` | Reserved for local testing reference |
| `MIRAI_API_PORT` | `8080` | Port the worker management API listens on |
| `MIRAI_HOST` | *(required at runtime)* | IP of the machine running the R session |

`MIRAI_HOST` is intentionally absent from `.env` — it is machine-specific and must be passed at runtime. Workers fail immediately with a clear error if it is not set.

---

## Usage Patterns

### Basic async evaluation

```r
library(mirai)
daemons(url = "tcp://0.0.0.0:5555")

m <- mirai(Sys.sleep(1))
# ... do other work ...
m[]
```

### Parallel computation

```r
jobs <- lapply(1:20, \(x) mirai(x^2, x = x))
unlist(lapply(jobs, `[]`))
```

### Integration with promises / Shiny

```r
library(promises)

mirai(expensive_computation(x), x = input$value) %...>%
  { output$result <- renderText(.) }
```

### Integration with `crew`

```r
library(crew)
controller <- crew_controller_local(workers = 4)
controller$start()
controller$push(name = "job1", command = sqrt(16))
controller$wait()
controller$pop()$result
```

---

## Image Details

### Worker image (`ghcr.io/ryanscharf/mirai-docker`)

| Property | Value |
|---|---|
| Base image | `rocker/r-ver:4.4.2` |
| Build strategy | Single stage, cmake purged post-install |
| R packages | `mirai`, `nanonext` |
| Entrypoint script | `worker.R` — connects to dispatcher, retries on failure, exits cleanly on close |

### API image (`ghcr.io/ryanscharf/mirai-docker-api`)

| Property | Value |
|---|---|
| Base image | `rocker/r-ver:4.4.2` |
| R packages | `plumber`, `curl`, `jsonlite` |
| Package installer | `pak` from Posit Package Manager (noble binaries — no compilation) |
| Docker access | Via Docker Engine HTTP API over mounted Unix socket — no Docker CLI |

### Why not two-stage?

`nanonext` compiles NNG from source and links against shared libraries present in the build environment. A two-stage copy of the R library directory leaves those runtime dependencies behind. Single stage with `apt purge cmake` after install is simpler and reliable.

---

## Building Locally

```bash
docker build -t mirai-r .
docker build -t mirai-api ./api
```

---

## References

- [mirai on CRAN](https://cran.r-project.org/package=mirai)
- [mirai documentation](https://shikokuchuo.net/mirai/)
- [nanonext](https://shikokuchuo.net/nanonext/) — NNG R bindings
- [NNG project](https://nng.nanomsg.org/)
- [rocker-project.org](https://rocker-project.org/)
- [crew package](https://wlandau.github.io/crew/)
