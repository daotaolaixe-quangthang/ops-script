// /opt/9router/nine-router.ecosystem.config.js
// Managed by OPS — do not edit manually
module.exports = {
  apps: [{
    name:       'nine-router',
    script:     'node_modules/.bin/next',
    args:       'start',
    cwd:        '{{NINE_ROUTER_DIR}}',
    instances:  1,
    exec_mode:  'fork',
    // Cap V8 heap at ~90% of max_memory_restart (512M) so GC runs aggressively
    // before PM2's RSS limit triggers a hard restart. Prevents 93%+ heap usage.
    node_args:  '--max-old-space-size=460',
    env: {
      PORT:     '{{NINE_ROUTER_PORT}}',
      HOSTNAME: '0.0.0.0',
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
