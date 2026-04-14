# ---- build stage ----
FROM rocker/r-ver:4.4.2 AS builder

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        cmake \
        libssl-dev \
    && rm -rf /var/lib/apt/lists/*

RUN Rscript -e "install.packages('mirai', repos = 'https://cloud.r-project.org')"

# ---- runtime stage ----
FROM rocker/r-ver:4.4.2

# nanonext (mirai's transport layer) needs libssl at runtime for TLS
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libssl3 \
    && rm -rf /var/lib/apt/lists/*

# Copy compiled R packages from builder
COPY --from=builder /usr/local/lib/R/library /usr/local/lib/R/library

CMD ["R"]
