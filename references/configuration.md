# Configuration: Configurator, includes, and .ini files

## Imperative vs declarative — they are equivalent

**Imperative** — plain Python statements on the `Configurator`:

```python
from pyramid.config import Configurator
from .views import hello_view

def main(global_config, **settings):
    with Configurator(settings=settings) as config:
        config.add_route("hello", "/hello/{name}")
        config.add_view(hello_view, route_name="hello", renderer="json")
    return config.make_wsgi_app()
```

**Declarative** — decorators near the code, activated by a scan:

```python
# views.py
from pyramid.view import view_config

@view_config(route_name="hello", renderer="json")
def hello_view(request):
    return {"hello": request.matchdict["name"]}
```

```python
# __init__.py
config.add_route("hello", "/hello/{name}")
config.scan()          # imports the package, registers @view_config/@subscriber/etc.
```

Real projects mix them: routes/includes imperatively in the app factory, views
declaratively via `@view_config` + `config.scan()`. Routes are (almost) always
imperative because **order matters** (first match wins).

## The Configurator — the one registry

Common methods:

| Method | Purpose |
|---|---|
| `add_route(name, pattern, ...)` | register a URL route |
| `add_view(view, ...)` | register a view callable |
| `add_static_view(name, path)` | serve a static asset directory |
| `add_notfound_view` / `add_forbidden_view` / `add_exception_view` | error views |
| `include(callable_or_dotted)` | pull in an add-on / sub-config |
| `scan(package=None)` | activate venusian decorators (`@view_config`, `@subscriber`) |
| `set_security_policy(policy)` | install the security policy (2.x) |
| `set_default_csrf_options(require_csrf=True)` | global CSRF enforcement |
| `add_request_method(callable, name=, reify=, property=)` | attach `request.xxx` helpers |
| `add_subscriber(fn, iface)` | register an event subscriber imperatively |
| `set_request_factory` / `add_renderer` / `add_route_predicate` | advanced hooks |
| `registry.settings` | the merged settings dict |

Use the context-manager form `with Configurator(settings=settings) as config:` so
pending config is committed and thread-locals are cleaned up on exit.

### Conflict detection

Pyramid detects conflicting registrations (e.g. two views for the exact same
predicates) at commit time and raises `ConfigurationConflictError` with both
source locations. `config.commit()` forces resolution early; `config.override_asset`
and `config.include` participate in conflict resolution too. Two registrations at
different "phases"/specificities do **not** conflict — this is how add-ons provide
overridable defaults.

## Add-ons and `includeme`

An add-on (or your own sub-module) is any callable, usually
`def includeme(config): ...`, that receives the Configurator:

```python
# myproject/routes.py
def includeme(config):
    config.add_static_view("static", "static", cache_max_age=3600)
    config.add_route("home", "/")
```

Activate it:

```python
config.include(".routes")          # dotted, relative to current package
config.include("pyramid_jinja2")   # third-party add-on
config.include("pyramid_tm")       # transaction manager
```

Or from the `.ini` (runs before `main()` body’s explicit includes are unaffected):

```ini
[app:main]
pyramid.includes =
    pyramid_debugtoolbar
    pyramid_tm
```

`config.include` runs the add-on with a configuration context rooted at the
add-on's package, so its asset paths resolve correctly. Prefer `pyramid.includes`
in the `.ini` for things that differ per environment (e.g. debugtoolbar in dev only).

## Settings

Anything in the `[app:main]` section (besides reserved `pyramid.*` keys) lands in
`settings` / `config.registry.settings`, all as **strings** — convert types yourself:

```python
from pyramid.settings import asbool, aslist

def main(global_config, **settings):
    debug = asbool(settings.get("myapp.feature_x", False))
    hosts = aslist(settings.get("myapp.hosts", ""))
```

Read settings inside views via `request.registry.settings`.

## PasteDeploy .ini structure

```ini
[app:main]
use = egg:myproject                 # -> paste.app_factory entry point -> main()
pyramid.reload_templates = true
pyramid.debug_authorization = false
pyramid.default_locale_name = en
pyramid.includes =
    pyramid_debugtoolbar
sqlalchemy.url = sqlite:///%(here)s/myproject.sqlite

[pshell]
setup = myproject.pshell.setup      # optional pshell bootstrapping

[server:main]
use = egg:waitress#main
listen = localhost:6543

# --- logging (Python logging config format) ---
[loggers]
keys = root, myproject, sqlalchemy.engine

[handlers]
keys = console

[formatters]
keys = generic

[logger_root]
level = INFO
handlers = console

[logger_myproject]
level = DEBUG
handlers =
qualname = myproject

[handler_console]
class = StreamHandler
args = (sys.stderr,)
level = NOTSET
formatter = generic

[formatter_generic]
format = %(asctime)s %(levelname)-5.5s [%(name)s:%(lineno)s][%(threadName)s] %(message)s
```

Key section types:

- `[app:main]` — the WSGI app; `use = egg:<project>` resolves to your `main()`.
- `[server:main]` — the WSGI server (waitress by default).
- `[pipeline:main]` — an ordered WSGI middleware pipeline ending in the app:
  ```ini
  [pipeline:main]
  pipeline =
      egg:WebError#evalerror
      translogger
      myapp
  [app:myapp]
  use = egg:myproject
  ```
- `[filter:...]` — WSGI middleware referenced by a pipeline.
- `[composite:main]` — dispatch to multiple apps by URL prefix (`egg:Paste#urlmap`).
- `[DEFAULT]` — shared globals passed to `main()` as `global_config`.
  `%(here)s` interpolates the directory of the `.ini` file.

`pserve <file.ini>` reads `[server:main]`, builds `[app:main]` (or the pipeline),
and serves it. `pserve --reload` watches for file changes.
