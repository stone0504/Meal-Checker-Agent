const { chromium } = require('playwright');

const ENTRY_URL = 'https://external-order.simplycarbs.com.tw/entry';
const HISTORY_URL = 'https://external-order.simplycarbs.com.tw/history';
const EMAIL = process.env.MEAL_CHECKER_EMAIL;

if (!EMAIL) {
  console.error(
    JSON.stringify({
      error:
        'MEAL_CHECKER_EMAIL is not set. Re-run install.sh or export it in your shell rc.',
    }),
  );
  process.exit(1);
}

function todayISO() {
  // Local date in YYYY-MM-DD
  const d = new Date();
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}

async function extractOrders(page, source) {
  await page.waitForSelector('strong:has-text("Lunch")', { timeout: 10000 });

  return page.evaluate((sourceLabel) => {
    const results = [];
    const strongs = Array.from(document.querySelectorAll('strong'));
    const lunchStrong = strongs.find((el) => el.textContent.trim() === 'Lunch');
    const dinnerStrong = strongs.find((el) => el.textContent.trim() === 'Dinner');
    if (!lunchStrong) return results;

    const dateStrongs = strongs.filter((el) =>
      /^20\d{2}-\d{2}-\d{2}\s*\([A-Za-z]{3}\)$/.test(el.textContent.trim()),
    );

    for (const dStrong of dateStrongs) {
      // Must fall between the Lunch and Dinner separators in document order
      const posLunch = lunchStrong.compareDocumentPosition(dStrong);
      if (!(posLunch & Node.DOCUMENT_POSITION_FOLLOWING)) continue;
      if (dinnerStrong) {
        const posDinner = dinnerStrong.compareDocumentPosition(dStrong);
        if (posDinner & Node.DOCUMENT_POSITION_FOLLOWING) continue;
      }

      // Climb to the enclosing card (contains status + a "•" meal line)
      let card = dStrong.parentElement;
      while (card && card !== document.body) {
        const txt = card.innerText || '';
        if (/(Confirmed|Cancelled|Pending)/.test(txt) && /•/.test(txt)) break;
        card = card.parentElement;
      }
      if (!card) continue;

      const text = card.innerText;
      const dateMatch = dStrong.textContent
        .trim()
        .match(/^(20\d{2}-\d{2}-\d{2})\s*\(([A-Za-z]{3})\)$/);
      const statusMatch = text.match(/\b(Confirmed|Cancelled|Pending)\b/);

      let shop = '';
      const shopIcon = card.querySelector('[aria-label="shop"], img[alt="shop"]');
      if (shopIcon) {
        const shopStrong = shopIcon.closest('strong') || shopIcon.parentElement;
        shop = (shopStrong?.innerText || '').trim();
      }

      const mealLineMatch = text.match(/•\s*([^\n()]+?)(?:\s*\([^)]*\))?\s*(?:\n|$)/);
      const meal = mealLineMatch ? mealLineMatch[1].trim() : '';

      results.push({
        date: dateMatch[1],
        weekday: dateMatch[2],
        status: statusMatch ? statusMatch[1] : '',
        shop,
        meal,
        source: sourceLabel,
      });
    }
    return results;
  }, source);
}

(async () => {
  const today = todayISO();
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();

  try {
    await page.goto(ENTRY_URL, { waitUntil: 'networkidle' });
    await page.fill('input[placeholder*="amazon.com"]', EMAIL);
    await page.click('button:has-text("Login")');
    await page.waitForURL('**/booking', { timeout: 15000 });

    await page.goto(HISTORY_URL, { waitUntil: 'networkidle' });
    await page.waitForSelector('[role="tab"]:has-text("Recent Orders")');

    await page.click('[role="tab"]:has-text("Recent Orders")');
    await page.waitForTimeout(500);
    const recent = await extractOrders(page, 'Recent');

    await page.click('[role="tab"]:has-text("Future Orders")');
    await page.waitForTimeout(500);
    const future = await extractOrders(page, 'Future');

    const confirmed = [...recent, ...future]
      .filter((o) => o.status === 'Confirmed')
      .sort((a, b) => a.date.localeCompare(b.date));

    const todayOrder = confirmed.find((o) => o.date === today) || null;

    const output = {
      today,
      todayOrder,
      confirmed,
    };

    console.log(JSON.stringify(output, null, 2));
  } catch (err) {
    console.error(JSON.stringify({ error: err.message }));
    process.exitCode = 1;
  } finally {
    await browser.close();
  }
})();
