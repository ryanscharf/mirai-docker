library(mirai)
source("R/workers.R")
gc()

# ---- configuration ----
dispatcher_host <- "192.168.2.4" # your machine's LAN IP (workers dial back to this)
dispatcher_port <- 5555 # must match MIRAI_PORT in .env
n_workers <- 4 # how many workers to spin up for the test
n_timing_workers <- 4 # expected worker count for the parallelism timing test
api_host <- "192.168.2.66" # TrueNAS IP (where the Plumber API is running)
api_port <- 8089 # must match MIRAI_API_PORT in .env
# ----------------------

Sys.setenv(MIRAI_API_HOST = api_host, MIRAI_API_PORT = api_port)

wait_for_workers <- function(n, timeout = 60, poll = 0.5) {
  deadline <- Sys.time() + timeout
  while (Sys.time() < deadline) {
    connected <- status()$connections
    if (connected >= n) {
      cat(sprintf("All %d/%d workers connected.\n", connected, n))
      return(invisible(TRUE))
    }
    Sys.sleep(poll)
  }
  connected <- status()$connections
  warning(sprintf(
    "Only %d/%d workers connected after %ds. Proceeding with available workers.",
    connected,
    n,
    timeout
  ))
  if (connected == 0) {
    stop("No workers connected — cannot proceed.")
  }
  invisible(FALSE)
}

# Start dispatcher and request workers from TrueNAS
cat("Starting dispatcher on port", dispatcher_port, "\n")
daemons(url = sprintf("tcp://0.0.0.0:%d", dispatcher_port))
start_workers(dispatcher_host, n = n_workers, port = dispatcher_port)
wait_for_workers(n_workers)

# Check connected workers
cat("\n--- Worker status ---\n")
print(status())

# 1. Basic smoke test - each worker reports its hostname
cat("\n--- Worker hostnames ---\n")
hostnames <- lapply(seq_len(status()$connections), \(i) {
  mirai(Sys.getenv("HOSTNAME"))
})
cat(unlist(lapply(hostnames, \(m) m[])), sep = "\n")

# 2. Parallel computation - distribute 20 tasks across workers
cat("\n--- Parallel computation (x^2 for x in 1:20) ---\n")
jobs <- lapply(1:20, \(x) mirai(x^2, x = x))
results <- unlist(lapply(jobs, \(m) m[]))
print(results)
stopifnot(results == (1:20)^2)
cat("PASSED\n")

# 3. Timing test - confirm tasks run in parallel, not sequentially
cat("\n--- Parallelism timing test (4 x 1s sleeps) ---\n")
t <- system.time({
  jobs <- lapply(seq_len(n_timing_workers), \(i) mirai(Sys.sleep(1)))
  lapply(jobs, \(m) m[])
})
cat(sprintf(
  "Elapsed: %.1fs (should be ~1s if workers >= %d)\n",
  t[["elapsed"]],
  n_timing_workers
))

# 4. Error handling - workers recover from failed tasks
cat("\n--- Error handling ---\n")
m <- mirai(stop("intentional error"), .timeout = 3000)
result <- m[]
stopifnot(is_mirai_error(result))
cat("Worker survived an error: PASSED\n")

cat("\n--- All tests complete ---\n")
daemons(0)
stop_workers(dispatcher_host, port = dispatcher_port)
gc()
