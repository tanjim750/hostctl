hostctl --init

hostctl --update
hostctl --vram
hostctl --cleanup
hostctl --cleanup --schedule

hostctl --docker
hostctl --docker-status
hostctl --docker-build
hostctl --docker-start
hostctl --docker-stop
hostctl --docker-restart
hostctl --docker-rebuild
hostctl --docker-down
hostctl --docker-pull
hostctl --docker-logs
hostctl --docker-logs-clear
hostctl --docker-ps

hostctl --nginx
hostctl --domain
hostctl --nginx-security
hostctl --nginx-rate-limit
hostctl --nginx-block-ip
hostctl --nginx-whitelist-ip
sudo hostctl --nginx-block-ip-list
sudo hostctl --nginx-block-ip-remove
sudo hostctl --nginx-whitelist-ip-list
sudo hostctl --nginx-rate-limit-list
hostctl --nginx-logs
hostctl --nginx-logs-clear

hostctl --ssl
hostctl --ssl-status

hostctl --firewall
hostctl --allow-port
hostctl --deny-port
hostctl --firewall-status
hostctl --firewall-reset

hostctl --db-backup
hostctl --db-restore
hostctl --backup-now
hostctl --backup-schedule
hostctl --backup-status

hostctl --rclone

hostctl --cronjob
hostctl --cron-list
hostctl --cron-remove

hostctl --security
hostctl --fail2ban
hostctl --ssh-security
hostctl --security-status

hostctl --status
hostctl --health
hostctl --monitor
hostctl --service-status

hostctl --logs
hostctl --logs-clear
hostctl --log-status
hostctl --system-logs

hostctl --help
hostctl --version