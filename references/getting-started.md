# Getting Started: Projects, Structure, Running

## Installing & scaffolding

Pyramid projects are normally scaffolded with the official cookiecutter
(`pyramid-cookiecutter-starter`). It installs Pyramid and its dependencies and
generates a working app.

```bash
python3 -m venv env
env/bin/pip install --upgrade pip setuptools
env/bin/pip install cookiecutter
env/bin/cookiecutter gh:Pylons/pyramid-cookiecutter-starter --checkout main
```

Prompts:

- **template language** — `jinja2` (default, `.jinja2`), `chameleon` (`.pt`), or `mako` (`.mako`).
- **backend** — `none`, `sqlalchemy` (SQLite + SQLAlchemy + Alembic + pyramid_tm), or `zodb`.
- **routing** — `urldispatch` (route table, most common) or `traversal` (resource tree).

Then install the project **editable** with its test extra and run it:

```bash
cd <project_slug>
../env/bin/pip install -e ".[testing]"
../env/bin/pserve development.ini --reload   # serves http://localhost:6543
../env/bin/pytest -q
```

`-e` (editable) means code edits take effect without reinstalling. `--reload`
restarts the server when Python files change (template reload is separate — see below).

## Generated project layout (starter, SQLAlchemy backend)

```
<project>/
├── development.ini          # PasteDeploy config for dev (debugtoolbar, reload on)
├── production.ini           # PasteDeploy config for prod (debug off)
├── testing.ini              # config used by functional tests
├── pytest.ini               # pytest settings
├── setup.py / pyproject.toml# package metadata, deps, entry points, [testing] extra
├── MANIFEST.in
├── CHANGES.txt / README.txt
├── <project>/               # the application package
│   ├── __init__.py          # main() app factory — the heart of the app
│   ├── routes.py            # add_route + add_static_view calls (includeme)
│   ├── models/              # (sqlalchemy) SQLAlchemy models, get_engine/get_session_factory
│   │   ├── __init__.py      #   includeme wires request.dbsession via pyramid_tm
│   │   ├── meta.py          #   declarative Base / metadata
│   │   └── mymodel.py
│   ├── views/               # view callables grouped by concern
│   │   ├── __init__.py
│   │   ├── default.py       # @view_config-decorated views
│   │   └── notfound.py      # 404 view
│   ├── templates/           # layout.jinja2, mytemplate.jinja2, 404.jinja2
│   ├── static/              # css/js/images served via add_static_view
│   ├── scripts/             # console scripts, e.g. initialize_db
│   └── alembic/             # (sqlalchemy) migration env + versions/
└── tests/                   # or tests.py — conftest.py, test_views.py, test_functional.py
```

Non-SQLAlchemy starters drop `models/`, `scripts/`, and `alembic/`.

## The app factory (`__init__.py`)

Everything starts here. `pserve` calls this via the `.ini` `use = egg:<project>`.

```python
from pyramid.config import Configurator


def main(global_config, **settings):
    """Build and return the WSGI application."""
    with Configurator(settings=settings) as config:
        config.include("pyramid_jinja2")       # templating add-on
        config.include(".routes")               # our routes.py includeme
        config.include(".models")               # (sqlalchemy) db + pyramid_tm
        config.scan()                           # activate @view_config decorators
    return config.make_wsgi_app()
```

`with Configurator(...) as config:` uses the context manager form so
`config.commit()` runs on exit and thread-local state is cleaned up.

`config.include(".routes")` imports `<project>/routes.py` and calls its
`includeme(config)` function — a leading `.` means "relative to this package".

## routes.py

```python
def includeme(config):
    config.add_static_view("static", "static", cache_max_age=3600)
    config.add_route("home", "/")
    config.add_route("hello", "/howdy/{name}")
```

## Console scripts (SQLAlchemy backend)

The starter defines an `initialize_db` console script (registered in
`setup.py`/`pyproject.toml` `[console_scripts]`) that creates tables and seeds data:

```bash
../env/bin/initialize_db development.ini
```

Write your own management commands with `pyramid.paster.bootstrap` /
`get_appsettings` — see `references/models-and-data.md`.

## Dev-loop knobs (development.ini)

- `pyramid.reload_templates = true` — edit templates without restarting.
- `pyramid.includes = pyramid_debugtoolbar` — the interactive debug toolbar
  (click the Pyramid logo in the top-right). `debugtoolbar.hosts = 0.0.0.0/0`
  to allow it from non-localhost (dev only).
- `[server:main] listen = localhost:6543` — change host/port; `listen = *:6543`
  to accept connections from the network.

## Commands cheat sheet

| Task | Command |
|---|---|
| Run dev server w/ reload | `pserve development.ini --reload` |
| Run on prod config | `pserve production.ini` |
| Interactive shell w/ app loaded | `pshell development.ini` |
| Show matched route for a URL | `proutes development.ini` |
| Show all registered views | `pviews development.ini /some/path` |
| Run tests | `pytest -q` |
| Tests + coverage | `pytest --cov -q` |
| Init database (sqlalchemy starter) | `initialize_db development.ini` |
| Create migration | `alembic -c development.ini revision --autogenerate -m "msg"` |
| Apply migrations | `alembic -c development.ini upgrade head` |
