/*
 * Top-bar behaviour: the mobile burger.
 *
 * The Shop and language menus are both CSS-only (:hover / :focus-within), so
 * they need no JavaScript and keep working if this file fails to load. The
 * language form posts through per-option submit buttons for the same reason.
 */
(function () {
    "use strict";

    function initBurger() {
        var burger = document.getElementById("sofi_burger");
        var collapse = document.getElementById("sofi_nav");
        if (!burger || !collapse) {
            return;
        }
        burger.addEventListener("click", function () {
            var open = burger.getAttribute("aria-expanded") === "true";
            burger.setAttribute("aria-expanded", String(!open));
            collapse.classList.toggle("is-open", !open);
        });
    }

    /*
     * Toast balloons under the basket total.
     *
     * Each message carries its own lifetime in a `data-toast-duration`
     * attribute rendered inside the message HTML (see
     * templates/oscar/basket/messages/*.html), so timings are set per message
     * without touching Oscar's views. A message with no marker stays until
     * dismissed.
     */
    function initToasts() {
        var container = document.getElementById("sofi_toasts");
        if (!container) {
            return;
        }

        var toasts = container.querySelectorAll(".sofi-toast");
        Array.prototype.forEach.call(toasts, function (toast) {
            var marker = toast.querySelector("[data-toast-duration]");
            var duration = marker
                ? parseInt(marker.getAttribute("data-toast-duration"), 10)
                : 0;
            var timer = null;

            function dismiss() {
                if (timer) {
                    clearTimeout(timer);
                    timer = null;
                }
                toast.classList.add("is-leaving");
                // Drop it from the layout once the fade-out has run, so the
                // toasts below it close the gap.
                setTimeout(function () {
                    if (toast.parentNode) {
                        toast.parentNode.removeChild(toast);
                    }
                }, 260);
            }

            function start() {
                if (duration > 0 && !timer) {
                    timer = setTimeout(dismiss, duration);
                }
            }

            var close = toast.querySelector(".sofi-toast__close");
            if (close) {
                close.addEventListener("click", dismiss);
            }

            // Don't yank the message away while it is being read or used.
            toast.addEventListener("mouseenter", function () {
                if (timer) {
                    clearTimeout(timer);
                    timer = null;
                }
            });
            toast.addEventListener("mouseleave", start);
            toast.addEventListener("focusin", function () {
                if (timer) {
                    clearTimeout(timer);
                    timer = null;
                }
            });
            toast.addEventListener("focusout", start);

            start();
        });
    }

    /*
     * Login / register tabs.
     *
     * Progressive enhancement: the template renders both forms stacked with
     * the tab strip hidden, and everything that makes them a tab widget — the
     * ARIA roles, the visible strip, hiding the inactive panel — is added
     * here. Without this file the page is still two working forms.
     *
     * Which tab opens first comes from the server via `data-initial-panel`,
     * so a registration that failed validation comes back on its own tab
     * rather than behind the login form.
     */
    function initAuthTabs() {
        var root = document.getElementById("sofi_auth");
        if (!root) {
            return;
        }

        var tablist = root.querySelector(".sofi-auth__tabs");
        var tabs = Array.prototype.slice.call(
            root.querySelectorAll(".sofi-auth__tab")
        );
        if (!tablist || !tabs.length) {
            return;
        }

        // Pair each tab with its panel; bail out rather than half-enhance if
        // any panel is missing.
        var pairs = [];
        var incomplete = false;
        tabs.forEach(function (tab) {
            var name = tab.getAttribute("data-panel");
            var panel = root.querySelector(
                '.sofi-auth__panel[data-panel="' + name + '"]'
            );
            if (!panel) {
                incomplete = true;
                return;
            }
            pairs.push({ name: name, tab: tab, panel: panel });
        });
        if (incomplete || !pairs.length) {
            return;
        }

        tablist.setAttribute("role", "tablist");
        pairs.forEach(function (pair) {
            pair.tab.setAttribute("role", "tab");
            pair.tab.setAttribute("aria-controls", pair.panel.id);
            pair.panel.setAttribute("role", "tabpanel");
            pair.panel.setAttribute("aria-labelledby", pair.tab.id);
        });

        function select(name, moveFocus) {
            pairs.forEach(function (pair) {
                var on = pair.name === name;
                pair.tab.setAttribute("aria-selected", String(on));
                // Roving tabindex: Tab reaches the strip once, then the arrow
                // keys move between tabs.
                pair.tab.setAttribute("tabindex", on ? "0" : "-1");
                pair.panel.hidden = !on;
                if (on && moveFocus) {
                    pair.tab.focus();
                }
            });
        }

        function indexOfSelected() {
            for (var i = 0; i < pairs.length; i++) {
                if (pairs[i].tab.getAttribute("aria-selected") === "true") {
                    return i;
                }
            }
            return 0;
        }

        pairs.forEach(function (pair) {
            pair.tab.addEventListener("click", function () {
                select(pair.name, false);
            });
        });

        tablist.addEventListener("keydown", function (event) {
            var last = pairs.length - 1;
            var next = null;
            switch (event.key) {
                case "ArrowLeft":
                case "ArrowUp":
                    next = indexOfSelected() === 0 ? last : indexOfSelected() - 1;
                    break;
                case "ArrowRight":
                case "ArrowDown":
                    next = indexOfSelected() === last ? 0 : indexOfSelected() + 1;
                    break;
                case "Home":
                    next = 0;
                    break;
                case "End":
                    next = last;
                    break;
                default:
                    return;
            }
            event.preventDefault();
            select(pairs[next].name, true);
        });

        var initial = root.getAttribute("data-initial-panel");
        select(
            pairs.some(function (pair) {
                return pair.name === initial;
            })
                ? initial
                : pairs[0].name,
            false
        );

        root.classList.add("sofi-auth--js");
    }

    document.addEventListener("DOMContentLoaded", function () {
        initBurger();
        initToasts();
        initAuthTabs();
    });
})();
