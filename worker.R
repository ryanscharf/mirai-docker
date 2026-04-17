library(mirai)

host <- Sys.getenv("MIRAI_HOST")
if (host == "") stop("MIRAI_HOST is not set")
port <- Sys.getenv("MIRAI_PORT", "5555")
url  <- paste0("tcp://", host, ":", port)

repeat {
  connected <- tryCatch(
    { cat("Connecting to", url, "\n"); daemon(url); TRUE },
    error = function(e) { cat("Error:", conditionMessage(e), "\n"); FALSE }
  )
  if (connected) { cat("Dispatcher closed. Exiting.\n"); break }
  cat("Retrying in 2s...\n")
  Sys.sleep(2)
}
