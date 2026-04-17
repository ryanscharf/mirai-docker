# mirai worker management helpers
# source("R/workers.R") to load these into your session

.mirai_api_url <- function() {
  host <- Sys.getenv("MIRAI_API_HOST", "192.168.2.66")
  port <- Sys.getenv("MIRAI_API_PORT", "8080")
  sprintf("http://%s:%s", host, port)
}

#' Start mirai workers on the remote host
#'
#' @param dispatcher_host IP of your local machine (the dispatcher)
#' @param n Number of workers to start
#' @param port mirai port (must match daemons() call). Defaults to MIRAI_PORT env var or 5555.
start_workers <- function(dispatcher_host, n = 4,
                           port = as.integer(Sys.getenv("MIRAI_PORT", "5555"))) {
  resp <- httr2::request(paste0(.mirai_api_url(), "/workers/start")) |>
    httr2::req_body_json(list(dispatcher = dispatcher_host, n = n, port = port)) |>
    httr2::req_error(is_error = \(r) FALSE) |>
    httr2::req_perform() |>
    httr2::resp_body_json()

  if (length(resp$started) > 0)
    message(sprintf("Started %d worker(s) -> %s:%d", length(resp$started), dispatcher_host, port))
  if (length(resp$failed) > 0) {
    warning(sprintf("%d worker(s) failed to start", length(resp$failed)))
    for (nm in names(resp$errors))
      message(sprintf("  %s: %s", nm, resp$errors[[nm]]))
  }

  invisible(resp)
}

#' Stop mirai workers for a dispatcher
#'
#' @param dispatcher_host IP of the dispatcher whose workers should be stopped
#' @param port mirai port. Defaults to MIRAI_PORT env var or 5555.
stop_workers <- function(dispatcher_host,
                          port = as.integer(Sys.getenv("MIRAI_PORT", "5555"))) {
  resp <- httr2::request(paste0(.mirai_api_url(), "/workers/stop")) |>
    httr2::req_body_json(list(dispatcher = dispatcher_host, port = port)) |>
    httr2::req_error(is_error = \(r) FALSE) |>
    httr2::req_perform() |>
    httr2::resp_body_json()

  message(sprintf("Stopped %d worker(s) for %s:%d", as.integer(resp$stopped), dispatcher_host, port))
  invisible(resp)
}

#' List all running mirai worker containers on the remote host
list_workers <- function() {
  resp <- httr2::request(paste0(.mirai_api_url(), "/workers")) |>
    httr2::req_error(is_error = \(r) FALSE) |>
    httr2::req_perform() |>
    httr2::resp_body_json()

  if (length(resp$workers) == 0) {
    message("No workers running.")
  } else {
    message(paste(resp$workers, collapse = "\n"))
  }

  invisible(resp$workers)
}
