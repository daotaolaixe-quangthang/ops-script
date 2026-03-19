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
    restart_delay:      3000,
    max_restarts:       10,
    // Memory safety valve: Next.js can grow large; recycle before OOMing the VPS.
    max_memory_restart: '512M',
    watch:              false
  }]
};
