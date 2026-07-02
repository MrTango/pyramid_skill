# Testing Pyramid Apps with pytest

Pyramid projects use `pytest`. The starter defines a `[testing]` extras group
(pytest, webtest, coverage) and a `tests/` package with unit + functional tests.

```bash
pip install -e ".[testing]"
pytest -q
pytest --cov -q          # coverage
```

## Two test styles

- **Unit / view tests** — call the view function directly with a fake request;
  fast, no server. Views that return dicts (renderer-based) are ideal: assert on
  the dict, not on rendered HTML.
- **Functional tests** — drive the real WSGI app through `webtest.TestApp`,
  exercising routing, renderers, middleware, and security end-to-end.

## Unit test with DummyRequest / testing.setUp

```python
import unittest
from pyramid import testing


class HomeViewTests(unittest.TestCase):
    def setUp(self):
        self.config = testing.setUp()          # sets up a testing registry
        self.config.add_route("home", "/")     # register anything the view needs

    def tearDown(self):
        testing.tearDown()

    def test_home(self):
        from myproject.views.default import home
        request = testing.DummyRequest()
        response = home(request)
        self.assertEqual(response["project"], "myproject")
```

`testing.setUp(settings=...)` returns a Configurator wired to a throwaway
registry; `testing.DummyRequest()` is a lightweight request you can populate
(`DummyRequest(params={...}, matchdict={...}, dbsession=fake)`).
`DummyResource` fakes a traversal context.

## pytest fixtures (conftest.py) — SQLAlchemy starter

The starter's `conftest.py` builds an app, a per-test transaction rolled back
after each test, and a `testapp` for functional tests:

```python
import pytest
import transaction
import webtest
from pyramid.paster import get_appsettings
from pyramid.scripting import prepare
from pyramid.testing import DummyRequest, setUp, tearDown

from myproject import main
from myproject.models import get_engine, get_session_factory, get_tm_session
from myproject.models.meta import Base


@pytest.fixture(scope="session")
def app_settings():
    return get_appsettings("testing.ini", name="main")


@pytest.fixture(scope="session")
def dbengine(app_settings):
    engine = get_engine(app_settings)
    Base.metadata.create_all(bind=engine)
    yield engine
    Base.metadata.drop_all(bind=engine)


@pytest.fixture(scope="session")
def app(app_settings, dbengine):
    return main({}, dbengine=dbengine, **app_settings)


@pytest.fixture
def testapp(app):
    return webtest.TestApp(app, extra_environ={"HTTP_HOST": "example.com"})


@pytest.fixture
def dbsession(app, tm):
    session_factory = app.registry["dbsession_factory"]
    return get_tm_session(session_factory, tm)


@pytest.fixture
def tm():
    tm = transaction.TransactionManager(explicit=True)
    tm.begin()
    tm.doom()                 # ensure the transaction can never commit
    yield tm
    tm.abort()                # roll back everything the test wrote
```

`main()` accepts an optional pre-built `dbengine` so tests share one engine.
Each test that uses `dbsession`/`tm` runs inside a doomed transaction that is
aborted on teardown — a clean DB every test, no manual cleanup.

## Functional test with testapp

```python
def test_home_page(testapp):
    res = testapp.get("/", status=200)
    assert b"Pyramid" in res.body


def test_add_requires_login(testapp):
    testapp.get("/admin", status=403)     # protected by permission


def test_create_and_read(testapp, dbsession):
    from myproject.models import MyModel
    dbsession.add(MyModel(name="x", value=1))
    dbsession.flush()
    res = testapp.get("/things/1", status=200)
    assert res.json["name"] == "x"
```

`testapp.get/post(url, status=NNN)` asserts the status code; `res.json`,
`res.body`, `res.forms` help inspect responses. For CSRF-protected POSTs, fetch
the form first and submit it (`res.forms[0].submit()`), or disable CSRF in
`testing.ini`.

## Tips

- Keep views thin and renderer-based → most logic is unit-testable without a server.
- Test security: assert 403 on protected routes when anonymous, 200 when logged in
  (set an identity via a test login or a stub security policy).
- Use `proutes`/`pviews`/`pshell` against `development.ini` to debug routing and
  view lookup interactively.
- Point tests at `testing.ini` (fast SQLite, debugtoolbar off, template reload off).
