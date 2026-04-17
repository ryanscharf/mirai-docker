FROM rocker/r-ver:4.4.2

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        docker.io \
        libssl-dev \
        libcurl4-openssl-dev \
        libsodium-dev \
    && Rscript -e "install.packages('plumber', repos = 'https://cloud.r-project.org')" \
    && rm -rf /var/lib/apt/lists/*

COPY plumber.R /api/plumber.R

EXPOSE 8080

CMD ["Rscript", "-e", \
     "plumber::plumb('/api/plumber.R')$run(host='0.0.0.0', port=as.integer(Sys.getenv('MIRAI_API_PORT', '8080')))"]
