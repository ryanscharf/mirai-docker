library(plumber)

worker_name <- function(host, port, i) {
  sprintf("mirai-worker-%s-%s-%d", gsub("\\.", "-", host), port, i)
}

worker_cmd <- function(host, port) {
  sprintf(
    "library(mirai);
     url <- 'tcp://%s:%d';
     repeat {
       connected <- tryCatch({ daemon(url); TRUE },
         error = function(e) { cat('Error:', conditionMessage(e), '\\n'); FALSE });
       if (connected) { cat('Dispatcher closed. Exiting.\\n'); break };
       cat('Retrying in 2s...\\n');
       Sys.sleep(2)
     }",
    host, as.integer(port)
  )
}

#* Start workers for a dispatcher
#* @post /workers/start
function(dispatcher, n = 4, port = 5555) {
  n    <- as.integer(n)
  port <- as.integer(port)
  image <- Sys.getenv("MIRAI_IMAGE", "ghcr.io/ryanscharf/mirai-docker:latest")

  started <- character(0)
  failed  <- character(0)

  for (i in seq_len(n)) {
    name   <- worker_name(dispatcher, port, i)
    result <- system2(
      "docker",
      c("run", "--rm", "-d",
        "--name", name,
        "-e", paste0("MIRAI_HOST=", dispatcher),
        image,
        "Rscript", "-e", worker_cmd(dispatcher, port)),
      stdout = TRUE, stderr = TRUE
    )
    if (attr(result, "status") %in% c(0, NULL)) {
      started <- c(started, name)
    } else {
      failed <- c(failed, name)
    }
  }

  list(started = started, failed = failed, dispatcher = dispatcher, port = port)
}

#* Stop workers for a dispatcher
#* @post /workers/stop
function(dispatcher, port = 5555) {
  port    <- as.integer(port)
  pattern <- sprintf("mirai-worker-%s-%s", gsub("\\.", "-", dispatcher), port)
  ids     <- system2("docker", c("ps", "-q", "--filter", paste0("name=", pattern)),
                     stdout = TRUE, stderr = FALSE)
  ids     <- ids[nchar(ids) > 0]

  if (length(ids) > 0) {
    system2("docker", c("stop", ids), stdout = FALSE, stderr = FALSE)
  }

  list(stopped = length(ids), dispatcher = dispatcher, port = port)
}

#* List all running mirai worker containers
#* @get /workers
function() {
  lines <- system2(
    "docker",
    c("ps", "--filter", "name=mirai-worker",
      "--format", "{{.Names}}\t{{.Status}}"),
    stdout = TRUE, stderr = FALSE
  )
  list(workers = lines[nchar(lines) > 0])
}
