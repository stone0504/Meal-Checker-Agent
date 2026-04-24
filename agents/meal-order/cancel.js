// Usage: node cancel.js <LUNCH|DINNER> <YYYY-MM-DD>
//
// Cancels the user's confirmed order for the given meal type on the given date.
// Prints JSON on success:
//   { "ok": true, "date": "2026-04-29", "mealType": "LUNCH",
//     "shop": "...", "meal": "...", "orderNumber": "096", "status": "Cancelled" }
// On failure prints { "error": "..." } to stderr and exits non-zero.

const { chromium } = require('playwright');

const ENTRY_URL = 'https://external-order.simplycarbs.com.tw/entry';
const HISTORY_URL = 'https://external-order.simplycarbs.com.tw/history';
const EMAIL = process.env.MEAL_CHECKER_EMAIL;

if (!EMAIL) {
  console.error(JSON.stringify({ error: 'MEAL_CHECKER_EMAIL is not set.' }));
  process.exit(1);
}

const mealTypeArg = (process.argv[2] || '').toUpperCase();
const dateArg = process.argv[3];

if (mealTypeArg !== 'LUNCH' && mealTypeArg !== 'DINNER') {
  console.error(JSON.stringify({ error: "First argument must be 'LUNCH' or 'DINNER'." }));
  process.exit(1);
}
if (!/^20\d{2}-\d{2}-\d{2}$/.test(dateArg || '')) {
  console.error(JSON.stringify({ error: 'Second argument must be a YYYY-MM-DD date.' }));
  process.exit(1);
}

const sectionLabel = mealTypeArg === 'LUNCH' ? 'Lunch' : 'Dinner';

(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  try {
    await page.goto(ENTRY_URL, { waitUntil: 'networkidle' });
    await page.fill('input[type="text"]', EMAIL);
    await page.click('button:has-text("Login")');
    await page.waitForURL('**/booking', { timeout: 15000 });

    await page.goto(HISTORY_URL, { waitUntil: 'networkidle' });
    await page.waitForSelector('[role="tab"]:has-text("Future Orders")');

    // Try Future first, then Recent — confirmed orders can live in either.
    const tabsToTry = ['Future Orders', 'Recent Orders'];
    let matched = null;

    for (const tabName of tabsToTry) {
      await page.evaluate((name) => {
        const t = Array.from(document.querySelectorAll('[role="tab"]')).find(
          (x) => x.innerText.trim() === name,
        );
        if (t) t.click();
      }, tabName);
      await page.waitForTimeout(600);

      const result = await page.evaluate(
        ({ date, section }) => {
          // Find the section divider (Lunch / Dinner) and walk its following
          // card siblings (stopping at the next divider), so we don't grab a
          // Dinner card when looking for Lunch.
          const dividers = Array.from(document.querySelectorAll('.ant-divider'));
          const sectionDivider = dividers.find((d) => {
            const s = d.querySelector('strong');
            return s && s.textContent.trim() === section;
          });
          if (!sectionDivider) return null;

          for (let sib = sectionDivider.nextElementSibling; sib; sib = sib.nextElementSibling) {
            if (sib.matches('.ant-divider')) break;
            if (!sib.matches('.ant-card')) continue;
            const text = sib.innerText || '';
            if (!text.includes(date)) continue;
            // Only cancel if still Confirmed
            if (!/\bConfirmed\b/.test(text)) continue;

            const shopEl = sib.querySelector('[aria-label="shop"], img[alt="shop"]');
            let shop = '';
            if (shopEl) {
              const shopStrong = shopEl.closest('strong') || shopEl.parentElement;
              shop = (shopStrong?.innerText || '').trim();
            }
            const mealLineMatch = text.match(/•\s*([^\n()]+?)(?:\s*\([^)]*\))?\s*(?:\n|$)/);
            const meal = mealLineMatch ? mealLineMatch[1].trim() : '';
            const numMatch = text.match(/\n(\d{3})\n/);
            const orderNumber = numMatch ? numMatch[1] : '';

            const btn = sib.querySelector('button[aria-label*="delete"], button');
            const cancelBtn = Array.from(sib.querySelectorAll('button')).find((b) =>
              /Cancel order/i.test(b.innerText),
            );
            if (!cancelBtn) return { found: true, shop, meal, orderNumber, clickable: false };
            cancelBtn.setAttribute('data-auto-cancel', '1');
            return { found: true, shop, meal, orderNumber, clickable: true };
          }
          return null;
        },
        { date: dateArg, section: sectionLabel },
      );

      if (result && result.found) {
        matched = result;
        break;
      }
    }

    if (!matched) {
      throw new Error(
        `No confirmed ${sectionLabel} order found for ${dateArg}. It may already be cancelled or not exist.`,
      );
    }
    if (!matched.clickable) {
      throw new Error('Found the order but could not locate the Cancel button.');
    }

    await page.click('[data-auto-cancel="1"]');
    await page.waitForSelector('[role="dialog"] button:has-text("Confirm cancellation")', {
      timeout: 5000,
    });
    await page.click('[role="dialog"] button:has-text("Confirm cancellation")');

    // Wait for the order row to flip from Confirmed to Cancelled.
    await page.waitForFunction(
      ({ date, num }) => {
        const cards = Array.from(document.querySelectorAll('.ant-card'));
        return cards.some((c) => {
          const t = c.innerText || '';
          return t.includes(date) && (num ? t.includes(num) : true) && /\bCancelled\b/.test(t);
        });
      },
      { date: dateArg, num: matched.orderNumber },
      { timeout: 10000 },
    );

    console.log(
      JSON.stringify(
        {
          ok: true,
          date: dateArg,
          mealType: mealTypeArg,
          shop: matched.shop,
          meal: matched.meal,
          orderNumber: matched.orderNumber,
          status: 'Cancelled',
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
