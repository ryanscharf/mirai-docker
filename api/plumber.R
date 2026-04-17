library(plumber)
library(jsonlite)

SOCK <- "/var/run/docker.sock"

docker_get <- function(path) {
  out <- system2("curl", c("-s", "--unix-socket", SOCK,
                            paste0("http://localhost", path)),
                 stdout = TRUE, stderr = FALSE)
  if (length(out) == 0 || !nzchar(paste(out, collapse = ""))) return(list())
  tryCatch(fromJSON(paste(out, collapse = ""), simplifyVector = FALSE),
           error = function(e) list())
}

docker_post <- function(path, body = NULL) {
  args <- c("-s", "-i", "--unix-socket", SOCK, "-X", "POST")
  if (!is.null(body)) {
    args <- c(args,
              "-H", "Content-Type: application/json",
              "-d", toJSON(body, auto_unbox = TRUE))
  }
  args <- c(args, paste0("http://localhost", path))
  out  <- system2("curl", args, stdout = TRUE, stderr = FALSE)
  raw  <- paste(out, collapse = "\n")
  # Split HTTP headers from body on the blank line
  body_text <- sub("^.*?\r\n\r\n", "", raw)
  if (!nzchar(trimws(body_text))) return(list())
  tryCatch(fromJSON(body_text, simplifyVector = FALSE),
           error = function(e) list(.raw = body_text))
}

worker_name <- function(host, port, i) {
  sprintf("mirai-worker-%s-%s-%d", gsub("\\.", "-", host), port, i)
}

#* Test Docker socket — version + raw create attempt
#* @get /debug
function() {
  image <- Sys.getenv("MIRAI_IMAGE", "ghcr.io/ryanscharf/mirai-docker:latest")

  version_out <- system2("curl", c("-s", "--unix-socket", SOCK,
                                    "http://localhost/version"),
                          stdout = TRUE, stderr = TRUE)

  create_body <- toJSON(list(
    Image      = image,
    Env        = list("MIRAI_HOST=debug", "MIRAI_PORT=5555"),
    Cmd        = list("Rscript", "/worker.R"),
    HostConfig = list(AutoRemove = TRUE)
  ), auto_unbox = TRUE)

  create_out <- system2(
    "curl",
    c("-s", "-i", "--unix-socket", SOCK,
      "-X", "POST",
      "-H", "Content-Type: application/json",
      "-d", create_body,
      "http://localhost/containers/create?name=mirai-debug-delete-me"),
    stdout = TRUE, stderr = TRUE
  )

  # Clean up if it actually created
  system2("curl", c("-s", "--unix-socket", SOCK, "-X", "DELETE",
                    "http://localhost/containers/mirai-debug-delete-me"),
          stdout = FALSE, stderr = FALSE)

  list(
    version     = paste(version_out, collapse = "\n"),
    create_raw  = paste(create_out,  collapse = "\n"),
    create_body = create_body
  )
}

#* Start workers for a dispatcher
#* @post /workers/start
function(dispatcher, n = 4, port = 5555) {
  n     <- as.integer(n)
  port  <- as.integer(port)
  image <- Sys.getenv("MIRAI_IMAGE", "ghcr.io/ryanscharf/mirai-docker:latest")

  # Pull image so /containers/create doesn't 404 on a cold TrueNAS host.
  # This blocks until the pull completes (no-op if already present).
  docker_post(paste0("/images/create?fromImage=",
                     URLencode(image, reserved = TRUE)))

  started <- character(0)
  failed  <- character(0)
  errors  <- list()

  for (i in seq_len(n)) {
    name <- worker_name(dispatcher, port, i)
    resp <- docker_post(
      paste0("/containers/create?name=", name),
      list(
        Image      = image,
        Env        = list(paste0("MIRAI_HOST=", dispatcher),
                          paste0("MIRAI_PORT=", port)),
        Cmd        = list("Rscript", "/worker.R"),
        HostConfig = list(AutoRemove = TRUE)
      )
    )
    if (!is.null(resp$Id)) {
      docker_post(paste0("/containers/", resp$Id, "/start"))
      started <- c(started, name)
    } else {
      failed        <- c(failed, name)
      errors[[name]] <- toJSON(resp, auto_unbox = TRUE)
    }
  }

  list(started = started, failed = failed, errors = errors,
       dispatcher = dispatcher, port = port)
}

#* Stop workers for a dispatcher
#* @post /workers/stop
function(dispatcher, port = 5555) {
  port    <- as.integer(port)
  pattern <- sprintf("mirai-worker-%s-%s", gsub("\\.", "-", dispatcher), port)
  filters <- URLencode(toJSON(list(name = list(pattern)), auto_unbox = TRUE),
                       reserved = TRUE)
  containers <- docker_get(paste0("/containers/json?filters=", filters))

  ids <- vapply(containers, function(c) c$Id, character(1))
  for (id in ids) docker_post(paste0("/containers/", id, "/stop"))

  list(stopped = length(ids), dispatcher = dispatcher, port = port)
}

#* List all running mirai worker containers
#* @get /workers
function() {
  filters    <- URLencode(toJSON(list(name = list("mirai-worker")), auto_unbox = TRUE),
                          reserved = TRUE)
  containers <- docker_get(paste0("/containers/json?filters=", filters))
  workers    <- vapply(containers, function(c) {
    paste0(sub("^/", "", c$Names[[1]]), "\t", c$Status)
  }, character(1))
  list(workers = workers)
}
