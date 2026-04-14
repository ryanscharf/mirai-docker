FROM rocker/r-ver:4.4.2

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        cmake \
        libssl-dev \
    && Rscript -e "install.packages('mirai', repos = 'https://cloud.r-project.org')" \
    && apt-get purge -y --auto-remove cmake \
    && rm -rf /var/lib/apt/lists/*

CMD ["R"]
