# pyramid-development — a Claude skill for the Pyramid web framework

A [Claude Code](https://claude.com/claude-code) skill for building, testing, and
deploying web applications and APIs with the [Pyramid](https://trypyramid.com)
Python web framework (Pylons Project, targeting **Pyramid 2.x**).

## What it covers

`SKILL.md` is the entry point (a router). It loads the right reference file on
demand:

| File | Topic |
|---|---|
| `references/getting-started.md` | Cookiecutter scaffold, project layout, `pserve`, venv, CLI cheat sheet |
| `references/configuration.md` | `Configurator`, imperative vs declarative config, `include`/`includeme`, settings, PasteDeploy `.ini` |
| `references/views-and-routing.md` | URL dispatch, traversal, view callables, renderers, templates, static assets, events, error views |
| `references/models-and-data.md` | SQLAlchemy + `pyramid_tm` + `zope.sqlalchemy`, `request.dbsession`, Alembic migrations, console scripts |
| `references/security.md` | Pyramid 2.x `ISecurityPolicy`, authentication, ACLs/permissions, CSRF, sessions |
| `references/testing.md` | `pytest`, `testing.setUp`/`DummyRequest`, `webtest` functional tests, transaction-rollback fixtures |
| `references/deployment.md` | `production.ini`, waitress/gunicorn, nginx, systemd, Docker, release checklist |
| `scripts/new_pyramid_project.sh` | One-shot scaffold into a fresh virtualenv |

## Using it

Install as a personal or project skill for Claude Code (place the directory under
`~/.claude/skills/` or your project's `.claude/skills/`). Claude activates it
automatically when a task mentions Pyramid, `pserve`, `development.ini`,
`@view_config`, the `Configurator`, and similar triggers.

Scaffold a new project directly:

```bash
scripts/new_pyramid_project.sh myapp
```

## Sources

Based on the official Pyramid documentation (v2.x narrative docs and the
`pyramid-cookiecutter-starter`) at
<https://docs.pylonsproject.org/projects/pyramid/en/latest/> and
<https://trypyramid.com/documentation.html>.
