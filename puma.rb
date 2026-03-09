# Puma configuration
workers 0           # single process to keep in-memory stores shared
threads_count = 4
threads threads_count, threads_count

environment ENV.fetch('RACK_ENV', 'production')

# Bind to all interfaces so Docker networking works
bind "tcp://0.0.0.0:#{ENV.fetch('PORT', 4567)}"
