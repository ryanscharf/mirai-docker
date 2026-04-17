FROM rocker/r-ver:4.4.2

# curl — used to call the Docker Engine HTTP API via the mounted socket.
# No Docker CLI needed: bypasses the CLI entirely to avoid syscall restrictions
# on TrueNAS SCALE's kernel environment.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        curl \
    && rm -rf /var/lib/apt/lists/*

# Install pak from P3M noble binaries, then use pak to install plumber
RUN Rscript -e "install.packages('pak', repos = 'https://packagemanager.posit.co/cran/__linux__/noble/latest')"
RUN Rscript -e "pak::pkg_install('plumber')"

COPY plumber.R /api/plumber.R

EXPOSE 8080

CMD ["Rscript", "-e", "plumber::plumb('/api/plumber.R')$run(host='0.0.0.0', port=as.integer(Sys.getenv('MIRAI_API_PORT', '8080')))"]
