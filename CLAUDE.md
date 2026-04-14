# CLAUDE.md — mirai-docker

Context file for LLM assistants working in this repository.

---

## What this repo is

A minimal Docker image that packages the [`mirai`](https://shikokuchuo.net/mirai/) R package for async/parallel R evaluation. The image is built on `rocker/r-ver` (bare R, no RStudio, no tidyverse) using a two-stage Docker build to keep the final image small.

---

## Repository structure

```
.
├── Dockerfile                        # Two-stage build: builder + runtime
├── .dockerignore
├── .github/
│   └── workflows/
│       └── docker-build.yml          # Builds and pushes to ghcr.io on push to main
├── README.md                         # Whitepaper-style usage guide
└── CLAUDE.md                         # This file
```

---

## Key design decisions

### Base image: `rocker/r-ver`
Chosen over `r-base` (Docker Hub) and other rocker variants (`rocker/rstudio`, `rocker/tidyverse`) because it is the smallest official R image with a reproducible R version pin and no GUI tooling.

### Two-stage build
`nanonext` (mirai's NNG transport layer) compiles NNG from source at install time and requires `cmake`. The builder stage installs cmake and compiles the packages; the runtime stage copies only the compiled R library, excluding cmake and C headers. This meaningfully reduces final image size.

### Runtime dep: `libssl3`
`nanonext` links against OpenSSL for TLS support. Only the shared library (`libssl3`) is needed at runtime — `libssl-dev` (headers + static lib) is build-only.

### GitHub Actions: GHCR push
The workflow pushes to `ghcr.io` using `GITHUB_TOKEN` — no secrets to configure. It only triggers when `Dockerfile` or the workflow file itself changes, and uses `type=gha` layer caching to skip recompiling NNG on repeat builds.

---

## mirai package overview

`mirai` provides async evaluation of R expressions via `mirai()`, returning a mirai object whose result is retrieved with `[]`. Workers are managed via `daemons()`.

Key functions:
- `mirai(expr, ...)` — submit async expression, returns mirai object
- `m[]` — collect result (blocks until ready or timeout)
- `daemons(n)` — launch n local worker processes (process pool)
- `daemons(url = "tcp://...")` — listen for remote workers
- `daemon(url)` — connect a worker to a dispatcher
- `daemons(0)` — shut down all daemons
- `unresolved(m)` — non-blocking check if result is ready

Transport is NNG (via `nanonext`). No forking — works on Windows.

Integrates with:
- `promises` — `.promise` method for Shiny async
- `crew` — higher-level worker controller, used by `targets`
- `parallel`/`foreach` — via crew adapters

---

## Common tasks

### Update R version
Change the `FROM rocker/r-ver:<version>` tag in `Dockerfile` (both stages must match).

### Add R packages
Add to the `RUN Rscript -e "install.packages(...)"` line in the builder stage. No changes needed in the runtime stage — the full `/usr/local/lib/R/library` is copied.

### Add system libraries
- If needed only at build time: add to the builder stage `apt-get install` block.
- If needed at runtime: add to the runtime stage `apt-get install` block.

### Test the image locally
```bash
docker build -t mirai-r .
docker run --rm -it mirai-r
# Inside R:
library(mirai)
daemons(2)
m <- mirai(1 + 1)
m[]
daemons(0)
```

### Trigger a manual CI build
Use `workflow_dispatch` from the GitHub Actions UI, or push a whitespace change to `Dockerfile`.

---

## What to avoid

- Do not use `rocker/rstudio` or `rocker/tidyverse` as the base — they add hundreds of MB of tooling that mirai does not need.
- Do not install packages in the runtime stage — compilation will fail without cmake/build tools. Always install in the builder stage.
- Do not pin `libssl3` to a specific version — let apt resolve the correct version for the Ubuntu release used by the rocker base.
- Do not add `daemons()` calls to the image entrypoint — daemon topology is user-defined at runtime.
