# hostctl

`hostctl` is an interactive Bash-based server management CLI for deploying and maintaining Dockerized Python backends such as Django, Flask, and FastAPI on Debian-based Linux systems.

## Features

* Docker & Docker Compose management
* Nginx reverse proxy and security
* Certbot SSL setup
* UFW firewall management
* Swap/V-RAM configuration
* Database backup and restore
* rclone backup integration
* Cron job management
* Automated cleanup
* Fail2Ban and SSH hardening
* Server monitoring and health checks
* Docker, Nginx, and system log management

## Installation

```bash
chmod +x hostctl.sh
sudo ./hostctl.sh --init
```

`--init` installs the selected dependencies and registers `hostctl` as a system-wide command.

After installation:

```bash
sudo hostctl --help
sudo hostctl --status
```

## Project Context

Docker and database operations use the current working directory as the project context.

```bash
cd /path/to/project
sudo hostctl --docker-start
```

`hostctl` automatically detects `docker-compose*` files and asks which one to use when multiple files exist.

Global operations such as Nginx, firewall, SSL, system monitoring, and security are independent of the current project directory.

## Requirements

* Debian-based Linux
* Bash
* Root/sudo privileges

## Help

```bash
sudo hostctl --help
```
