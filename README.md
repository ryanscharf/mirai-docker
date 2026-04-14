# mirai-docker

A minimal Docker image for the [`mirai`](https://shikokuchuo.net/mirai/) R package — a lightweight, low-latency async evaluation framework built on [NNG (Nanomsg Next Generation)](https://nng.nanomsg.org/).

---

## Overview

`mirai` ("future" in Japanese, 未来) provides a clean interface for asynchronous and parallel R evaluation. Unlike heavier frameworks such as `future` or `parallel`, `mirai` is designed around a minimal footprint and high throughput, using NNG as its transport layer rather than forking or socket abstractions built on POSIX primitives.

This image packages `mirai` and its dependency `nanonext` into a `rocker/r-ver` base — the leanest official R Docker image — using a two-stage build to exclude compile-time tooling (cmake, headers) from the final layer.

---

## Image

```
ghcr.io/<owner>/mirai-docker:latest
```

Built automatically on every push to `main` via GitHub Actions. Tagged `latest` on the default branch and `sha-<hash>` for every build.

---

## Quick Start

### Pull and run an interactive R session

```bash
docker pull ghcr.io/<owner>/mirai-docker:latest
docker run --rm -it ghcr.io/<owner>/mirai-docker:latest
```

### Run a one-shot script

```bash
docker run --rm \
  -v "$(pwd)/script.R:/script.R" \
  ghcr.io/<owner>/mirai-docker:latest \
  Rscript /script.R
```

---

## Usage Patterns

### 1. Basic Async Evaluation

`mirai()` submits an expression for async evaluation and immediately returns a mirai object (analogous to a promise/future). The result is retrieved with `[]`.

```r
library(mirai)

m <- mirai(Sys.sleep(1), .timeout = 5000)
# ... do other work ...
m[]  # blocks until result is ready, or timeout
#> NULL
```

### 2. Local Daemons (Process Pool)

`daemons()` launches a persistent pool of background R processes. Subsequent `mirai()` calls are dispatched to the pool without spawning a new process each time.

```r
library(mirai)

daemons(4)  # 4 local worker processes

results <- lapply(1:20, \(x) mirai(x^2, x = x))
unlist(lapply(results, `[]`))
#>  [1]   1   4   9  16  25  36  49  64  81 100 121 144 169 196 225 256 289 324 361 400

daemons(0)  # shut down pool
```

### 3. Remote / Distributed Daemons

Daemons can run on any reachable host. The dispatcher listens on a URL; workers call `daemon()` to connect back.

**Dispatcher (coordinator container):**
```r
library(mirai)
daemons(url = "tcp://0.0.0.0:5555")
```

**Worker containers:**
```r
library(mirai)
daemon("tcp://<dispatcher-host>:5555")
```

With Docker Compose this is straightforward — see the example below.

### 4. Integration with Promises / Shiny

`mirai` ships a `.promise` method, enabling direct use with the `promises` package and `shiny`:

```r
library(mirai)
library(promises)

daemons(2)

mirai(expensive_computation(x), x = input$value) %...>%
  { output$result <- renderText(.) }
```

### 5. Integration with `crew`

[`crew`](https://wlandau.github.io/crew/) uses `mirai` daemons as its worker backend and is the recommended interface for `targets`-based pipelines:

```r
library(crew)

controller <- crew_controller_local(workers = 4)
controller$start()
controller$push(name = "job1", command = sqrt(16))
controller$wait()
controller$pop()$result
#> [[1]]
#> [1] 4
```

---

## Docker Compose — Distributed Daemons

```yaml
services:
  dispatcher:
    image: ghcr.io/<owner>/mirai-docker:latest
    command: >
      Rscript -e "
        library(mirai);
        daemons(url = 'tcp://0.0.0.0:5555');
        Sys.sleep(Inf)
      "
    ports:
      - "5555:5555"

  worker:
    image: ghcr.io/<owner>/mirai-docker:latest
    command: >
      Rscript -e "
        library(mirai);
        daemon('tcp://dispatcher:5555')
      "
    depends_on:
      - dispatcher
    deploy:
      replicas: 4
```

```bash
docker compose up --scale worker=4
```

---

## Image Details

| Property | Value |
|---|---|
| Base image | `rocker/r-ver:4.4.2` |
| Build strategy | Two-stage (builder + runtime) |
| R packages | `mirai`, `nanonext` |
| Runtime system deps | `libssl3` |
| Build-only deps | `cmake`, `libssl-dev` (excluded from final image) |
| Default entrypoint | `R` (interactive) |

### Why two-stage?

`nanonext` bundles NNG and compiles it from source at install time, requiring `cmake` and C build tooling. These are stripped in the second stage — only the compiled `.so` files and R package sources land in the final image, keeping it lean.

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
