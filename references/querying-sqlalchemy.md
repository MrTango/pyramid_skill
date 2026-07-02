# Database Queries with SQLAlchemy — Deep Dive & Best Practices

Scope: querying data with SQLAlchemy **2.0** inside a Pyramid app, where the ORM
session is `request.dbsession` and transactions are managed by `pyramid_tm`
(see `references/models-and-data.md` for the wiring). This file is about **how to
write good queries**, not how to define models.

> **Golden rules**
> 1. Use the **2.0 `select()` style** (`session.execute(...)` / `session.scalars(...)`),
>    not the legacy `session.query(...)`. New code should be 2.0-native.
> 2. **Never** build SQL by string-formatting user input — use bound parameters
>    (which the expression language does automatically). This prevents SQL injection.
> 3. **Never** call `session.commit()` in a view — `pyramid_tm` owns the transaction.
>    Use `dbsession.flush()` when you need generated ids mid-request.
> 4. Assume every relationship access can emit a query — design against **N+1**.

---

## 1. The 2.0 query pattern (learn this first)

A query is a `select()` construct that you execute against the session. Execution
returns a `Result`; the session's `scalars()` helper unwraps single-entity rows.

```python
from sqlalchemy import select
from ..models import User

# Build a statement (no DB access yet — it's just an object you can compose/pass around)
stmt = select(User).where(User.active.is_(True)).order_by(User.name)

# Execute + get ORM entities. THREE common shapes:
users = request.dbsession.scalars(stmt).all()          # list[User]
user  = request.dbsession.scalars(stmt).first()        # User | None
users = list(request.dbsession.scalars(stmt))          # iterate/stream
```

`execute()` vs `scalars()`:

```python
# execute() -> Result of Row tuples. Use when selecting columns or multiple entities.
rows = request.dbsession.execute(
    select(User.id, User.email).where(User.active.is_(True))
).all()                                     # list[Row]; rows[0].id, rows[0].email

# scalars() -> ScalarResult, unwraps the first column of each row.
emails = request.dbsession.scalars(select(User.email)).all()   # list[str]
users  = request.dbsession.scalars(select(User)).all()         # list[User]
```

### Result accessors (know exactly what each does)

| Call | Returns | Raises |
|---|---|---|
| `.all()` | list of everything | — |
| `.first()` | first row or `None` (silently ignores extras) | — |
| `.one()` | exactly one | `NoResultFound` / `MultipleResultsFound` |
| `.one_or_none()` | one or `None` | `MultipleResultsFound` if >1 |
| `.scalar_one()` | first column of the one row | same as `.one()` |
| `.scalar_one_or_none()` | first column or `None` | `MultipleResultsFound` |
| `.partitions(n)` / `yield_per` | server-side batches | — |

```python
# Fetch-or-404 by primary key — prefer session.get() (uses identity map / cache):
user = request.dbsession.get(User, user_id)
if user is None:
    raise HTTPNotFound()

# Fetch-or-404 by non-PK, unambiguous:
user = request.dbsession.scalars(
    select(User).where(User.email == email)
).one_or_none()
```

`session.get(Entity, pk)` is the idiomatic primary-key lookup — it checks the
identity map first and can avoid a round trip. Use `select().where()` for
everything else.

---

## 2. Filtering (WHERE)

`.where()` chains with **AND**. Use the column operators and the `and_`/`or_`/`not_`
helpers for anything non-trivial. All values become **bound parameters** — safe.

```python
from sqlalchemy import select, and_, or_, not_, func

select(Post).where(Post.author_id == uid, Post.published.is_(True))   # AND of both
select(Post).where(or_(Post.title.ilike("%pyramid%"),
                       Post.body.ilike("%pyramid%")))
select(Post).where(Post.status.in_(["draft", "review"]))
select(Post).where(Post.tag.is_(None))                # IS NULL  (never == None)
select(Post).where(Post.views.between(10, 100))
select(Post).where(func.lower(Post.slug) == slug.lower())
```

Operator cheat sheet: `==`, `!=`, `<`, `>`, `<=`, `>=`, `.in_(...)`,
`.not_in(...)`, `.is_(None)`, `.is_not(None)`, `.like(...)`, `.ilike(...)`,
`.between(a, b)`, `.startswith(...)`, `.contains(...)`, `~` (negate).

**Dynamic filters** — build a list and splat it, don't concatenate SQL strings:

```python
conditions = []
if q := request.params.get("q"):
    conditions.append(Post.title.ilike(f"%{q}%"))     # value is bound, not injected
if author := request.params.get("author"):
    conditions.append(Post.author_id == int(author))
stmt = select(Post).where(*conditions).order_by(Post.created.desc())
```

Relationship-aware filters without an explicit join:

```python
select(User).where(User.addresses.any(Address.city == "Berlin"))   # one-to-many -> EXISTS
select(Address).where(Address.user.has(User.active.is_(True)))     # many-to-one -> EXISTS
```

---

## 3. Joins

```python
# Join along a relationship (ON clause inferred):
select(User).join(User.addresses).where(Address.city == "Berlin")

# Join to an entity (ON inferred from FKs; errors if ambiguous):
select(User).join(Address)

# Explicit ON:
select(User).join(Address, Address.user_id == User.id)

# LEFT OUTER JOIN:
select(User).outerjoin(User.addresses)

# Set the left side explicitly:
select(Address.email).join_from(User, User.addresses)

# Multiple entities in the result:
for row in request.dbsession.execute(
    select(User, Address).join(User.addresses)
):
    print(row.User.name, row.Address.email)
```

Self-joins / joining the same table twice need `aliased`:

```python
from sqlalchemy.orm import aliased
Manager = aliased(User)
select(User.name, Manager.name).join(Manager, User.manager_id == Manager.id)
```

> A `.join()` used only to filter does **not** populate relationship collections.
> If you both filter on a join and want the related rows loaded, pair it with
> `contains_eager` (see §6) — otherwise you get the join *and* a second lazy load.

---

## 4. Ordering, limit, and pagination

```python
select(Post).order_by(Post.created.desc(), Post.id.desc())
select(Post).limit(20).offset(40)
```

**Offset pagination** (simple, fine for small/medium offsets):

```python
def paginate(dbsession, stmt, page, per_page=20):
    total = dbsession.scalar(select(func.count()).select_from(stmt.subquery()))
    items = dbsession.scalars(
        stmt.limit(per_page).offset((page - 1) * per_page)
    ).all()
    return items, total
```

**Keyset / "seek" pagination** (scales — no growing OFFSET cost). Order by a unique,
indexed column and carry the last seen value:

```python
stmt = select(Post).order_by(Post.id.desc()).limit(per_page)
if after_id is not None:
    stmt = stmt.where(Post.id < after_id)
```

Prefer keyset pagination for infinite scroll / large tables; deep `OFFSET` forces
the DB to scan and discard rows.

---

## 5. Aggregates & scalars

```python
from sqlalchemy import func

# Count rows CORRECTLY — count on the DB, never len(scalars(...).all()):
n_active = request.dbsession.scalar(
    select(func.count()).select_from(User).where(User.active.is_(True))
)

# Group by + having:
rows = request.dbsession.execute(
    select(User.country, func.count(Post.id).label("posts"))
    .join(User.posts)
    .group_by(User.country)
    .having(func.count(Post.id) > 5)
    .order_by(func.count(Post.id).desc())
).all()                                  # [Row(country=..., posts=...), ...]

# Single scalar value:
newest = request.dbsession.scalar(select(func.max(Post.created)))
```

`session.scalar(stmt)` = "execute and return the first column of the first row (or
None)" — perfect for counts/max/exists.

**Existence check** (cheaper than counting — the DB can stop at the first match):

```python
from sqlalchemy import exists
has_any = request.dbsession.scalar(
    select(exists().where(Post.author_id == uid))
)                                        # -> True / False
```

---

## 6. Relationship loading & the N+1 problem (the big one)

By default relationships are **lazy**: accessing `user.addresses` emits a SELECT
the first time. Loop over 100 users touching `.addresses` → 1 + 100 queries. This
is the #1 SQLAlchemy performance bug. Fix it with eager-loading `options()`.

```python
from sqlalchemy.orm import selectinload, joinedload, contains_eager, raiseload

# Collections (one-to-many / many-to-many): prefer selectinload.
users = request.dbsession.scalars(
    select(User).options(selectinload(User.addresses))
).all()                                   # 2 queries total, regardless of N

# Scalar many-to-one references: prefer joinedload (single JOIN, no extra round trip).
posts = request.dbsession.scalars(
    select(Post).options(joinedload(Post.author))
).all()

# joinedload on a COLLECTION multiplies rows — you MUST de-dupe with .unique():
users = request.dbsession.scalars(
    select(User).options(joinedload(User.addresses))
).unique().all()

# Nested / chained eager loading:
select(User).options(
    selectinload(User.posts).joinedload(Post.category)
)

# You already joined for filtering and want those rows in the collection:
select(User).join(User.addresses).where(Address.city == "Berlin") \
    .options(contains_eager(User.addresses))
```

Strategy selection:

| Situation | Use |
|---|---|
| one-to-many / many-to-many collection | `selectinload` (default choice) |
| many-to-one / one-to-one scalar | `joinedload` |
| reuse an existing explicit join | `contains_eager` |
| forbid accidental lazy loads | `raiseload("*")` |

**Guard against N+1 in dev**: add `raiseload("*")` (or per-relationship
`raiseload`) so any un-eager-loaded access raises instead of silently issuing
queries — turn latent N+1 into a loud error in tests.

```python
select(Post).options(joinedload(Post.author), raiseload("*"))
```

You can also set a default at mapping time: `relationship(..., lazy="selectin")`.
Use `lazy="raise"` on relationships that must always be loaded explicitly.

> Beware lazy loads **after the request transaction commits**: with pyramid_tm the
> transaction commits at the end of the request and objects expire. Anything you
> render must be loaded *during* the request. Don't stash ORM objects for use in a
> later request — store ids and re-query.

---

## 7. Loading only the columns you need

```python
from sqlalchemy.orm import load_only, defer, undefer

# Load just a few columns (others become deferred / lazy):
select(User).options(load_only(User.id, User.name))

# Defer an expensive column (e.g. a large TEXT/BLOB) until accessed:
select(Post).options(defer(Post.body))

# Select raw columns when you don't need entities at all — cheapest:
request.dbsession.execute(select(User.id, User.name)).all()
```

For read-only list/table views, selecting columns (not full entities) avoids ORM
identity-map and instrumentation overhead.

---

## 8. Writes: insert / update / delete

Within a request, mutate through the session; `pyramid_tm` commits on success.

```python
# INSERT — add and (optionally) flush to get the generated PK:
post = Post(title="Hi", author_id=uid)
request.dbsession.add(post)
request.dbsession.flush()          # emits INSERT now; post.id is populated
new_id = post.id                   # available without committing

# Bulk add:
request.dbsession.add_all([Post(title=t) for t in titles])

# ORM-enabled bulk UPDATE / DELETE (one statement, no per-row Python):
from sqlalchemy import update, delete
request.dbsession.execute(
    update(Post).where(Post.author_id == uid).values(published=True)
)
request.dbsession.execute(
    delete(Post).where(Post.created < cutoff)
)

# RETURNING (Postgres, SQLite 3.35+, etc.):
new = request.dbsession.execute(
    insert(Post).values(title="x").returning(Post.id)
).scalar_one()
```

- `flush()` sends pending SQL **without** committing — use it to obtain autogenerated
  ids or to make writes visible to a later query in the same request. `pyramid_tm`
  still decides commit vs rollback at request end.
- Bulk `update()`/`delete()` bypass Python-level ORM cascades/events and by default
  don't refresh in-session objects. Pass
  `execution_options(synchronize_session="fetch")` (or `"evaluate"`) if you must
  keep already-loaded objects consistent within the same request.
- To force a rollback while returning a normal response, `import transaction;
  transaction.doom()` / `transaction.abort()` — but usually raising an HTTP error
  is cleaner and lets pyramid_tm abort for you.

---

## 9. Transactions & retries (Pyramid specifics)

- One transaction per request. Success (status < 400) → commit; exception or 4xx/5xx
  → abort. You rarely touch the transaction manager directly.
- Enable **`pyramid_retry`** (the SQLAlchemy starter does) so requests that fail with
  a transient serialization/deadlock error are retried. This means a request body may
  run **more than once** — keep view logic idempotent and avoid side effects before
  the DB work (or use `pyramid_retry`'s `mark_error_retryable` / `IBeforeRetry`).
- Need multiple independent commits in one request (rare, e.g. a long job)? Use an
  explicit nested transaction manager rather than calling `session.commit()`.

---

## 10. Raw SQL when you truly need it

Escape hatch for DB-specific SQL — still parameterized:

```python
from sqlalchemy import text
rows = request.dbsession.execute(
    text("SELECT id, name FROM users WHERE created > :since"),
    {"since": since},                      # bound param — NOT f-string interpolation
).all()
```

Never `text(f"... {user_input} ...")`. Bind every value with `:name` params.

---

## 11. Debugging & inspecting queries

```ini
# development.ini — log every statement + params:
[logger_sqlalchemy]
level = INFO        ; INFO = SQL, DEBUG = SQL + result rows
handlers =
qualname = sqlalchemy.engine
```

```python
print(stmt)                                  # rendered SQL (with :params)
print(stmt.compile(compile_kwargs={"literal_binds": True}))   # inline values (debug only!)
```

Watch the SQL log while developing a view — a burst of near-identical SELECTs is the
signature of an N+1 you should fix with `selectinload`/`joinedload`. Use the
**pyramid_debugtoolbar** "SQLAlchemy" panel to see per-request query counts and timing.

---

## 12. Pyramid integration patterns (querying *in* a Pyramid app)

This is the part that ties SQLAlchemy to Pyramid. The pieces:
`request.dbsession` (request-scoped session), `pyramid_tm` (one transaction per
request), `config.scan()` views, renderers, routes, and — optionally — traversal.

### 12.1 Keep views thin: put queries in a query module

Don't scatter `select()` statements across view functions. Centralize them so they
are reusable, unit-testable, and easy to optimize (add eager-loading in one place).

```python
# myproject/queries.py  — pure functions: (dbsession, params) -> data
from sqlalchemy import select, func
from sqlalchemy.orm import selectinload
from .models import Post


def recent_posts(dbsession, limit=20):
    return dbsession.scalars(
        select(Post)
        .options(selectinload(Post.tags))       # eager-load once, here
        .order_by(Post.created.desc())
        .limit(limit)
    ).all()


def post_by_slug(dbsession, slug):
    return dbsession.scalars(
        select(Post).where(Post.slug == slug)
    ).one_or_none()


def post_count(dbsession):
    return dbsession.scalar(select(func.count()).select_from(Post))
```

```python
# myproject/views/blog.py — the view just wires HTTP <-> queries <-> renderer
from pyramid.view import view_config
from pyramid.httpexceptions import HTTPNotFound
from .. import queries


@view_config(route_name="blog", renderer="myproject:templates/blog.jinja2")
def blog(request):
    return {"posts": queries.recent_posts(request.dbsession)}


@view_config(route_name="post", renderer="myproject:templates/post.jinja2")
def post(request):
    obj = queries.post_by_slug(request.dbsession, request.matchdict["slug"])
    if obj is None:
        raise HTTPNotFound()
    return {"post": obj}
```

Views stay trivial; the query layer is where you tune SQL and prevent N+1.

### 12.2 Expose queries as `request` methods (optional, ergonomic)

For queries you use everywhere, attach a helper to the request alongside
`request.dbsession`, in your models/queries `includeme`:

```python
def includeme(config):
    config.add_request_method(
        lambda request: request.dbsession.get(User, request.authenticated_userid),
        "user",
        reify=True,          # computed once per request, then cached
    )
```

Now any view/template can use `request.user` (one query per request, cached).
`reify=True` is the key: it memoizes the result for the life of the request.

### 12.3 End-to-end list view with pagination + `route_url`

```python
# queries.py
def posts_page(dbsession, page, per_page=20):
    total = dbsession.scalar(select(func.count()).select_from(Post))
    items = dbsession.scalars(
        select(Post).order_by(Post.created.desc())
        .limit(per_page).offset((page - 1) * per_page)
    ).all()
    return items, total
```

```python
# views/blog.py
@view_config(route_name="blog", renderer="myproject:templates/blog.jinja2")
def blog(request):
    page = max(1, int(request.params.get("page", 1)))
    items, total = queries.posts_page(request.dbsession, page)
    return {
        "posts": items,
        "page": page,
        "has_next": page * 20 < total,
        # build URLs with route_url, never hardcode:
        "next_url": request.route_url("blog", _query={"page": page + 1}),
    }
```

Coerce/validate `request.params` (they are strings and user-controlled) *before*
they reach a query — `int(...)` in a `try`, clamp ranges, whitelist sort columns.

### 12.4 Traversal: make the DB row the `context`

In a traversal app, a resource factory loads the object by id; the loaded ORM
object becomes `request.context`, and a missing row is a natural 404. This puts the
query at the edge and lets views/ACLs work on the object directly.

```python
# resources.py
from pyramid.httpexceptions import HTTPNotFound
from .models import Post


class PostResource:
    def __init__(self, request):
        self.request = request

    def __getitem__(self, key):
        post = self.request.dbsession.get(Post, int(key))   # /posts/{id}
        if post is None:
            raise HTTPNotFound()
        post.__parent__ = self          # location-aware -> ACL inheritance works
        post.__name__ = key
        return post
```

```python
# a view matched on the loaded context type — no re-query needed
@view_config(context=Post, renderer="myproject:templates/post.jinja2")
def post_view(context, request):
    return {"post": context}           # context IS the Post row
```

Use this when objects form a tree and you want per-object security (§12.5); use
plain URL-dispatch + a query module (§12.1) otherwise.

### 12.5 Row-level authorization: filter querysets by principal

Object permissions come from ACLs (see `references/security.md`), but *list*
queries must be filtered in SQL — never load everything and filter in Python.
Push the security predicate into the `WHERE` clause:

```python
def visible_posts(dbsession, request):
    stmt = select(Post).order_by(Post.created.desc())
    if "group:editors" not in request.effective_principals:
        stmt = stmt.where(Post.published.is_(True))     # non-editors see only published
    if uid := request.authenticated_userid:
        stmt = stmt.where(or_(Post.published.is_(True), Post.author_id == uid))
    return dbsession.scalars(stmt).all()
```

This keeps authorization and pagination consistent (you can't paginate correctly if
you filter after the query).

### 12.6 Transactions & retries — recap for query code

- The session is committed by `pyramid_tm` at request end; **don't** `commit()`.
  `flush()` only when you need a generated id mid-request (§8).
- With `pyramid_retry` enabled, a view (and its queries/writes) may run **more than
  once** on a transient DB conflict. Keep the view idempotent; do external side
  effects (emails, payments) *after* the DB work commits, e.g. from a
  `transaction` after-commit hook, not inline.

### 12.7 Debugging & testing queries in Pyramid

- **pyramid_debugtoolbar** → "SQLAlchemy" panel shows every statement, params, and
  count for the request — the fastest way to spot an N+1 in a real view.
- **`pshell development.ini`** drops you into a shell with `request` and the app
  registry loaded, so you can iterate on `select()` statements against the real DB.
- **Tests** use the starter's `dbsession`/`tm` fixtures (transaction rolled back per
  test — see `references/testing.md`). Test query functions directly, and assert
  query *counts* to lock in N+1 fixes:

```python
def test_recent_posts_is_two_queries(dbsession):
    from sqlalchemy import event
    from myproject import queries
    dbsession.add_all([Post(title=f"p{i}", slug=str(i)) for i in range(5)])
    dbsession.flush()

    count = 0
    engine = dbsession.get_bind()

    @event.listens_for(engine, "before_cursor_execute")
    def _(*a, **k):
        nonlocal count
        count += 1

    posts = queries.recent_posts(dbsession)         # selectinload tags
    for p in posts:                                  # touch the relationship
        _ = p.tags
    assert count <= 2                                # 1 for posts + 1 selectin, no N+1
```

---

## 13. Deferred execution & async

### 13.1 Never run queries at import / config time

Statement construction is **lazy** — building a `select()` does not touch the
database. Execution only happens when you call `execute()` / `scalars()` /
`scalar()` on a session. Keep it that way: **no query should run at module import,
at `Configurator` setup, or from a module-global session.**

```python
# BAD — runs at import; no request, no transaction, connects too early,
#       and the result is frozen for the life of the process.
from .models import Session, User          # a module-global Session
ADMINS = Session().scalars(select(User).where(User.is_admin)).all()   # <-- executes on import!

# BAD — query at Configurator/main() time.
def main(global_config, **settings):
    engine = get_engine(settings)
    engine.execute(text("SELECT 1"))        # don't hit the DB while wiring the app

# GOOD — a deferred function that runs per request, against request.dbsession.
def admins(dbsession):
    return dbsession.scalars(select(User).where(User.is_admin.is_(True))).all()
```

Why this matters in Pyramid specifically:

- Views/queries must run **inside** the request so `pyramid_tm` owns the transaction
  and `request.dbsession` is the right request-scoped session. A query at import
  time has neither.
- `engine_from_config()` / `get_engine()` build an engine but **do not connect** —
  connections are opened lazily on first use. So creating the engine in `main()` is
  fine; *querying* through it there is not.
- Schema creation (`Base.metadata.create_all`) belongs in the `initialize_db`
  script or test fixtures — never at import.
- Query helpers take `dbsession` as an argument (§12.1); they don't close over a
  global session. This is what makes them safe to import and easy to test.

Rule of thumb: **importing any module in your package must not emit SQL.** If it
does, you have a query executing at import time — move it into a function.

### 13.2 Async SQLAlchemy and Pyramid — read this before reaching for it

**Pyramid 2.x is a WSGI, synchronous framework.** Its router invokes view callables
synchronously — there is no native `async def` view support — and the standard data
stack (`pyramid_tm` + `zope.sqlalchemy` + `request.dbsession`) is **sync-only**. It
does **not** drive a SQLAlchemy `AsyncSession`. So the patterns everywhere else in
this file (sync `request.dbsession`) are the supported, recommended path for Pyramid.

If you genuinely need SQLAlchemy's asyncio API, understand the trade-offs:

- You **lose the pyramid_tm / zope.sqlalchemy integration** and must open, commit,
  rollback, and close the `AsyncSession` yourself (no automatic per-request
  transaction, no `pyramid_retry` on the async session).
- Pyramid can't `await` a view, so you bridge one of two ways, both with costs:
  1. Run the coroutine from a sync view with `anyio.from_thread` / a persistent
     event loop (a per-request `asyncio.run()` spins up and tears down a loop every
     request — avoid). Under a threaded WSGI server (waitress) this blocks a worker
     thread anyway, so you get async SQLAlchemy's API but **not** its concurrency win.
  2. Serve the app under ASGI (e.g. wrap with `a2wsgi`), which still doesn't make
     Pyramid views awaitable — it just changes the server protocol.
- **Lazy loading does not work under async** — accessing an unloaded relationship
  raises. You must eager-load (`selectinload`/`joinedload`) every relationship, use
  `AsyncAttrs` (`await obj.awaitable_attrs.rel`), or `await session.refresh(obj, [...])`.

Sketch, if you accept all of the above (note: transactions are manual, not pyramid_tm):

```python
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker
from sqlalchemy.orm import selectinload

engine = create_async_engine(settings["sqlalchemy.url"])   # e.g. postgresql+asyncpg://...
AsyncSession = async_sessionmaker(engine, expire_on_commit=False)

async def recent_posts(limit=20):
    async with AsyncSession() as session:      # you manage the lifecycle/txn here
        result = await session.scalars(
            select(Post)
            .options(selectinload(Post.tags))   # MUST eager-load; no lazy under async
            .order_by(Post.created.desc())
            .limit(limit)
        )
        return result.all()
```

Note the async engine/sessionmaker above are created **at module load, but no query
runs** — §13.1 still holds. The first SQL is emitted only inside `recent_posts()`.

Practical guidance: **for a Pyramid app, stay synchronous** with `request.dbsession`
and let `pyramid_tm` manage transactions. If your workload is genuinely async-first
(lots of concurrent I/O-bound calls), that's a signal to use an async-native
framework (FastAPI/Starlette) rather than bolting `AsyncSession` onto WSGI Pyramid.
Reserve async in Pyramid for isolated, self-managed tasks (e.g. a background script)
where you own the event loop and the session lifecycle.

---

## 14. Best-practices checklist

- [ ] 2.0 `select()` + `session.scalars()/execute()`; not legacy `session.query()`.
- [ ] Primary-key lookups via `session.get(Model, pk)`.
- [ ] All user input passed as bound params / expression values — no string SQL.
- [ ] Every relationship touched in a loop or template is eager-loaded
      (`selectinload` for collections, `joinedload` for scalars).
- [ ] `raiseload("*")` in tests/dev to catch N+1 regressions.
- [ ] Counts via `select(func.count())` on the DB, never `len(...all())`.
- [ ] List views select only needed columns (`load_only` / column selects) and
      paginate (keyset for large tables).
- [ ] No `session.commit()` in views; `flush()` only for generated ids.
- [ ] Views are idempotent enough to survive a `pyramid_retry` re-run.
- [ ] Indexes exist for every column used in `WHERE`/`ORDER BY`/join keys.
- [ ] SQL logging or the debugtoolbar checked for query count/latency before shipping.
- [ ] Bulk `update()`/`delete()` for set-based changes instead of per-row loops.
- [ ] Query logic lives in a query module / model methods, not inline in views.
- [ ] `request.params`/`matchdict` values validated & coerced before hitting a query.
- [ ] List queries filter by principal in SQL for row-level auth (not in Python).
- [ ] No SQL emitted at import / `main()` time — queries run only inside a request
      via `request.dbsession` (statements are built lazily, executed on demand).
- [ ] Async (`AsyncSession`) used only with eyes open: Pyramid is WSGI/sync, so it
      bypasses `pyramid_tm`/`zope.sqlalchemy` and needs manual transaction handling
      and mandatory eager loading — default to sync `request.dbsession`.
