"""Context available to every template, used by the top bar."""

from django.db.models import F
from oscar.core.loading import get_model

Product = get_model("catalogue", "Product")

NAV_PRODUCT_COUNT = 4


def nav_products(request):
    """
    The "Our Products" column of the Shop menu: the best-rated products.

    `Product.rating` is null until a product has reviews, so nulls are pushed
    to the end and `title` is used as a stable tie-breaker — without it the
    order of unrated products would be whatever the database happened to
    return, and could change between requests.
    """
    products = (
        Product.objects.browsable()
        .select_related("product_class")
        .prefetch_related("images", "stockrecords")
        .order_by(F("rating").desc(nulls_last=True), "title")[:NAV_PRODUCT_COUNT]
    )
    return {"nav_products": products}
