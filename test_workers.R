library(mirai)

# ---- configuration ----
dispatcher_host <- "192.168.2.4"   # IP of the machine running the dispatcher
dispatcher_port <- 5555             # must match MIRAI_PORT in .env
n_timing_workers <- 4               # expected worker count for the parallelism timing test
# ----------------------

dispatcher_url <- sprintf("tcp://%s:%d", dispatcher_host, dispatcher_port)
cat("Connecting to dispatcher at", dispatcher_url, "\n")
daemons(url = dispatcher_url)

# Check connected workers
cat("\n--- Worker status ---\n")
print(status())

# 1. Basic smoke test - each worker reports its hostname
cat("\n--- Worker hostnames ---\n")
hostnames <- lapply(seq_len(status()$connections), \(i) mirai(Sys.getenv("HOSTNAME")))
cat(unlist(lapply(hostnames, `[]`)), sep = "\n")

# 2. Parallel computation - distribute 20 tasks across workers
cat("\n--- Parallel computation (x^2 for x in 1:20) ---\n")
jobs <- lapply(1:20, \(x) mirai(x^2, x = x))
results <- unlist(lapply(jobs, `[]`))
print(results)
stopifnot(results == (1:20)^2)
cat("PASSED\n")

# 3. Timing test - confirm tasks run in parallel, not sequentially
cat("\n--- Parallelism timing test (4 x 1s sleeps) ---\n")
t <- system.time({
  jobs <- lapply(seq_len(n_timing_workers), \(i) mirai(Sys.sleep(1)))
  lapply(jobs, `[]`)
})
cat(sprintf("Elapsed: %.1fs (should be ~1s if workers >= %d)\n", t[["elapsed"]], n_timing_workers))

# 4. Error handling - workers recover from failed tasks
cat("\n--- Error handling ---\n")
m <- mirai(stop("intentional error"), .timeout = 3000)
result <- m[]
stopifnot(inherits(result, "mirai_error"))
cat("Worker survived an error: PASSED\n")

cat("\n--- All tests complete ---\n")
daemons(0)
