import re

from django.apps import apps
from django.conf import settings
from django.conf.urls.static import static
from django.contrib import admin
from django.urls import include, path, re_path
from django.views.decorators.cache import cache_control
from django.views.static import serve

urlpatterns = [
    path("admin/", admin.site.urls),
    path("i18n/", include("django.conf.urls.i18n")),
    # Everything else is served by Oscar: catalogue, basket, checkout,
    # accounts, search, offers, wishlists and the dashboard.
    path("", include(apps.get_app_config("oscar").urls[0])),
]

if settings.DEBUG:
    urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)
    urlpatterns += static(settings.STATIC_URL, document_root=settings.STATIC_ROOT)
elif settings.SERVE_MEDIA:
    # In production the collected static files are served by a CDN (STATIC_URL),
    # but media cannot be: product images and easy-thumbnails output are written
    # at runtime by the Oscar dashboard, so they have to come off this box's
    # disk. static() above deliberately no-ops when DEBUG is off, hence the
    # explicit route.
    #
    # This streams files through gunicorn, which is why the Cache-Control
    # matters — Cloudflare fronts the origin and serves repeat requests itself,
    # keeping the worker free. If image traffic outgrows that, put nginx in
    # front with a `location /media/` alias (or move to object storage) and set
    # SERVE_MEDIA=False.
    urlpatterns += [
        re_path(
            r"^%s(?P<path>.*)$" % re.escape(settings.MEDIA_URL.lstrip("/")),
            cache_control(max_age=60 * 60 * 24 * 30, public=True)(serve),
            {"document_root": settings.MEDIA_ROOT},
        ),
    ]
