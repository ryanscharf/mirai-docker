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

## Image

```
ghcr.io/ryanscharf/mirai-docker:latest
```

Built automatically on every push to `main` via GitHub Actions.

---

## Worker Management API

A Plumber API runs as a container on your worker host (e.g. TrueNAS). It exposes endpoints to start, stop, and list worker containers on demand from any R session — no SSH or manual Docker commands needed.

### Deploy the API (on TrueNAS)

```bash
docker compose -f docker-compose_example.yml up -d mirai-api
```

### Use from R (Positron or any IDE)

```r
library(mirai)
source("R/workers.R")   # loads start_workers(), stop_workers(), list_workers()

# Set where the API lives (or set MIRAI_API_HOST env var)
Sys.setenv(MIRAI_API_HOST = "192.168.2.66")

daemons(url = "tcp://0.0.0.0:5555")     # your session listens for workers
start_workers("192.168.2.4", n = 6)     # API starts 6 workers pointing at you
# > Started 6 worker(s) -> 192.168.2.4:5555

status()                                 # confirm connections

# ... do work ...

daemons(0)                               # signals workers to exit (auto-removed)
stop_workers("192.168.2.4")             # cleanup any that didn't exit cleanly
```

Multiple R sessions can each request their own workers simultaneously — they're isolated by container name.

### API endpoints

| Method | Path | Body | Description |
|---|---|---|---|
| `POST` | `/workers/start` | `{dispatcher, n, port}` | Start n workers pointing at dispatcher |
| `POST` | `/workers/stop` | `{dispatcher, port}` | Stop and remove workers for a dispatcher |
| `GET` | `/workers` | — | List all running worker containers |

---

## Quick Start

### 1. Start your R session as the dispatcher

In Positron, RStudio, or any R session on your machine:

```r
library(mirai)
daemons(url = "tcp://0.0.0.0:5555")
```

Your session is now listening for workers on port 5555.

### 2. Start workers

**Locally (same machine):**
```bash
MIRAI_HOST=127.0.0.1 docker compose -f docker-compose_example.yml up worker
```

**Remote machine (e.g. a NAS or server at 192.168.x.x):**
```bash
# On the remote machine — point workers at your machine's LAN IP
MIRAI_HOST=192.168.2.4 docker compose -f docker-compose_example.yml up worker
```

`MIRAI_HOST` is always the IP of the machine running your R session. Workers connect to it, not the other way around.

### 3. Check status

Back in your R session:

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

---

## Configuration

Variables are set in `.env` (copy from `.env.example`):

| Variable | Default | Description |
|---|---|---|
| `MIRAI_PORT` | `5555` | Port your R session listens on and workers dial to |
| `MIRAI_WORKERS` | `4` | Number of worker replicas (local testing only) |
| `MIRAI_API_PORT` | `8080` | Port the worker management API listens on |
| `MIRAI_HOST` | *(required at runtime)* | IP of the machine running the R session |

`MIRAI_HOST` is intentionally not in `.env` — it depends on which machine is running the R session and changes per deployment.

---

## docker-compose_example.yml

The compose file only contains the `worker` service. There is no dispatcher service — your R session fills that role.

```yaml
# Start your R session first:
#   daemons(url = "tcp://0.0.0.0:5555")
# Then start workers pointing at your machine:
#   MIRAI_HOST=192.168.2.4 docker compose -f docker-compose_example.yml up worker
```

Scale workers up or down:
```bash
MIRAI_HOST=192.168.2.4 docker compose -f docker-compose_example.yml up worker --scale worker=8
```

---

## Testing

`test_workers.R` runs four tests against a live worker pool:

```r
# Edit the config block at the top first:
dispatcher_host <- "0.0.0.0"   # listen on all interfaces
dispatcher_port <- 5555
n_timing_workers <- 4
```

Run from your R session:
```r
source("test_workers.R")
```

The script will:
1. Call `daemons()` to start listening
2. Wait up to 60s for workers to connect
3. Run smoke tests: hostnames, parallel computation, timing, error recovery

Start workers on your remote machine before or after running the script — the script waits for them.

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

| Property | Value |
|---|---|
| Base image | `rocker/r-ver:4.4.2` |
| Build strategy | Single stage, cmake purged post-install |
| R packages | `mirai`, `nanonext` |
| Runtime system deps | `libssl-dev` |
| Default entrypoint | `R` (interactive) |

### Why not two-stage?

`nanonext` compiles NNG from source and links against shared libraries present in the build environment. A two-stage copy of the R library directory leaves those runtime dependencies behind. Single stage with `apt purge cmake` after install is simpler and reliable.

---

## Building Locally

```bash
docker build -t mirai-r .
docker run --rm -it mirai-r
```

---

## References

- [mirai on CRAN](https://cran.r-project.org/package=mirai)
- [mirai documentation](https://shikokuchuo.net/mirai/)
- [nanonext](https://shikokuchuo.net/nanonext/) — NNG R bindings
- [NNG project](https://nng.nanomsg.org/)
- [rocker-project.org](https://rocker-project.org/)
- [crew package](https://wlandau.github.io/crew/)
