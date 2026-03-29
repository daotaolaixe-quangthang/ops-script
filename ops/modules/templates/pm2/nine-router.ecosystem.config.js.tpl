// /opt/9router/nine-router.ecosystem.config.js
// Managed by OPS — do not edit manually
module.exports = {
  apps: [{
    name:       'nine-router',
    // 9router is built with `output: standalone` — use the self-contained server
    // directly instead of `next start` (which does NOT work with standalone builds
    // and emits a warning, causing repeated PM2 restarts in older versions).
    // The standalone server reads PORT and HOSTNAME from the environment.
    script:     'node',
    args:       '.next/standalone/server.js',
    cwd:        '{{NINE_ROUTER_DIR}}',
    instances:  1,
    exec_mode:  'fork',
    // Cap V8 heap at ~90% of max_memory_restart (512M) so GC runs aggressively
    // before PM2's RSS limit triggers a hard restart. Prevents 93%+ heap usage.
    // --expose-gc allows Node to run incremental GC passes on idle, reducing
    // peak RSS on a memory-constrained VPS.
    node_args:  '--max-old-space-size=460 --expose-gc',
    // S3-4: filter_env [] means PM2 will NOT copy shell-inherited env vars
    // into this process beyond what the `env` block and `env_file` declare.
    // Combined with `env -i` in the shell launcher, SSH_CONNECTION / ADMIN_USER
    // and other SSH session variables are fully excluded.
    filter_env: [],
    env: {
      PORT:     '{{NINE_ROUTER_PORT}}',
      HOSTNAME: '127.0.0.1',
      NODE_ENV: 'production',
      DATA_DIR: '/var/lib/9router',
      // Secrets loaded from .env file — do NOT inline here
    },
    env_file:           '{{NINE_ROUTER_DIR}}/.env',
    error_file:         '/var/log/ops/nine-router.err.log',
    out_file:           '/var/log/ops/nine-router.out.log',
    log_date_format:    'YYYY-MM-DD HH:mm:ss',
    // merge_logs prevents PM2 appending "-<id>" suffix to log filenames
    merge_logs:         true,
    restart_delay:      3000,
    max_restarts:       10,
    // Memory safety valve: Next.js can grow large; recycle before OOMing the VPS.
    max_memory_restart: '512M',
    // Graceful shutdown: Next.js needs up to 8s to drain active SSR requests.
    kill_timeout:       8000,
    // Cold start: Next.js can take 10-15s to boot on first deploy.
    listen_timeout:     15000,
    watch:              false
  }]
};
