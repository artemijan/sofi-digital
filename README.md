# Sofi

An e-commerce shop built on [django-oscar](https://django-oscar.readthedocs.io/).

Deliberately dependency-light: no external services are required to run it.

| Concern     | Choice                                                    |
| ----------- | --------------------------------------------------------- |
| Framework   | Django 5.2 + django-oscar 4.1                              |
| Database    | SQLite (WAL mode)                                          |
| Cache       | `LocMemCache` (in-process, in-memory)                      |
| Search      | Haystack + Whoosh (pure-Python, file-based index)          |
| Thumbnails  | easy-thumbnails                                            |
| Config      | `.env` via django-environ (gitignored)                     |
| Packaging   | uv (`pyproject.toml` + `uv.lock`)                          |

## Getting started

```bash
uv sync                                 # install dependencies
cp .env.example .env                    # then fill in SECRET_KEY etc.
uv run python manage.py migrate
uv run python manage.py oscar_populate_countries --initial-only
uv run python manage.py createsuperuser --noinput   # reads DJANGO_SUPERUSER_* from .env
uv run python manage.py rebuild_index --noinput
uv run python manage.py runserver
```

Generate a fresh `SECRET_KEY` with:

```bash
uv run python -c "from django.core.management.utils import get_random_secret_key as k; print(k())"
```

- Storefront — <http://127.0.0.1:8000/>
- Oscar dashboard — <http://127.0.0.1:8000/dashboard/>
- Django admin — <http://127.0.0.1:8000/admin/>

## Layout

```
config/          settings, urls, wsgi/asgi
templates/       project-wide template overrides (win over Oscar's own)
static/          project-wide static file overrides
media/           uploaded product images (gitignored)
whoosh_index/    search index (gitignored, rebuildable)
```

## Search

Haystack's Whoosh backend keeps a file-based index under `whoosh_index/`.
`HAYSTACK_SIGNAL_PROCESSOR` is set to `RealtimeSignalProcessor`, so saving a
product updates the index immediately — no cron job needed for development.

Rebuild from scratch at any time:

```bash
uv run python manage.py rebuild_index --noinput
```

Two Whoosh limitations worth knowing:

- **Query facets are not supported.** Oscar's default `price_range` facet is
  therefore removed in `OSCAR_SEARCH_FACETS`; field facets (`product_class`,
  `rating`) work fine.
- **Realtime indexing assumes a single writer.** Whoosh takes a file lock on
  write, so with multiple web workers you should switch
  `HAYSTACK_SIGNAL_PROCESSOR` to `haystack.signals.BaseSignalProcessor` and run
  `update_index` on a schedule instead.

## Caching

`LocMemCache` is per-process: each worker keeps its own copy and nothing is
shared. That is fine for development and single-process deployments. Cache
invalidation across workers needs a shared backend (Redis/Memcached) — swap the
`CACHES` block in `config/settings.py` when you get there.

## Customising Oscar

Oscar apps are used unforked. To override models, views, or forms in one, fork
it into the project first:

```bash
uv run python manage.py oscar_fork_app catalogue apps/
```

then replace the corresponding entry in `INSTALLED_APPS`. Template overrides do
not need a fork — put them in `templates/oscar/...` and they take precedence.

## Pinned versions

`django-treebeard` is pinned to `<6.0`: Oscar 4.1 builds its `Category` manager
with `CategoryQuerySet.as_manager()`, which Treebeard 6 rejects with a hard
`treebeard.E001` error. The matching warning is silenced in settings via
`SILENCED_SYSTEM_CHECKS`. Remove both once Oscar ships a Treebeard 6 compatible
manager.

`whoosh-reloaded` is used instead of the original `whoosh`, which is unmaintained
and emits `SyntaxWarning`s on modern Python.
