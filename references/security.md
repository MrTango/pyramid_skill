# Security: Policy, Auth, Permissions, CSRF, Sessions

**Pyramid 2.x uses a single security policy** implementing `ISecurityPolicy`.
This replaced the older split of *authentication policy* + *authorization policy*.
If you see `config.set_authentication_policy(...)` /
`config.set_authorization_policy(...)` in tutorials, that is the **legacy** API —
port it to a single `set_security_policy`.

By default Pyramid enables **no** security policy: every view is anonymous and
permissions are ignored until you install one and attach permissions.

## The security policy interface

```python
from pyramid.authentication import AuthTktCookieHelper
from pyramid.authorization import ACLHelper, Authenticated, Everyone


class MySecurityPolicy:
    def __init__(self, secret):
        self.authtkt = AuthTktCookieHelper(secret)
        self.acl = ACLHelper()

    def identity(self, request):
        # Return an app-specific identity object (or None). Cache/reify as needed.
        ident = self.authtkt.identify(request)
        if ident is None:
            return None
        userid = ident["userid"]
        return request.dbsession.query(User).get(userid)   # your User or None

    def authenticated_userid(self, request):
        user = self.identity(request)
        return str(user.id) if user is not None else None

    def permits(self, request, context, permission):
        principals = self.effective_principals(request)
        return self.acl.permits(context, principals, permission)  # Allowed/Denied

    def effective_principals(self, request):
        principals = [Everyone]
        user = self.identity(request)
        if user is not None:
            principals += [Authenticated, f"user:{user.id}"]
            principals += [f"group:{g}" for g in user.groups]
        return principals

    def remember(self, request, userid, **kw):
        return self.authtkt.remember(request, userid, **kw)   # headers

    def forget(self, request, **kw):
        return self.authtkt.forget(request, **kw)             # headers
```

Install it and set a secure default:

```python
config.set_security_policy(MySecurityPolicy(settings["auth.secret"]))
config.set_default_permission("view")     # secure-by-default: everything needs 'view'
```

Required methods: `identity`, `authenticated_userid`, `permits`, `remember`,
`forget`. `effective_principals` is a helper you call from `permits` (not part of
the formal 2.x interface but conventional). Built-in helpers you compose with:
`AuthTktCookieHelper` (signed cookie) and `SessionAuthenticationHelper`
(server-side session).

## Protecting views with permissions

```python
@view_config(route_name="admin", permission="edit")
def admin(request):
    ...
```

When a request hits this view, the policy's `permits(request, context, "edit")`
runs. `Denied` → Pyramid raises `HTTPForbidden`, invoking your forbidden view.

## ACLs (context-based authorization)

An ACL is a list of `(action, principal, permission)` ACEs on the **context**
object (a resource in traversal, or a route's `factory=`). First matching ACE wins.

```python
from pyramid.authorization import Allow, Deny, Everyone, Authenticated, ALL_PERMISSIONS


class Root:
    __acl__ = [
        (Allow, Everyone, "view"),
        (Allow, "group:editors", "edit"),
        (Allow, "group:admins", ALL_PERMISSIONS),
        (Deny, "user:banned", ALL_PERMISSIONS),
    ]

    def __init__(self, request):
        self.request = request
```

Attach a root/context factory:

```python
config.add_route("admin", "/admin", factory=".resources.Root")
# or a global default:
config.set_root_factory(".resources.Root")
```

ACLs inherit up the resource tree via `__parent__` (location-aware objects); use
`NO_PERMISSION_REQUIRED` to punch a hole for a specific view (e.g. the login page).

## Login / logout views

```python
from pyramid.httpexceptions import HTTPFound
from pyramid.security import remember, forget    # or use policy methods

@view_config(route_name="login", renderer="myproject:templates/login.jinja2",
             permission=NO_PERMISSION_REQUIRED)
def login(request):
    if request.method == "POST":
        user = authenticate(request.POST["login"], request.POST["password"])
        if user is not None:
            headers = request.security_policy.remember(request, str(user.id))
            return HTTPFound(location=request.route_url("home"), headers=headers)
    return {}

@view_config(route_name="logout")
def logout(request):
    headers = request.security_policy.forget(request)
    return HTTPFound(location=request.route_url("home"), headers=headers)
```

Always hash passwords (e.g. `bcrypt`/`argon2`); never store plaintext.

## CSRF protection

```python
from pyramid.csrf import SessionCSRFStoragePolicy   # or CookieCSRFStoragePolicy

config.set_csrf_storage_policy(SessionCSRFStoragePolicy())
config.set_default_csrf_options(require_csrf=True)   # enforce on unsafe methods
```

With `require_csrf=True`, POST/PUT/DELETE/PATCH must carry a valid token
(`csrf_token` form field or `X-CSRF-Token` header); Pyramid raises
`BadCSRFToken` otherwise. In templates:

```jinja2
<form method="post">
  <input type="hidden" name="csrf_token" value="{{ get_csrf_token() }}">
</form>
```

Check manually when needed: `from pyramid.csrf import check_csrf_token`. Pyramid
also validates the request Origin/Referer against trusted domains on HTTPS.

## Sessions

CSRF and flash messages need a session factory. Pyramid ships a signed-cookie
factory; for production prefer a server-side store (redis/db) add-on.

```python
from pyramid.session import SignedCookieSessionFactory
config.set_session_factory(SignedCookieSessionFactory(settings["session.secret"]))
```

```python
request.session["k"] = "v"
request.session.flash("Saved!")            # pop in template with request.session.pop_flash()
```

## Checklist

- [ ] Install **one** `set_security_policy` (not the legacy auth+authz pair).
- [ ] `set_default_permission` or per-view `permission=` — no unprotected mutating views.
- [ ] `NO_PERMISSION_REQUIRED` only where intentional (login, health check).
- [ ] CSRF storage policy + `set_default_csrf_options(require_csrf=True)`.
- [ ] Secrets (`auth.secret`, `session.secret`) come from env/`.ini`, never hardcoded.
- [ ] Passwords hashed with bcrypt/argon2; cookies `secure`/`httponly` in prod.
- [ ] Behind TLS in production so signed cookies aren't sniffable.
