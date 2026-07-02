# Views, Routing, Renderers & Templates

## View callables

A view is any callable taking `request` (or `context, request`) and producing a
response — either a `Response` object, or a value handed to a **renderer**.

```python
from pyramid.view import view_config
from pyramid.response import Response


@view_config(route_name="home", renderer="myproject:templates/home.jinja2")
def home(request):
    return {"project": "myproject"}            # dict -> renderer -> HTML


@view_config(route_name="raw")
def raw(request):
    return Response("plain text", content_type="text/plain")
```

Class-based views group related handlers and share setup:

```python
@view_defaults(renderer="myproject:templates/site.jinja2")
class BlogViews:
    def __init__(self, request):
        self.request = request

    @view_config(route_name="blog_list")
    def list(self):
        return {"posts": ...}

    @view_config(route_name="blog_add", request_method="POST")
    def add(self):
        ...
```

## URL dispatch (routes)

Register ordered routes; **first match wins**, so declare specific patterns before
general ones.

```python
config.add_route("home", "/")
config.add_route("user", "/users/{id}")               # {id} = [^/]+, one segment
config.add_route("num", "/items/{id:\\d+}")           # regex-constrained
config.add_route("file", "/files/{path:.*}")          # greedy remainder (regex)
config.add_route("rest", "/tree/*traverse")           # route + traversal hybrid
```

Captured values arrive in `request.matchdict` as decoded strings:

```python
@view_config(route_name="user", renderer="json")
def user(request):
    return {"id": request.matchdict["id"]}
```

### Route/view predicates (narrow when a view applies)

Pass to `add_route` or `@view_config`:

- `request_method="POST"` (or a tuple)
- `request_param="format=json"`
- `accept="application/json"` (content negotiation)
- `header`, `xhr=True`, `path_info=`, `match_param="action=edit"`
- `physical_path`, `effective_principals`, custom predicates via `add_view_predicate`

More specific predicate sets win. If two views tie, you get a
`ConfigurationConflictError`.

### Generating URLs (never hardcode)

```python
request.route_url("user", id=42)      # http://host/users/42  (absolute)
request.route_path("user", id=42)     # /users/42             (relative)
request.route_url("user", id=42, _query={"tab": "x"}, _anchor="c")
request.static_url("myproject:static/app.css", request)
```

## Traversal (the other mode)

Instead of a route table, a tree of **resource** objects is walked from a root
factory; each path segment does `__getitem__`. The final resource is the `context`;
the leftover name is the `view_name`. Views are matched on `context` type
(`context=Folder`) and `name=`. Good for CMS-like, arbitrarily nested, per-object
security (ACLs live on resources). Hybrid apps use `*traverse` in a route pattern.
Use URL dispatch unless the data is naturally a tree.

## Renderers

The `renderer=` argument decides how a view's return value becomes a Response.
Built-in: `"json"`, `"string"`, and any registered template
(`"pkg:templates/x.jinja2"`, `.pt`, `.mako`). Returning a dict + a template renderer
is the most testable pattern (assert on the dict, not parsed HTML).

```python
@view_config(route_name="api", renderer="json")
def api(request):
    request.response.status = 201                 # tweak the response object
    return {"ok": True}
```

- JSON renderer: customize with `config.add_renderer` or an adapter via
  `config.add_json_adapter` (e.g. for `datetime`/`Decimal`).
- Access the pending response in any renderer-using view via `request.response`
  (set `.status`, `.headers`, `.content_type`, cookies).

## Templates

Enable a binding, then reference templates as asset specs:

```python
config.include("pyramid_jinja2")        # .jinja2   (starter default)
# config.include("pyramid_chameleon")   # .pt  ZPT
# config.include("pyramid_mako")         # .mako/.mak
```

```python
@view_config(route_name="home", renderer="myproject:templates/home.jinja2")
def home(request):
    return {"title": "Home"}
```

System values available in every template: `request`, `context`, `view`,
`renderer_name`, `renderer_info`, and `get_csrf_token()`.

Render outside the view config when needed:

```python
from pyramid.renderers import render, render_to_response

html = render("myproject:templates/mail.jinja2", {"x": 1}, request=request)
resp = render_to_response("myproject:templates/home.jinja2", {"x": 1}, request=request)
```

Build asset/static URLs in templates with `request.static_url(...)` and
`request.route_url(...)` so paths survive mount-point/proxy changes.

## Static assets

```python
config.add_static_view(name="static", path="myproject:static", cache_max_age=3600)
# template: {{ request.static_url('myproject:static/app.css') }}
```

## Errors & special views

```python
from pyramid.view import notfound_view_config, forbidden_view_config, exception_view_config
from pyramid.httpexceptions import HTTPNotFound, HTTPFound

@notfound_view_config(renderer="myproject:templates/404.jinja2")
def notfound(request):
    request.response.status = 404
    return {}

@view_config(route_name="old")
def redirect(request):
    return HTTPFound(location=request.route_url("home"))   # raise or return

@exception_view_config(ValueError, renderer="json")
def handle_valueerror(exc, request):
    request.response.status = 400
    return {"error": str(exc)}
```

HTTP exceptions in `pyramid.httpexceptions` (`HTTPFound`, `HTTPNotFound`,
`HTTPForbidden`, `HTTPBadRequest`, …) are both exceptions **and** responses — raise
them to short-circuit or return them directly.

## Events (request lifecycle hooks)

```python
from pyramid.events import subscriber, NewRequest, BeforeRender

@subscriber(NewRequest)
def on_new_request(event):
    event.request.start_time = ...          # add per-request state

@subscriber(BeforeRender)
def add_globals(event):
    event["site_name"] = "MySite"           # inject into every template
```

Other useful events: `ApplicationCreated`, `NewResponse`, `ContextFound`,
`BeforeTraversal`. `config.scan()` activates `@subscriber`.
