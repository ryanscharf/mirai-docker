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
├── .dockerignore
├── .env                              # MIRAI_PORT and MIRAI_WORKERS (not committed)
├── .env.example                      # Reference copy of .env
├── docker-compose_example.yml        # Worker service only — no dispatcher
├── test_workers.R                    # Live integration test for a running worker pool
├── .github/
│   └── workflows/
│       └── docker-build.yml          # Builds and pushes to ghcr.io on push to main
├── README.md
└── CLAUDE.md                         # This file
```

---

## Key design decisions

### Your R session is the dispatcher

mirai does not have a standalone dispatcher process. `daemons(url = "tcp://0.0.0.0:port")` makes the **calling R session** listen for worker connections on that port. Workers dial in using `daemon("tcp://host:port")`.

Do not create a separate dispatcher container. It will not work — mirai's dispatcher is tightly coupled to the R session that created it, and there is no public API to run it as an independent service.

### MIRAI_HOST is a runtime variable, not a config file setting

`MIRAI_HOST` is the IP of the machine running the R session (the dispatcher). This changes depending on which machine the user is working from, so it must be passed at runtime:

```bash
MIRAI_HOST=192.168.2.4 docker compose -f docker-compose_example.yml up worker
```

It is intentionally absent from `.env`. Workers fail immediately with a clear error if it is not set.

### Single-stage Dockerfile

A two-stage build was attempted (builder copies R library to runtime stage) but caused `nanonext` shared libraries to be missing at runtime. Single stage with `apt purge cmake` post-install is the correct approach.

### Base image: `rocker/r-ver`

Chosen over `r-base` (Docker Hub) and other rocker variants (`rocker/rstudio`, `rocker/tidyverse`) because it is the smallest official R image with a reproducible R version pin and no GUI tooling.

---

## mirai package overview

Key functions:
- `daemons(url = "tcp://0.0.0.0:port")` — make this R session listen for worker connections
- `mirai(expr, ...)` — submit async expression, returns mirai object
- `m[]` — collect result (blocks until ready)
- `daemon(url)` — connect this R process to a dispatcher as a worker (blocks forever)
- `daemons(0)` — shut down all daemons
- `status()` — show connected worker count and task queue state
- `unresolved(m)` — non-blocking check if result is ready

Transport is NNG (via `nanonext`). No forking — works on Windows.

---

## Worker connection flow

```
User's R session (any machine)
  └─ daemons(url = "tcp://0.0.0.0:5555")     ← listens
        ▲            ▲            ▲
   worker-1      worker-2     worker-3        ← Docker containers
   daemon("tcp://192.168.2.4:5555")           ← workers dial out
```

Workers dial the user's machine IP. The user's machine must have port 5555 reachable from wherever the workers run.

---

## Common tasks

### Update R version
Change the `FROM rocker/r-ver:<version>` tag in `Dockerfile`.

### Add R packages
Add to the `RUN Rscript -e "install.packages(...)"` line. They install at build time with full build tooling available.

### Add system libraries
- Build-time only: add to the `apt-get install` block before the Rscript line.
- Runtime: add to a second `apt-get install` block after the Rscript line (before purge).

### Test against a live worker pool

1. In your R session: `daemons(url = "tcp://0.0.0.0:5555")`
2. On worker machines: `MIRAI_HOST=<your-ip> docker compose -f docker-compose_example.yml up worker`
3. Run: `source("test_workers.R")`

### Trigger a manual CI build
Use `workflow_dispatch` from the GitHub Actions UI, or push any change to `Dockerfile`.

---

## What to avoid

- Do not add a dispatcher container. mirai's dispatcher IS the calling R session — a separate container cannot serve this role.
- Do not put `MIRAI_HOST` in `.env`. It is machine-specific and must be set at runtime.
- Do not use `daemons(0)` in any container entrypoint or startup command — it is the shutdown signal and will immediately terminate any connected workers.
- Do not use `rocker/rstudio` or `rocker/tidyverse` as the base — unnecessary bloat.
- Do not install packages in a separate runtime stage — build tooling (cmake) is required and not present there.
- Do not pin `libssl-dev` to a specific version — let apt resolve it.
