"""
Populate the shop with a small demo catalogue: t-shirts, boots and jackets.

Safe to re-run: products are matched on UPC and updated in place. Pass --reset
to delete the demo products (and their images) first.

    uv run python manage.py seed_demo_data
    uv run python manage.py seed_demo_data --reset
"""

from decimal import Decimal

from django.core.files.base import ContentFile
from django.core.management.base import BaseCommand
from django.db import transaction
from oscar.apps.catalogue.categories import create_from_breadcrumbs
from oscar.core.loading import get_model

from core.product_images import render_product_image

Product = get_model("catalogue", "Product")
ProductClass = get_model("catalogue", "ProductClass")
ProductAttribute = get_model("catalogue", "ProductAttribute")
ProductCategory = get_model("catalogue", "ProductCategory")
ProductImage = get_model("catalogue", "ProductImage")
Partner = get_model("partner", "Partner")
StockRecord = get_model("partner", "StockRecord")

UPC_PREFIX = "SOFI-"

PRODUCTS = [
    # --- T-shirts ---------------------------------------------------------
    {
        "upc": "SOFI-TSH-001",
        "title": "Harbour Cotton T-Shirt",
        "category": "Clothing > T-shirts",
        "shape": "tshirt",
        "colour": (44, 62, 102),
        "colour_name": "Navy",
        "material": "100% combed cotton",
        "price": "24.00",
        "stock": 25,
        "description": (
            "A midweight everyday tee cut from combed cotton, with a ribbed "
            "crew neck that keeps its shape wash after wash."
        ),
    },
    {
        "upc": "SOFI-TSH-002",
        "title": "Sunset Graphic T-Shirt",
        "category": "Clothing > T-shirts",
        "shape": "tshirt",
        "colour": (198, 93, 59),
        "colour_name": "Terracotta",
        "material": "Organic cotton",
        "price": "29.50",
        "stock": 18,
        "description": (
            "Garment-dyed organic cotton in a warm terracotta, finished with a "
            "soft-hand print that fades gently rather than cracking."
        ),
    },
    {
        "upc": "SOFI-TSH-003",
        "title": "Everyday Crew T-Shirt",
        "category": "Clothing > T-shirts",
        "shape": "tshirt",
        "colour": (222, 224, 226),
        "colour_name": "Off-white",
        "material": "Cotton blend",
        "price": "19.00",
        "stock": 40,
        "description": (
            "The plain white tee, done properly: a slightly heavier blend that "
            "stays opaque, with shoulder taping to stop it twisting."
        ),
    },
    # --- Boots ------------------------------------------------------------
    {
        "upc": "SOFI-BOO-001",
        "title": "Ridge Leather Chelsea Boot",
        "category": "Clothing > Boots",
        "shape": "boot",
        "colour": (138, 88, 52),
        "colour_name": "Chestnut",
        "material": "Full-grain leather",
        "price": "145.00",
        "stock": 12,
        "description": (
            "Full-grain leather over a Goodyear-welted sole, so it can be "
            "resoled rather than replaced. Elastic gussets, cotton pull tab."
        ),
    },
    {
        "upc": "SOFI-BOO-002",
        "title": "Trailhead Hiking Boot",
        "category": "Clothing > Boots",
        "shape": "boot",
        "colour": (92, 106, 71),
        "colour_name": "Olive",
        "material": "Suede and ripstop nylon",
        "price": "179.00",
        "stock": 9,
        "description": (
            "A four-season hiker with a waterproof membrane, padded collar and "
            "a lugged outsole that clears mud instead of packing it."
        ),
    },
    # --- Jackets ----------------------------------------------------------
    {
        "upc": "SOFI-JKT-001",
        "title": "Northwind Quilted Jacket",
        "category": "Clothing > Jackets",
        "shape": "jacket",
        "colour": (67, 72, 78),
        "colour_name": "Charcoal",
        "material": "Recycled polyester",
        "price": "210.00",
        "stock": 7,
        "description": (
            "Diamond-quilted recycled shell with a light synthetic fill: warm "
            "enough for a cold platform, packable enough for a bag."
        ),
    },
    {
        "upc": "SOFI-JKT-002",
        "title": "Camden Denim Jacket",
        "category": "Clothing > Jackets",
        "shape": "jacket",
        "colour": (58, 84, 122),
        "colour_name": "Indigo",
        "material": "14oz rigid denim",
        "price": "98.00",
        "stock": 15,
        "description": (
            "Rigid 14oz indigo denim that starts stiff and breaks in to your "
            "own creases. Copper rivets and a corduroy-lined collar."
        ),
    },
]


class Command(BaseCommand):
    help = "Create a demo catalogue of t-shirts, boots and jackets with images."

    def add_arguments(self, parser):
        parser.add_argument(
            "--reset",
            action="store_true",
            help="Delete existing demo products before seeding.",
        )

    @transaction.atomic
    def handle(self, *args, **options):
        if options["reset"]:
            deleted, _ = Product.objects.filter(upc__startswith=UPC_PREFIX).delete()
            self.stdout.write(f"Deleted {deleted} demo objects.")

        product_class = self._get_product_class()
        partner, _ = Partner.objects.get_or_create(
            name="Sofi Warehouse", defaults={"code": "sofi-warehouse"}
        )

        created_count = updated_count = 0
        for spec in PRODUCTS:
            product, created = self._upsert_product(spec, product_class)
            self._set_category(product, spec["category"])
            self._set_stock(product, partner, spec)
            self._set_image(product, spec)
            created_count += bool(created)
            updated_count += not created
            self.stdout.write(
                f"  {'created' if created else 'updated'}  {product.title}"
            )

        self.stdout.write(
            self.style.SUCCESS(
                f"Done: {created_count} created, {updated_count} updated, "
                f"{Product.objects.count()} products in catalogue."
            )
        )
        self.stdout.write(
            "The search index is updated automatically by the realtime signal "
            "processor; run `rebuild_index` if you ever need to force it."
        )

    def _get_product_class(self):
        product_class, _ = ProductClass.objects.get_or_create(
            slug="clothing",
            defaults={
                "name": "Clothing",
                "requires_shipping": True,
                "track_stock": True,
            },
        )
        for code, name in (("colour", "Colour"), ("material", "Material")):
            ProductAttribute.objects.get_or_create(
                product_class=product_class,
                code=code,
                defaults={
                    "name": name,
                    "type": ProductAttribute.TEXT,
                    "required": False,
                },
            )
        return product_class

    def _upsert_product(self, spec, product_class):
        product, created = Product.objects.update_or_create(
            upc=spec["upc"],
            defaults={
                "title": spec["title"],
                "description": spec["description"],
                "product_class": product_class,
                "structure": Product.STANDALONE,
                "is_public": True,
            },
        )
        product.attr.colour = spec["colour_name"]
        product.attr.material = spec["material"]
        product.save()
        return product, created

    def _set_category(self, product, breadcrumbs):
        category = create_from_breadcrumbs(breadcrumbs)
        ProductCategory.objects.get_or_create(product=product, category=category)

    def _set_stock(self, product, partner, spec):
        StockRecord.objects.update_or_create(
            product=product,
            partner=partner,
            defaults={
                "partner_sku": spec["upc"],
                "price": Decimal(spec["price"]),
                "price_currency": "EUR",
                "num_in_stock": spec["stock"],
                # Reset allocations too, so re-seeding always yields the same
                # available quantity rather than inheriting earlier test orders.
                "num_allocated": 0,
            },
        )

    def _set_image(self, product, spec):
        # Regenerate every run so the files exist even though media/ is
        # gitignored and may have been wiped.
        product.images.all().delete()
        data = render_product_image(
            shape=spec["shape"], colour=tuple(spec["colour"]), label=spec["colour_name"]
        )
        image = ProductImage(product=product, display_order=0)
        image.original.save(f"{spec['upc'].lower()}.jpg", ContentFile(data), save=True)
