library(plumber)
library(jsonlite)
library(curl)

SOCK <- "/var/run/docker.sock"

docker_request <- function(method, path, body = NULL) {
  h <- new_handle(unix_socket_path = SOCK, customrequest = method)
  if (!is.null(body)) {
    handle_setheaders(h, "Content-Type" = "application/json")
    handle_setopt(h, postfields = toJSON(body, auto_unbox = TRUE))
  }
  resp     <- curl_fetch_memory(paste0("http://localhost", path), handle = h)
  raw_text <- rawToChar(resp$content)
  if (!nzchar(raw_text)) return(list())
  tryCatch(fromJSON(raw_text, simplifyVector = FALSE),
           error = function(e) list(.raw = raw_text))
}

docker_get  <- function(path)              docker_request("GET",  path)
docker_post <- function(path, body = NULL) docker_request("POST", path, body)

worker_name <- function(host, port, i) {
  sprintf("mirai-worker-%s-%s-%d", gsub("\\.", "-", host), port, i)
}

request_meta <- function(req) {
  list(
    received_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    from        = req$REMOTE_ADDR
  )
}

#* Log every incoming request
#* @filter logger
function(req) {
  cat(sprintf("[%s] %s %s from %s\n",
              format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
              req$REQUEST_METHOD,
              req$PATH_INFO,
              req$REMOTE_ADDR))
  plumber::forward()
}

#* Test Docker socket — version + raw create attempt
#* @get /debug
function(req) {
  image <- Sys.getenv("MIRAI_IMAGE", "ghcr.io/ryanscharf/mirai-docker:latest")

  version <- docker_get("/version")

  h <- new_handle(unix_socket_path = SOCK, customrequest = "POST")
  handle_setheaders(h, "Content-Type" = "application/json")
  handle_setopt(h, postfields = toJSON(list(
    Image      = image,
    Env        = list("MIRAI_HOST=debug", "MIRAI_PORT=5555"),
    Cmd        = list("Rscript", "/worker.R"),
    HostConfig = list(AutoRemove = TRUE)
  ), auto_unbox = TRUE))
  raw_resp <- curl_fetch_memory(
    "http://localhost/containers/create?name=mirai-debug-delete-me",
    handle = h
  )
  create_raw <- rawToChar(raw_resp$content)

  docker_request("DELETE", "/containers/mirai-debug-delete-me")

  c(request_meta(req),
    list(
      status         = raw_resp$status_code,
      create_raw     = create_raw,
      docker_version = version$Version
    ))
}

#* Start workers for a dispatcher
#* @post /workers/start
function(req, dispatcher, n = 4, port = 5555) {
  n     <- as.integer(n)
  port  <- as.integer(port)
  image <- Sys.getenv("MIRAI_IMAGE", "ghcr.io/ryanscharf/mirai-docker:latest")

  cat(sprintf("  dispatcher=%s  n=%d  port=%d  image=%s\n",
              dispatcher, n, port, image))

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
      cat(sprintf("  started %s\n", name))
    } else {
      failed         <- c(failed, name)
      errors[[name]] <- if (!is.null(resp$message)) resp$message else
                          if (!is.null(resp$.raw)) resp$.raw else "unknown"
      cat(sprintf("  FAILED  %s: %s\n", name, errors[[name]]))
    }
  }

  c(request_meta(req),
    list(started = started, failed = failed, errors = errors,
         dispatcher = dispatcher, port = port))
}

#* Stop workers for a dispatcher
#* @post /workers/stop
function(req, dispatcher, port = 5555) {
  port    <- as.integer(port)
  pattern <- sprintf("mirai-worker-%s-%s", gsub("\\.", "-", dispatcher), port)
  filters <- URLencode(toJSON(list(name = list(pattern)), auto_unbox = TRUE),
                       reserved = TRUE)
  containers <- docker_get(paste0("/containers/json?filters=", filters))

  ids <- vapply(containers, function(c) c$Id, character(1))
  for (id in ids) {
    docker_post(paste0("/containers/", id, "/stop"))
    cat(sprintf("  stopped %s\n", id))
  }

  c(request_meta(req),
    list(stopped = length(ids), dispatcher = dispatcher, port = port))
}

#* List all running mirai worker containers
#* @get /workers
function(req) {
  filters    <- URLencode(toJSON(list(name = list("mirai-worker")), auto_unbox = TRUE),
                          reserved = TRUE)
  containers <- docker_get(paste0("/containers/json?filters=", filters))
  workers    <- vapply(containers, function(c) {
    paste0(sub("^/", "", c$Names[[1]]), "\t", c$Status)
  }, character(1))

  c(request_meta(req), list(workers = workers))
}
