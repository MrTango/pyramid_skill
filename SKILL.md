---
name: pyramid-development
description: >-
  Build, structure, test, and deploy web applications and APIs with the Pyramid
  Python web framework (Pylons Project). Use when creating a new Pyramid project,
  wiring the Configurator, routes/URL dispatch or traversal, views and renderers,
  templates (Jinja2/Chameleon/Mako), SQLAlchemy models with pyramid_tm, security
  policies / authentication / CSRF, writing pytest tests, or configuring
  development.ini/production.ini and deploying with waitress, gunicorn, nginx,
  systemd, or Docker. Triggers on "pyramid", "pserve", "development.ini",
  "cookiecutter-starter", "@view_config", "Configurator", "pyramid_tm".
---

# Pyramid Framework Development & Deployment

Pyramid is a small, fast, "pay only for what you use" Python web framework from the
Pylons Project. It scales from a single-file app to large applications and supports
both **URL dispatch** (route tables) and **traversal** (resource trees), with pluggable
templating, persistence, and security.

## How to use this skill

1. Identify what the user is doing (new project, adding a feature, debugging, deploying).
2. Read the matching reference file(s) below **before** writing code — they contain
   the current v2.x APIs, idioms, and copy-pasteable snippets. Do not rely on memory
   for security or deployment specifics; those APIs changed in Pyramid 2.x.
3. Follow the conventions the generated cookiecutter project already uses (a `main()`
   app factory, `config.scan()`, `@view_config`, PasteDeploy `.ini` files, `pytest`).

## Reference map

| You are working on… | Read |
|---|---|
| Creating a project, project layout, running `pserve`, venv setup | `references/getting-started.md` |
| The `Configurator`, imperative vs declarative config, `include`/`includeme`, `.ini` wiring, settings | `references/configuration.md` |
| Routes/URL dispatch, traversal, view callables, renderers, templates, static assets | `references/views-and-routing.md` |
| SQLAlchemy models, sessions, `pyramid_tm` transactions, migrations, request methods | `references/models-and-data.md` |
| Writing SQLAlchemy **queries in a Pyramid app** (2.0 `select()`, joins, eager loading / N+1, pagination, aggregates, bulk writes; plus Pyramid integration: query modules, request methods, view/traversal patterns, row-level auth, query testing, deferred/no-query-on-import, and async caveats) | `references/querying-sqlalchemy.md` |
| Security policy, authentication, authorization/ACLs, permissions, CSRF, sessions | `references/security.md` |
| Unit + functional tests with `pytest`, `DummyRequest`, `testapp`/webtest | `references/testing.md` |
| production.ini, waitress/gunicorn, nginx reverse proxy, systemd, Docker, logging | `references/deployment.md` |

## Quick start (most common request)

```bash
python3 -m venv env
env/bin/pip install --upgrade pip setuptools cookiecutter
cookiecutter gh:Pylons/pyramid-cookiecutter-starter --checkout main
# choose: template language (jinja2/chameleon/mako), backend (none/sqlalchemy/zodb),
#         routing (urldispatch/traversal)
cd <project_slug>
../env/bin/pip install -e ".[testing]"
../env/bin/pserve development.ini --reload   # http://localhost:6543
../env/bin/pytest -q
```

The smallest possible Pyramid app (useful for explaining the core loop):

```python
from wsgiref.simple_server import make_server
from pyramid.config import Configurator
from pyramid.response import Response

def hello(request):
    return Response(f"Hello {request.matchdict['name']}!")

if __name__ == "__main__":
    with Configurator() as config:
        config.add_route("hello", "/hello/{name}")
        config.add_view(hello, route_name="hello")
        app = config.make_wsgi_app()
    make_server("0.0.0.0", 6543, app).serve_forever()
```

## Core mental model

- **App factory** — a `main(global_config, **settings)` function builds a `Configurator`,
  registers everything, and returns `config.make_wsgi_app()`. PasteDeploy's
  `use = egg:<project>` in the `.ini` points at it via the `paste.app_factory` entry point.
- **Configurator** — the single registry you call `add_route`, `add_view`,
  `include`, `set_security_policy`, `scan`, etc. on. `config.scan()` imports a package
  and activates `@view_config`/`@subscriber` decorators (declarative config).
- **Router** — per request: find a context (route match or traversal) → look up the best
  view for `(context, request, view_name)` → check its permission → call it → run its
  renderer → return a Response.
- **Add-ons** are just packages exposing `includeme(config)`; you activate them with
  `config.include('pyramid_jinja2')` or the `pyramid.includes` `.ini` setting.

## Version note

Target **Pyramid 2.x** (2.0/2.1). Key 2.x differences vs old tutorials:
`config.scan()` + a single **security policy** (`ISecurityPolicy`) replaced the separate
authentication + authorization policies; Python 3 only; `setup.py`/`pyproject.toml` with a
`[testing]` extra. Flag legacy patterns (`authentication_policy=`, `pyramid.security.Everyone`
imports, `unauthenticated_userid`) when you see them and steer to the current API.
