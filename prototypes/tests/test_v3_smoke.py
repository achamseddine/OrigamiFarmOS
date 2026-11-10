"""Browser smoke checks for the standalone Origami FarmOS V3 prototype.

Prerequisites: pip install playwright && playwright install chromium
Run: python prototypes/tests/test_v3_smoke.py
The script never accesses or changes farm production systems.
"""
from pathlib import Path
from playwright.sync_api import sync_playwright

HTML = Path(__file__).resolve().parents[1] / "origami-farmos-v3.html"

def run():
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page(viewport={"width": 1280, "height": 860})
        errors = []
        page.on("pageerror", lambda err: errors.append(str(err)))
        page.goto("about:blank")
        page.evaluate("""() => {
            const d = {};
            Object.defineProperty(window, 'localStorage', {
                value: {getItem(k) {return d[k] ?? null}, setItem(k,v) {d[k] = String(v)}},
                configurable: true
            })
        }""")
        page.set_content(HTML.read_text(encoding="utf-8"))
        for module in ("overview","day","animals","feed","production","health","inventory",
                       "crops","finance","operations","intelligence"):
            page.evaluate("(x) => navigate(x)", module)
            assert page.locator("#screen h1").count() > 0, module

        def form(kind):
            page.evaluate("(kind) => openForm(kind)", kind)
            assert page.locator(".modalback.show").count() == 1

        def save():
            page.locator("#modal button[type=submit]").click()
            assert page.locator(".modalback.show").count() == 0, page.locator("#modal").inner_text()

        form("supplier")
        page.locator("#f_name").fill("Smoke Grain Supplier")
        save()
        form("receipt")
        page.locator("#f_item").fill("Corn")
        page.locator("#f_qty").fill("100")
        page.locator("#f_unitCost").fill("0.30")
        save()
        lot_id = page.evaluate("db.lots[0].id")
        form("mix")
        page.locator("#f_formula").fill("Smoke dairy test v1")
        page.locator("#f_qty").fill("50")
        page.locator(".mixlot").first.select_option(value=lot_id)
        page.locator(".mixqty").first.fill("50")
        save()
        assert page.evaluate("db.mixes[0].code") == "MIX-000001"
        assert page.evaluate("v3lotBalance(db.lots[0])") == 50

        page.evaluate("openForm('feed','a1')")
        page.locator("#f_source").select_option(label="MIX-000001")
        page.locator("#f_offered").fill("5")
        save()
        assert page.evaluate("v3mixBalance(db.mixes[0].id)") == 45

        form("financeTx")
        page.locator("#f_amount").fill("200")
        save()
        form("field")
        page.locator("#f_code").fill("GH-SMOKE")
        page.locator("#f_name").fill("Test greenhouse")
        save()
        form("workOrder")
        page.locator("#f_title").fill("Inspect water system")
        save()

        page.locator("#role").select_option("worker")
        page.evaluate("navigate('inventory')")
        assert page.get_by_role("button", name="+ Receive stock").count() == 0
        page.evaluate("openForm('receipt')")
        assert page.locator(".modalback.show").count() == 0

        assert not errors, errors
        mobile = browser.new_page(viewport={"width": 390, "height": 844})
        mobile.goto("about:blank")
        mobile.set_content(HTML.read_text(encoding="utf-8"))
        assert not mobile.evaluate("document.documentElement.scrollWidth > innerWidth")
        print("Origami V3 smoke checks passed")
        browser.close()

if __name__ == "__main__":
    run()
