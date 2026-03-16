'use strict';

module.exports = {
  apps: [
    {
      name:             'heliproxy-monitor',
      script:           '/opt/heliproxy/monitor.js',
      instances:        1,
      autorestart:      true,
      watch:            false,
      max_restarts:     20,
      restart_delay:    5000,
      exp_backoff_restart_delay: 100,
      max_memory_restart: '128M',
      env: {
        NODE_ENV:          'production',
        CONTAINER_NAME:    'mtproto-proxy',
        MONITOR_PORT:      '3000',
        CHECK_INTERVAL_MS: '30000',
      },
      error_file:      '/var/log/heliproxy-monitor-err.log',
      out_file:        '/var/log/heliproxy-monitor-out.log',
      log_date_format: 'YYYY-MM-DD HH:mm:ss',
    },
  ],
};
