FROM rocker/r-ver:4.4.2

# Docker CE CLI — needed to manage worker containers via the mounted socket
# Use official Docker repo instead of ubuntu's docker.io package, which triggers
# "Function not implemented" (ENOSYS) on TrueNAS SCALE's kernel environment.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

# Install pak from P3M noble binaries, then use pak to install plumber
RUN Rscript -e "install.packages('pak', repos = 'https://packagemanager.posit.co/cran/__linux__/noble/latest')"
RUN Rscript -e "pak::pkg_install('plumber')"

COPY plumber.R /api/plumber.R

EXPOSE 8080

CMD ["Rscript", "-e", "plumber::plumb('/api/plumber.R')$run(host='0.0.0.0', port=as.integer(Sys.getenv('MIRAI_API_PORT', '8080')))"]
