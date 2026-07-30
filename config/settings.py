"""
Django settings for the Sofi e-commerce shop (django-oscar).

Secrets and environment-specific values are read from the .env file in the
project root (see .env.example). Never commit .env.
"""

from pathlib import Path

import environ
from django.utils.translation import gettext_lazy as _

# Pull in every OSCAR_* default. Anything set below this import overrides it.
from oscar.defaults import *  # noqa: F401,F403

BASE_DIR = Path(__file__).resolve().parent.parent

env = environ.Env(
    DEBUG=(bool, False),
    ALLOWED_HOSTS=(list, ["localhost", "127.0.0.1"]),
    CSRF_TRUSTED_ORIGINS=(list, []),
    DATABASE_URL=(str, f"sqlite:///{BASE_DIR / 'db.sqlite3'}"),
    EMAIL_URL=(str, "consolemail://"),
    DEFAULT_FROM_EMAIL=(str, "shop@sofi.local"),
    OSCAR_SHOP_NAME=(str, "Sofi"),
    OSCAR_SHOP_TAGLINE=(str, ""),
    OSCAR_DEFAULT_CURRENCY=(str, "EUR"),
)
environ.Env.read_env(BASE_DIR / ".env")

SECRET_KEY = env("SECRET_KEY")
DEBUG = env("DEBUG")
ALLOWED_HOSTS = env("ALLOWED_HOSTS")
CSRF_TRUSTED_ORIGINS = env("CSRF_TRUSTED_ORIGINS")


# ---------------------------------------------------------------------------
# Applications
# ---------------------------------------------------------------------------

INSTALLED_APPS = [
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "django.contrib.sites",
    "django.contrib.flatpages",
    # Oscar core
    "oscar.config.Shop",
    "oscar.apps.analytics.apps.AnalyticsConfig",
    "oscar.apps.checkout.apps.CheckoutConfig",
    "oscar.apps.address.apps.AddressConfig",
    "oscar.apps.shipping.apps.ShippingConfig",
    "oscar.apps.catalogue.apps.CatalogueConfig",
    "oscar.apps.catalogue.reviews.apps.CatalogueReviewsConfig",
    "oscar.apps.communication.apps.CommunicationConfig",
    "oscar.apps.partner.apps.PartnerConfig",
    "oscar.apps.basket.apps.BasketConfig",
    "oscar.apps.payment.apps.PaymentConfig",
    "oscar.apps.offer.apps.OfferConfig",
    "oscar.apps.order.apps.OrderConfig",
    "oscar.apps.customer.apps.CustomerConfig",
    "oscar.apps.search.apps.SearchConfig",
    "oscar.apps.voucher.apps.VoucherConfig",
    "oscar.apps.wishlists.apps.WishlistsConfig",
    "oscar.apps.dashboard.apps.DashboardConfig",
    "oscar.apps.dashboard.reports.apps.ReportsDashboardConfig",
    "oscar.apps.dashboard.users.apps.UsersDashboardConfig",
    "oscar.apps.dashboard.orders.apps.OrdersDashboardConfig",
    "oscar.apps.dashboard.catalogue.apps.CatalogueDashboardConfig",
    "oscar.apps.dashboard.offers.apps.OffersDashboardConfig",
    "oscar.apps.dashboard.partners.apps.PartnersDashboardConfig",
    "oscar.apps.dashboard.pages.apps.PagesDashboardConfig",
    "oscar.apps.dashboard.ranges.apps.RangesDashboardConfig",
    "oscar.apps.dashboard.reviews.apps.ReviewsDashboardConfig",
    "oscar.apps.dashboard.vouchers.apps.VouchersDashboardConfig",
    "oscar.apps.dashboard.communications.apps.CommunicationsDashboardConfig",
    "oscar.apps.dashboard.shipping.apps.ShippingDashboardConfig",
    # Third-party apps Oscar depends on
    "widget_tweaks",
    "haystack",
    "treebeard",
    "django_tables2",
    "easy_thumbnails",
]

SITE_ID = 1

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.locale.LocaleMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
    "django.contrib.flatpages.middleware.FlatpageFallbackMiddleware",
    "oscar.apps.basket.middleware.BasketMiddleware",
]

ROOT_URLCONF = "config.urls"
WSGI_APPLICATION = "config.wsgi.application"
ASGI_APPLICATION = "config.asgi.application"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        # Project-level template overrides win over Oscar's own templates,
        # which are found by the app-dirs loader.
        "DIRS": [BASE_DIR / "templates"],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.contrib.auth.context_processors.auth",
                "django.template.context_processors.request",
                "django.template.context_processors.debug",
                "django.template.context_processors.i18n",
                "django.template.context_processors.media",
                "django.template.context_processors.static",
                "django.contrib.messages.context_processors.messages",
                "oscar.apps.search.context_processors.search_form",
                "oscar.apps.checkout.context_processors.checkout",
                "oscar.apps.communication.notifications.context_processors.notifications",
                "oscar.core.context_processors.metadata",
            ],
        },
    },
]


# ---------------------------------------------------------------------------
# Database — SQLite
# ---------------------------------------------------------------------------

DATABASES = {"default": env.db("DATABASE_URL")}
DATABASES["default"].setdefault("ATOMIC_REQUESTS", True)
# A relative sqlite path in DATABASE_URL is anchored to the project root, so
# the same file is used no matter which directory you run manage.py from.
if DATABASES["default"]["ENGINE"].endswith("sqlite3"):
    _name = DATABASES["default"]["NAME"]
    if _name != ":memory:" and not Path(_name).is_absolute():
        DATABASES["default"]["NAME"] = str(BASE_DIR / _name)
DATABASES["default"].setdefault("OPTIONS", {}).update(
    {
        # WAL + a busy timeout keep SQLite usable with concurrent requests.
        "init_command": "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;",
        "transaction_mode": "IMMEDIATE",
        "timeout": 20,
    }
)

DEFAULT_AUTO_FIELD = "django.db.models.AutoField"

# Oscar 4.1's Category manager is built with CategoryQuerySet.as_manager() and
# so isn't an MP_NodeManager subclass. Treebeard 6 turns that into a hard
# error, which is why django-treebeard is pinned to <6.0 in pyproject.toml.
# Drop this once Oscar ships a treebeard-6-compatible Category manager.
SILENCED_SYSTEM_CHECKS = ["treebeard.E001"]


# ---------------------------------------------------------------------------
# Cache — local in-memory (per-process, no external services)
# ---------------------------------------------------------------------------

CACHES = {
    "default": {
        "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
        "LOCATION": "sofi-default",
        "TIMEOUT": 300,
        "OPTIONS": {"MAX_ENTRIES": 10000},
    }
}

SESSION_ENGINE = "django.contrib.sessions.backends.db"


# ---------------------------------------------------------------------------
# Search — Haystack + Whoosh (pure Python, file-based, no external services)
# ---------------------------------------------------------------------------

HAYSTACK_CONNECTIONS = {
    "default": {
        "ENGINE": "haystack.backends.whoosh_backend.WhooshEngine",
        "PATH": str(BASE_DIR / "whoosh_index"),
        "INCLUDE_SPELLING": True,
    },
}

# Keep the index in sync as products/categories change. Fine for a single
# process; move to a queued/cron `rebuild_index` if you run multiple workers.
HAYSTACK_SIGNAL_PROCESSOR = "haystack.signals.RealtimeSignalProcessor"

# Whoosh supports *field* facets but not *query* facets, so Oscar's default
# "price_range" query facet is dropped to avoid a warning on every search.
OSCAR_SEARCH_FACETS = {
    "fields": {
        "product_class": {"name": _("Type"), "field": "product_class"},
        "rating": {"name": _("Rating"), "field": "rating"},
    },
    "queries": {},
}


# ---------------------------------------------------------------------------
# Authentication
# ---------------------------------------------------------------------------

AUTHENTICATION_BACKENDS = [
    "oscar.apps.customer.auth_backends.EmailBackend",
    "django.contrib.auth.backends.ModelBackend",
]

AUTH_PASSWORD_VALIDATORS = [
    {"NAME": "django.contrib.auth.password_validation.UserAttributeSimilarityValidator"},
    {"NAME": "django.contrib.auth.password_validation.MinimumLengthValidator"},
    {"NAME": "django.contrib.auth.password_validation.CommonPasswordValidator"},
    {"NAME": "django.contrib.auth.password_validation.NumericPasswordValidator"},
]

LOGIN_REDIRECT_URL = "/"


# ---------------------------------------------------------------------------
# Internationalisation
# ---------------------------------------------------------------------------

LANGUAGE_CODE = "en-gb"
TIME_ZONE = "UTC"
USE_I18N = True
USE_TZ = True


# ---------------------------------------------------------------------------
# Static & media files
# ---------------------------------------------------------------------------

STATIC_URL = "/static/"
STATIC_ROOT = BASE_DIR / "staticfiles"
STATICFILES_DIRS = [BASE_DIR / "static"]

MEDIA_URL = "/media/"
MEDIA_ROOT = BASE_DIR / "media"

STORAGES = {
    "default": {"BACKEND": "django.core.files.storage.FileSystemStorage"},
    "staticfiles": {
        "BACKEND": "django.contrib.staticfiles.storage.StaticFilesStorage"
        if DEBUG
        else "django.contrib.staticfiles.storage.ManifestStaticFilesStorage"
    },
}

# easy-thumbnails is used instead of sorl-thumbnail: pure Python, no key-value
# store to run alongside it.
OSCAR_THUMBNAILER = "oscar.core.thumbnails.EasyThumbnails"
THUMBNAIL_DEBUG = DEBUG


# ---------------------------------------------------------------------------
# Email
# ---------------------------------------------------------------------------

vars().update(env.email_url("EMAIL_URL"))
DEFAULT_FROM_EMAIL = env("DEFAULT_FROM_EMAIL")
OSCAR_FROM_EMAIL = DEFAULT_FROM_EMAIL


# ---------------------------------------------------------------------------
# Oscar shop configuration
# ---------------------------------------------------------------------------

OSCAR_SHOP_NAME = env("OSCAR_SHOP_NAME")
OSCAR_SHOP_TAGLINE = env("OSCAR_SHOP_TAGLINE")
OSCAR_DEFAULT_CURRENCY = env("OSCAR_DEFAULT_CURRENCY")
OSCAR_ALLOW_ANON_CHECKOUT = True
OSCAR_URL_SCHEMA = "http" if DEBUG else "https"


# ---------------------------------------------------------------------------
# Security (relevant once DEBUG is off)
# ---------------------------------------------------------------------------

if not DEBUG:
    SECURE_SSL_REDIRECT = True
    SESSION_COOKIE_SECURE = True
    CSRF_COOKIE_SECURE = True
    SECURE_HSTS_SECONDS = 60 * 60 * 24 * 7
    SECURE_HSTS_INCLUDE_SUBDOMAINS = True
    SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")

X_FRAME_OPTIONS = "DENY"


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "formatters": {
        "simple": {"format": "%(asctime)s %(levelname)-8s %(name)s %(message)s"},
    },
    "handlers": {
        "console": {"class": "logging.StreamHandler", "formatter": "simple"},
    },
    "root": {"handlers": ["console"], "level": "INFO"},
    "loggers": {
        "django.db.backends": {"level": "WARNING"},
        "oscar": {"level": "INFO"},
    },
}
