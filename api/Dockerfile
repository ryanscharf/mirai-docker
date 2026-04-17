FROM rocker/r-ver:4.4.2

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        docker.io \
        libssl-dev \
        libcurl4-openssl-dev \
        libsodium-dev \
        libxml2-dev \
    && rm -rf /var/lib/apt/lists/*

# Use Posit Package Manager for pre-compiled Linux binaries (no compilation needed)
RUN Rscript -e " \
        options(repos = c(CRAN = 'https://packagemanager.posit.co/cran/__linux__/jammy/latest')); \
        install.packages('plumber'); \
        stopifnot(requireNamespace('plumber', quietly = TRUE)) \
    "

COPY plumber.R /api/plumber.R

EXPOSE 8080

CMD ["Rscript", "-e", "plumber::plumb('/api/plumber.R')$run(host='0.0.0.0', port=as.integer(Sys.getenv('MIRAI_API_PORT', '8080')))"]
