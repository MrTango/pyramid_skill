# Deployment: production.ini, WSGI servers, nginx, systemd, Docker

Recommended production stack: **nginx** (TLS termination, static files, buffering)
→ **WSGI server** (waitress or gunicorn) → your Pyramid app, supervised by
**systemd** (or run in a container). Never expose the raw WSGI server to the
internet.

## production.ini

Start from the generated `production.ini` and harden it:

```ini
[app:main]
use = egg:myproject

# --- turn OFF all dev/debug aids ---
pyramid.reload_templates = false
pyramid.debug_authorization = false
pyramid.debug_notfound = false
pyramid.debug_routematch = false
pyramid.default_locale_name = en
# NO pyramid_debugtoolbar here!
pyramid.includes =
    pyramid_tm

# secrets/urls come from the environment, not the file (see below)
sqlalchemy.url = %(DATABASE_URL)s
auth.secret = %(AUTH_SECRET)s
session.secret = %(SESSION_SECRET)s

[server:main]
use = egg:waitress#main
listen = 127.0.0.1:6543         # bind localhost; nginx proxies to it
# waitress honors X-Forwarded-* when told which proxy to trust:
trusted_proxy = 127.0.0.1
trusted_proxy_headers = x-forwarded-for x-forwarded-host x-forwarded-proto x-forwarded-port
```

Logging section: keep `level = WARN`/`INFO` (not DEBUG) for `root`/app loggers,
and `sqlalchemy.engine = WARN`.

### Secrets & env interpolation

Do **not** commit secrets. PasteDeploy interpolates `%(NAME)s` from the
`[DEFAULT]` section and OS environment isn't read automatically — common patterns:

- Set values in `[DEFAULT]` on the host and keep `production.ini` out of VCS, or
- Read env vars in `main()`:
  ```python
  import os
  settings["sqlalchemy.url"] = os.environ["DATABASE_URL"]
  settings["auth.secret"] = os.environ["AUTH_SECRET"]
  ```

## WSGI servers

### Waitress (pure-Python, simplest, cross-platform)

Already the starter default. Run with `pserve production.ini`. Good throughput for
most apps; handles slow clients well. Set `trusted_proxy*` so `request.route_url`
generates correct `https://` URLs behind nginx.

### Gunicorn (multi-process, Unix)

```bash
pip install gunicorn
gunicorn --paste production.ini -w 4 -b 127.0.0.1:6543 \
         --forwarded-allow-ips=127.0.0.1
```

- `-w` workers ≈ `2 × CPU + 1` (sync workers). Each worker is a separate process.
- `--forwarded-allow-ips` — gunicorn ignores `X-Forwarded-*` unless the proxy IP
  is trusted; set it or generated URLs/scheme will be wrong behind nginx.
- `--paste` loads the app from the `.ini` (needs the app installed in the venv).

Pick waitress for simplicity/portability; gunicorn when you want process-level
concurrency and its worker types.

## nginx reverse proxy

```nginx
upstream myapp { server 127.0.0.1:6543; }

server {
    listen 443 ssl http2;
    server_name example.com;

    ssl_certificate     /etc/letsencrypt/live/example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

    # serve static assets directly (fast, cached)
    location /static/ {
        alias /srv/myapp/myproject/static/;
        expires 1h;
        access_log off;
    }

    location / {
        proxy_pass http://myapp;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;   # so app knows it's HTTPS
        proxy_set_header X-Forwarded-Host  $host;
    }
}

server {                       # redirect http -> https
    listen 80;
    server_name example.com;
    return 301 https://$host$request_uri;
}
```

The `X-Forwarded-Proto`/`Host` headers + the WSGI server's trusted-proxy config are
what make Pyramid emit correct absolute `https://` URLs. If the app is mounted under
a path prefix, set `SCRIPT_NAME`/`proxy_set_header` accordingly or use a
`prefixmiddleware`.

## systemd service

`/etc/systemd/system/myapp.service`:

```ini
[Unit]
Description=MyProject Pyramid app
After=network.target postgresql.service

[Service]
User=www-data
Group=www-data
WorkingDirectory=/srv/myapp
Environment=DATABASE_URL=postgresql://user:pass@localhost/myapp
Environment=AUTH_SECRET=change-me
Environment=SESSION_SECRET=change-me-too
ExecStart=/srv/myapp/env/bin/pserve production.ini
# or: /srv/myapp/env/bin/gunicorn --paste production.ini -w 4 -b 127.0.0.1:6543
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now myapp
sudo systemctl status myapp
journalctl -u myapp -f          # tail logs
```

## Docker

```dockerfile
FROM python:3.12-slim
WORKDIR /app
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1

COPY setup.py pyproject.toml README.txt CHANGES.txt ./
COPY myproject ./myproject
RUN pip install --upgrade pip && pip install -e . waitress

EXPOSE 6543
# bind 0.0.0.0 inside the container; still front it with nginx/ingress
CMD ["pserve", "production.ini"]
```

Run migrations as a separate step/initContainer before the app starts:

```bash
alembic -c production.ini upgrade head
```

Compose sketch: an `app` service (this image), a `db` service (postgres), and an
`nginx` service terminating TLS and proxying to `app:6543`. Pass secrets via
environment variables / secrets, never baked into the image.

## Release checklist

- [ ] `production.ini`: template reload off, all `debug_*` off, **no** debugtoolbar.
- [ ] Secrets from env, not committed. Rotate `auth.secret`/`session.secret`.
- [ ] `pip install -e .` (or wheel) into a clean venv; pin deps / use a lockfile.
- [ ] `alembic upgrade head` run as part of deploy, before traffic.
- [ ] TLS at nginx; `X-Forwarded-Proto` set; WSGI server trusts the proxy IP.
- [ ] Static files served by nginx (`add_static_view` still needed for URL gen).
- [ ] Process supervised (systemd/container orchestrator) with auto-restart.
- [ ] Logging to stdout/journal at INFO/WARN; error monitoring (Sentry etc.).
- [ ] Health-check route (permission `NO_PERMISSION_REQUIRED`) for load balancers.
- [ ] Run `pytest` in CI against `testing.ini` before deploy.
