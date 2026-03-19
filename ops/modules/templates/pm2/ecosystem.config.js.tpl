// ecosystem.config.js.tpl
// PM2 ecosystem config template for a generic Node.js app.
// Rendered by OPS node module — do not edit this template directly.
// Placeholders: {{APP_NAME}}, {{APP_PATH}}, {{APP_PORT}}, {{NODE_ENV}},
//               {{INSTANCES}}, {{EXEC_MODE}}, {{MAX_MEMORY_RESTART}}

module.exports = {
  apps: [
    {
      name: "{{APP_NAME}}",
      script: "{{APP_PATH}}",
      cwd: require("path").dirname("{{APP_PATH}}"),
      instances: {{INSTANCES}},         // 1 for Tier S, or min(CPU_CORES,4) for M/L CPU-bound apps
      exec_mode: "{{EXEC_MODE}}",       // "fork" or "cluster"
      env: {
        NODE_ENV: "{{NODE_ENV}}",
        PORT: {{APP_PORT}},
      },
      // Restart policy
      max_restarts: 10,
      min_uptime: "5s",
      restart_delay: 2000,
      // Memory safety valve: recycle the process if RSS exceeds this limit.
      // Prevents a leaky app from starving the whole VPS (tier-tuned by OPS).
      // Tier S (<1.5 GB RAM): 300M  |  Tier M: 500M  |  Tier L: 800M
      max_memory_restart: "{{MAX_MEMORY_RESTART}}",
      // Logging
      out_file: "/var/log/ops/pm2-{{APP_NAME}}-out.log",
      error_file: "/var/log/ops/pm2-{{APP_NAME}}-err.log",
      merge_logs: true,
      log_date_format: "YYYY-MM-DD HH:mm:ss",
      // Graceful shutdown — do NOT add wait_ready here.
      // Most apps do not emit process.send('ready'); enabling it by default
      // causes PM2 to wait until listen_timeout and then treat startup as failed.
      kill_timeout: 5000,
      listen_timeout: 10000,
    },
  ],
};
