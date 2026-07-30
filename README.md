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
uv run python manage.py seed_demo_data           # optional demo catalogue
uv run python manage.py runserver
```

Generate a fresh `SECRET_KEY` with:

```bash
uv run python -c "from django.core.management.utils import get_random_secret_key as k; print(k())"
```

- Storefront — <http://127.0.0.1:8000/>
- Oscar dashboard — <http://127.0.0.1:8000/dashboard/>
- Django admin — <http://127.0.0.1:8000/admin/>

## Demo catalogue

`seed_demo_data` creates seven products — three t-shirts, two pairs of boots and
two jackets — under `Clothing > {T-shirts, Boots, Jackets}`, each with a colour
and material attribute, a stock record priced in EUR, and a product image.

```bash
uv run python manage.py seed_demo_data           # create or update in place
uv run python manage.py seed_demo_data --reset   # delete demo products first
```

It is idempotent: products are matched on their `SOFI-*` UPC and updated rather
than duplicated, so it is safe to re-run.

The images are **generated locally** by `core/product_images.py` using Pillow —
flat garment illustrations on a neutral studio background. Nothing is
downloaded, so there is no network dependency and no image licensing to worry
about. Because `media/` is gitignored, re-running the command after a fresh
clone recreates the image files.

To use real photography instead, drop the files in and attach them via the Oscar
dashboard (`/dashboard/catalogue/`), or replace the `_set_image` step in
`core/management/commands/seed_demo_data.py`.

## Layout

```
config/          settings, urls, wsgi/asgi
core/            project app: management commands, image generation
static/sofi/     storefront stylesheet + top-bar behaviour
templates/       project-wide template overrides (win over Oscar's own)
static/          project-wide static file overrides
media/           uploaded product images (gitignored)
whoosh_index/    search index (gitignored, rebuildable)
```

## Storefront layout

The look follows [innerbalance.com](https://www.innerbalance.com/): a floating
rounded top bar, periwinkle actions on near-white surfaces, generous corner
radii.

The bar itself is the frosted surface — translucent white with
`backdrop-filter: blur(14px)`, so page content blurs through it as it scrolls
underneath. The sticky wrapper around it is purely spacing (`background: none`,
`pointer-events: none`); giving *it* the background would paint a full-width
rectangle behind the rounded bar.

Oscar ships three stacked bars (accounts / brand + basket / browse + search).
They are replaced by one pill-shaped bar: wordmark left, nav centred on the
bar, then search, language, account and the **basket total** — which occupies
the slot the reference site gives its "Get started" button.

The nav is centred on the bar itself, not on the space left between the
wordmark and the controls: the right-hand group is much wider than the
wordmark, so auto margins leave it visibly off-centre. Above 992px the nav is
taken out of flow and pinned to `left: 50%; top: 50%`. The `top` matters — an
absolutely positioned flex child does not inherit `align-items: center`, and
its static position is the container's top edge, so without it the nav sits
high while everything else is centred.

### Shop menu

**Shop** opens a two-column mega-menu on hover and on keyboard focus
(`:focus-within`), mirroring the reference site's "What We Treat" / "Our
Products" layout:

- **Categories** — the category tree, two levels deep, plus an "All products"
  link.
- **Our Products** — the four best-rated products with thumbnails, supplied by
  `core.context_processors.nav_products`.

`Product.rating` is null until a product has reviews, so the query pushes nulls
last and uses `title` as a tie-breaker. **The demo catalogue has no reviews
yet**, so all seven products rate null and the menu currently shows the first
four by title. Add reviews and the ordering becomes meaningful with no code
change.

The panel fades and slides down over 0.22s while the chevron rotates;
`visibility` is transitioned with a matching delay so it animates *out* rather
than snapping away, and stays unclickable while hidden. The panel's top padding
bridges the gap to the toggle, so crossing it with the pointer does not close
the menu. Below 992px it renders inline inside a burger menu, since hover has
no meaning on touch.

### Listings

Product listings span the full page width: `.container.page` drops Bootstrap's
1140px cap in favour of fluid gutters, and the grid runs up to six across.
Oscar's left sidebar is gone, and so is its facet UI — categories live in the
Shop menu, and the listing is a breadcrumb row, a result count and the grid.

Neither the catalogue index nor category pages render an `<h1>`: the breadcrumb
already ends in the page's name, so repeating it below was redundant. The sort
control sits on the breadcrumb row, right-aligned. Oscar's `ui.js` submits the
closest form when `#id_sort_by` changes, so the select stays wrapped in a form
carrying the current query and any URL-selected facets.

`templates/oscar/catalogue/category.html` overrides Oscar's only to drop its
`header` block; the staff "Edit this category" shortcut that lived there is
kept, moved into the breadcrumb row. Subclasses override `breadcrumb_items` and
`crumbrow_extra` rather than the whole row, so the row itself is defined once in
`browse.html`.

`OSCAR_SEARCH_FACETS` is still configured, so facet counts are still computed
and `?selected_facets=` still filters — only the checkbox UI was removed. To
bring it back, re-add the `{% if has_facets %}` block to
`catalogue/browse.html` and `search/results.html`.

Three templates are overridden: `templates/oscar/layout.html`,
`catalogue/browse.html` and `search/results.html`. Oscar's own
`catalogue/category.html` extends `browse.html`, so category pages follow
automatically. The `navigation` and `mini_basket` block names are preserved so
templates that suppress them (e.g. `basket/basket.html`) still work.

The basket total sits outside `.sofi-topbar__collapse`, so it stays visible on
mobile instead of hiding inside the burger menu; CSS `order` places it after
the collapse on desktop and before the burger on mobile.

The language selector offers EN / UK / ES only (`LANGUAGES` in settings —
Django's default is every language it knows about). Oscar ships compiled
catalogues for all three, so switching genuinely translates its UI. Strings
introduced by this project ("Shop", "Categories", "Our Products") stay English
until a project `locale/` is created and compiled with `makemessages` /
`compilemessages`. The selector submits on change once JS loads; without JS the
`Go` button stays visible and the form still works. The Shop menu is CSS-only,
so it works even if `ui.js` fails to load.

## Flash messages

Basket messages appear as balloons hanging beneath the basket total, and hide
themselves: 3s for "<product> has been added to your cart", 5s for "Your cart
total is now €X".

Each message carries its own lifetime in a `data-toast-duration` attribute
rendered *inside the message HTML*
(`templates/oscar/basket/messages/{addition,new_total}.html`). That is why no
Oscar view is overridden and the basket app is not forked — the timing travels
with the message. Those two templates copy Oscar's wording and `blocktrans`
whitespace verbatim so the msgids still match its compiled catalogues and the
messages keep translating.

`partials/toasts.html` renders only messages carrying that marker;
`partials/alert_messages.html` is overridden to skip them, so nothing appears
twice. Everything else — form errors, voucher problems — stays in the in-page
alert area where it has context, rather than floating up to the header and
timing out.

Balloons pause their countdown on hover and on focus, and each has a close
button. A message with no marker stays until dismissed.


## Styling

Colours live in one `:root` block in `static/sofi/css/sofi.css`, sampled from
the reference site: `#5472cc` for actions, `#183690` for headings, white
surfaces on a `#f5f7fc` page. Retune the palette there and the whole storefront
follows. Everything is plain CSS layered over Oscar's Bootstrap 4 stylesheet —
there is no build step.

There is no dark mode: the storefront is light-only, matching the reference.

Several of Oscar's own rules had to be reworked, all marked with comments in
the CSS:

- `.page .page_inner` is painted solid white with a shadow; the content sheet
  is now transparent so cards float on the page background.
- `.product_pod` is pinned to `height: 380px` with an absolutely positioned
  price block, so two-line titles collide with the price. Pods are now flex
  columns that size to their content.
- `.star-rating` greys the row and colours only earned stars via `.One`…`.Five`;
  recolouring `.star-rating i` wholesale would show five filled stars on every
  unrated product, so those selectors are mirrored exactly.
- `form_field.html` (style `horizontal`) emits `col-sm-4` / `col-sm-7` with no
  wrapping `.row`. Inside a content-sized flex container those percentages
  resolve against a box sized by its own content, so the sort control is
  explicitly constrained in `.sofi-toolbar__sort`.

Note when screenshotting in headless Chrome: it clamps the viewport to a 500px
minimum, so `--window-size=430,...` renders a 500px-wide page and crops it —
which looks exactly like a horizontal-overflow bug. Measure
`document.documentElement.clientWidth` before believing it.

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
