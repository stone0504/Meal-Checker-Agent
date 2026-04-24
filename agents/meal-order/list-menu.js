// Usage: node list-menu.js <LUNCH|DINNER> [YYYY-MM-DD]
// Lists available meal options for the given meal type and date.
// If no date given, uses the first (earliest) available tab.
// Prints JSON to stdout:
//   { "mealType": "LUNCH", "date": "2026-04-30", "weekday": "Thu",
//     "availableDates": ["2026-04-24", ...],
//     "shops": [ { "name": "...", "items": [ { "name": "...", "en": "...", "specs": "..." } ] } ] }

const { chromium } = require('playwright');

const ENTRY_URL = 'https://external-order.simplycarbs.com.tw/entry';
const EMAIL = process.env.MEAL_CHECKER_EMAIL;

if (!EMAIL) {
  console.error(JSON.stringify({ error: 'MEAL_CHECKER_EMAIL is not set.' }));
  process.exit(1);
}

const mealTypeArg = (process.argv[2] || '').toUpperCase();
const dateArg = process.argv[3] || null;

if (mealTypeArg !== 'LUNCH' && mealTypeArg !== 'DINNER') {
  console.error(
    JSON.stringify({ error: "First argument must be 'LUNCH' or 'DINNER'." }),
  );
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

    const availableDates = await page.evaluate(() =>
      Array.from(document.querySelectorAll('[role="tab"]'))
        .map((t) => t.innerText.trim())
        .filter((t) => /^20\d{2}-\d{2}-\d{2}/.test(t)),
    );

    let targetDate = dateArg;
    if (!targetDate) {
      const first = availableDates[0] || '';
      targetDate = first.slice(0, 10);
    }

    const clicked = await page.evaluate((date) => {
      const tabs = Array.from(document.querySelectorAll('[role="tab"]'));
      const t = tabs.find((tab) => tab.innerText.startsWith(date));
      if (!t) return false;
      t.click();
      return true;
    }, targetDate);

    if (!clicked) {
      throw new Error(
        `Date ${targetDate} is not an available tab. Available: ${availableDates.join(', ')}`,
      );
    }

    await page.waitForTimeout(800);

    const result = await page.evaluate(() => {
      const shops = [];
      const separators = Array.from(document.querySelectorAll('.ant-divider'));
      for (const sep of separators) {
        const shopName = sep.innerText?.trim();
        if (!shopName) continue;
        const itemsContainer = sep.nextElementSibling;
        if (!itemsContainer) continue;
        const items = [];
        // Each item row has a <strong> containing a Chinese name and a nested
        // generic (usually a <span>) with the English translation.
        const strongs = itemsContainer.querySelectorAll('strong');
        strongs.forEach((s) => {
          const clone = s.cloneNode(true);
          const nested = clone.querySelector('span, div');
          const en = nested ? nested.innerText.trim() : '';
          if (nested) nested.remove();
          const name = clone.innerText.trim();
          // specs text is typically the small gray line right after the strong
          let specs = '';
          const parent = s.parentElement;
          if (parent) {
            const next = parent.nextElementSibling;
            // Also try the sibling inside the same card layout
            const maybeSpecs = parent.querySelector(':scope > div:not(strong)');
            if (maybeSpecs) specs = maybeSpecs.innerText.trim();
            if (!specs && next) specs = next.innerText.trim();
          }
          items.push({ name, en, specs });
        });
        if (items.length > 0) shops.push({ name: shopName, items });
      }
      return shops;
    });

    const weekdayMatch = availableDates
      .find((d) => d.startsWith(targetDate))
      ?.match(/\(([A-Za-z]{3})\)/);
    const weekday = weekdayMatch ? weekdayMatch[1] : '';

    console.log(
      JSON.stringify(
        {
          mealType: mealTypeArg,
          date: targetDate,
          weekday,
          availableDates: availableDates.map((d) => d.slice(0, 10)),
          shops: result,
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
