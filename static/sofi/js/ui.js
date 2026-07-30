/*
 * Top-bar behaviour: mobile burger and language auto-submit.
 *
 * The Shop menu itself is CSS-only (:hover / :focus-within), so it needs no
 * JavaScript and keeps working if this file fails to load.
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

    function initLanguageForm() {
        var form = document.querySelector(".sofi-lang");
        if (!form) {
            return;
        }
        var select = form.querySelector(".sofi-lang__select");
        if (!select) {
            return;
        }
        // Progressive enhancement: submit on change and drop the Go button.
        // Without JS the button stays visible and the form still works.
        form.classList.add("sofi-lang--auto");
        select.addEventListener("change", function () {
            form.submit();
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

    document.addEventListener("DOMContentLoaded", function () {
        initBurger();
        initLanguageForm();
        initToasts();
    });
})();
