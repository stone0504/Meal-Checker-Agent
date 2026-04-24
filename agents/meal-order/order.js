// Usage: node order.js <LUNCH|DINNER> <YYYY-MM-DD> <ITEM_INDEX>
//
// ITEM_INDEX is 1-based, counting across ALL shops on that date (e.g. if shop A
// has items 1-5 and shop B has items 6-10, index 8 picks the 3rd item of shop B).
// The script picks the item, adds to cart, goes to checkout, and submits.
// Prints a JSON summary on success:
//   { "ok": true, "date": "2026-05-04", "mealType": "LUNCH",
//     "shop": "...", "meal": "...", "orderNumber": "055" }
// On failure prints { "error": "..." } to stderr and exits non-zero.

const { chromium } = require('playwright');

const ENTRY_URL = 'https://external-order.simplycarbs.com.tw/entry';
const EMAIL = process.env.MEAL_CHECKER_EMAIL;

if (!EMAIL) {
  console.error(JSON.stringify({ error: 'MEAL_CHECKER_EMAIL is not set.' }));
  process.exit(1);
}

const mealTypeArg = (process.argv[2] || '').toUpperCase();
const dateArg = process.argv[3];
const indexArg = parseInt(process.argv[4], 10);

if (mealTypeArg !== 'LUNCH' && mealTypeArg !== 'DINNER') {
  console.error(
    JSON.stringify({ error: "First argument must be 'LUNCH' or 'DINNER'." }),
  );
  process.exit(1);
}
if (!/^20\d{2}-\d{2}-\d{2}$/.test(dateArg || '')) {
  console.error(JSON.stringify({ error: 'Second argument must be a YYYY-MM-DD date.' }));
  process.exit(1);
}
if (!Number.isFinite(indexArg) || indexArg < 1) {
  console.error(JSON.stringify({ error: 'Third argument must be a 1-based integer index.' }));
  process.exit(1);
}

(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  try {
    await page.goto(ENTRY_URL, { waitUntil: 'networkidle' });
    await page.fill('input[type="text"]', EMAIL);
    await page.click('button:has-text("Login")');
    await page.waitForURL('**/booking', { timeout: 15000 });

    await page.goto(
      `https://external-order.simplycarbs.com.tw/meals?type=${mealTypeArg}`,
      { waitUntil: 'networkidle' },
    );
    await page.waitForSelector('[role="tab"]');

    const clicked = await page.evaluate((date) => {
      const tabs = Array.from(document.querySelectorAll('[role="tab"]'));
      const t = tabs.find((tab) => tab.innerText.startsWith(date));
      if (!t) return false;
      t.click();
      return true;
    }, dateArg);
    if (!clicked) throw new Error(`Date ${dateArg} is not an available tab.`);
    await page.waitForTimeout(800);

    // Find the Confirm button at the requested global index and the meal/shop
    // names next to it. We rely on the ordering of the shop-section blocks that
    // follow each .ant-divider — this mirrors what list-menu.js sees.
    const picked = await page.evaluate((targetIdx) => {
      const separators = Array.from(document.querySelectorAll('.ant-divider'));
      let counter = 0;
      for (const sep of separators) {
        const shopName = sep.innerText?.trim();
        if (!shopName) continue;
        const container = sep.nextElementSibling;
        if (!container) continue;
        const strongs = Array.from(container.querySelectorAll('strong'));
        for (const s of strongs) {
          counter++;
          if (counter === targetIdx) {
            // Name — without the nested English generic
            const clone = s.cloneNode(true);
            const nested = clone.querySelector('span, div');
            if (nested) nested.remove();
            const name = clone.innerText.trim();
            // Find the nearest Confirm button inside the row
            const row = s.closest('[class*="ant-card"], div');
            let btn = null;
            let ancestor = s.parentElement;
            while (ancestor && !btn) {
              btn = ancestor.querySelector('button');
              ancestor = ancestor.parentElement;
              if (ancestor === document.body) break;
            }
            if (!btn) return { error: 'could not locate Confirm button' };
            // Mark for clicking from outside the evaluate
            btn.setAttribute('data-auto-pick', '1');
            return { ok: true, shop: shopName, name };
          }
        }
      }
      return { error: `Index ${targetIdx} out of range — only ${counter} items on this date.` };
    }, indexArg);

    if (picked.error) throw new Error(picked.error);

    await page.click('[data-auto-pick="1"]');
    // Add dialog
    await page.waitForSelector('[role="dialog"] button:has-text("Add")', { timeout: 5000 });
    await page.click('[role="dialog"] button:has-text("Add")');

    // Go to cart / checkout
    await page.waitForSelector('button[aria-label*="shopping"], button:has(img[alt="shopping-cart"])', { timeout: 5000 }).catch(() => {});
    await page.goto('https://external-order.simplycarbs.com.tw/checkout', { waitUntil: 'networkidle' });
    await page.waitForSelector('button:has-text("Confirm and submit")', { timeout: 10000 });
    await page.click('button:has-text("Confirm and submit")');

    // Confirmation dialog
    await page.waitForSelector('[role="dialog"] button:has-text("Confirm")', { timeout: 5000 });
    await page.click('[role="dialog"] button:has-text("Confirm")');

    await page.waitForURL('**/history', { timeout: 15000 });
    await page.waitForTimeout(500);

    // Switch to Future Orders tab
    await page.evaluate(() => {
      const tabs = Array.from(document.querySelectorAll('[role="tab"]'));
      const f = tabs.find((t) => t.innerText.includes('Future'));
      if (f) f.click();
    });
    await page.waitForTimeout(500);

    const confirmation = await page.evaluate(
      ({ date, shop, name }) => {
        const cards = Array.from(document.querySelectorAll('.ant-card'));
        for (const c of cards) {
          const txt = c.innerText || '';
          if (txt.includes(date) && txt.includes(shop) && txt.includes(name)) {
            const numMatch = txt.match(/\n(\d{3})\n/);
            const statusMatch = txt.match(/\b(Confirmed|Pending|Cancelled)\b/);
            return {
              orderNumber: numMatch ? numMatch[1] : '',
              status: statusMatch ? statusMatch[1] : '',
            };
          }
        }
        return { orderNumber: '', status: '' };
      },
      { date: dateArg, shop: picked.shop, name: picked.name },
    );

    console.log(
      JSON.stringify(
        {
          ok: true,
          date: dateArg,
          mealType: mealTypeArg,
          shop: picked.shop,
          meal: picked.name,
          orderNumber: confirmation.orderNumber,
          status: confirmation.status,
        },
        null,
        2,
      ),
    );
  } catch (err) {
    console.error(JSON.stringify({ error: err.message }));
    process.exitCode = 1;
  } finally {
    await browser.close();
  }
})();
