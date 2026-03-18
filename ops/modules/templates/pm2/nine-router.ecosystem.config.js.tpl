// nine-router.ecosystem.config.js.tpl
// PM2 ecosystem config for 9router service.
// Rendered by OPS nine-router module — do not edit this template directly.
// Placeholders: {{NINE_ROUTER_PATH}}, {{NINE_ROUTER_PORT}}, {{NODE_ENV}}

module.exports = {
  apps: [
    {
      name: "nine-router",
      script: "{{NINE_ROUTER_PATH}}",
      cwd: require("path").dirname("{{NINE_ROUTER_PATH}}"),
      instances: 1,             // 9router is stateful — always single instance
      exec_mode: "fork",
      env: {
        NODE_ENV: "{{NODE_ENV}}",
        PORT: {{NINE_ROUTER_PORT}},
        // Secrets loaded from /opt/9router/.env at runtime — NOT inline here.
      },
      // 9router serves SSE / long-poll — generous timeouts
      kill_timeout: 10000,
      wait_ready: true,
      listen_timeout: 15000,
      // Restart policy
      max_restarts: 10,
      min_uptime: "10s",
      restart_delay: 3000,
      // Logging
      out_file: "/var/log/ops/nine-router-out.log",
      error_file: "/var/log/ops/nine-router-err.log",
      merge_logs: true,
      log_date_format: "YYYY-MM-DD HH:mm:ss",
      // 9router must NOT be exposed directly to the internet — Nginx proxies it.
    },
  ],
};
