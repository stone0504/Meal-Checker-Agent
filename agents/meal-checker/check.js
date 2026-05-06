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
  // Taipei (GMT+8) date in YYYY-MM-DD — the meal platform operates in Taiwan time,
  // so we pin to Asia/Taipei regardless of the host's system timezone.
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Taipei',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(new Date());
  const get = (type) => parts.find((p) => p.type === type).value;
  return `${get('year')}-${get('month')}-${get('day')}`;
}

async function extractOrders(page, source) {
  // Wait until the active tab panel's Lunch and Dinner sections have fully rendered.
  await page.waitForFunction(
    () => {
      function sectionReady(label) {
        const strongs = Array.from(document.querySelectorAll('strong')).filter(
          (el) => el.textContent.trim() === label,
        );
        const visible = strongs.find((el) => {
          const divider = el.closest('.ant-divider');
          return divider && divider.offsetParent !== null;
        });
        if (!visible) return true; // section doesn't exist on this tab — skip
        const divider = visible.closest('.ant-divider');
        const countTag = divider.querySelector('.ant-tag');
        const expected = countTag ? parseInt(countTag.textContent.trim(), 10) : 0;
        if (!Number.isFinite(expected) || expected === 0) return true;
        let fullyRendered = 0;
        for (let sib = divider.nextElementSibling; sib; sib = sib.nextElementSibling) {
          if (sib.matches('.ant-divider')) break;
          if (!sib.matches('.ant-card') || sib.offsetParent === null) continue;
          if (/•/.test(sib.innerText || '')) fullyRendered++;
        }
        return fullyRendered >= expected;
      }
      return sectionReady('Lunch') && sectionReady('Dinner');
    },
    { timeout: 10000 },
  );

  return page.evaluate((sourceLabel) => {
    const results = [];
    const dateStrongs = Array.from(document.querySelectorAll('strong')).filter((el) =>
      /^20\d{2}-\d{2}-\d{2}\s*\([A-Za-z]{3}\)$/.test(el.textContent.trim()),
    );

    for (const dStrong of dateStrongs) {
      const card = dStrong.closest('.ant-card');
      if (!card || card.offsetParent === null) continue;

      // The card's section (Lunch/Dinner) is the nearest preceding sibling divider
      // at the same depth containing a <strong>Lunch</strong> or <strong>Dinner</strong>.
      let section = null;
      for (let sib = card.previousElementSibling; sib; sib = sib.previousElementSibling) {
        const t = sib.querySelector?.('strong')?.textContent?.trim();
        if (t === 'Lunch' || t === 'Dinner') { section = t; break; }
      }
      if (section !== 'Lunch' && section !== 'Dinner') continue;

      const text = card.innerText || '';
      const dateMatch = dStrong.textContent
        .trim()
        .match(/^(20\d{2}-\d{2}-\d{2})\s*\(([A-Za-z]{3})\)$/);
      const statusMatch = text.match(/\b(Confirmed|Cancelled|Pending)\b/);

      // Pickup No.: the new UI renders the number inside a styled <div> next to
      // a "Pickup\nNo." label, so it shows up in innerText as "Pickup\nNo.\n067".
      // Fall back to the older layout (numeric <strong> in the card header row)
      // for backwards compatibility.
      let orderId = '';
      const pickupMatch = text.match(/Pickup\s*\n?\s*No\.?\s*\n?\s*(\d+)/i);
      if (pickupMatch) orderId = pickupMatch[1];
      if (!orderId) {
        const strongs = Array.from(card.querySelectorAll('strong'));
        for (const s of strongs) {
          const t = s.textContent.trim();
          if (/^\d{2,}$/.test(t)) { orderId = t; break; }
        }
      }

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
        orderId,
        status: statusMatch ? statusMatch[1] : '',
        shop,
        meal,
        mealType: section,
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
    await page.fill('input[type="text"]', EMAIL);
    await page.click('button:has-text("Login")');
    await page.waitForURL('**/booking', { timeout: 15000 });

    await page.goto(HISTORY_URL, { waitUntil: 'networkidle' });

    // Platform UI was updated: the single "Recent Orders" tab was split into
    // three — "Today Orders", "Order History", "Future Orders" — so we now
    // scrape each and merge the results.
    await page.waitForSelector('[role="tab"]:has-text("Today Orders")');

    await page.click('[role="tab"]:has-text("Today Orders")');
    await page.waitForTimeout(500);
    const todayOrders = await extractOrders(page, 'Today');

    await page.click('[role="tab"]:has-text("Order History")');
    await page.waitForTimeout(500);
    const historyOrders = await extractOrders(page, 'History');

    await page.click('[role="tab"]:has-text("Future Orders")');
    await page.waitForTimeout(500);
    const futureOrders = await extractOrders(page, 'Future');

    const confirmed = [...todayOrders, ...historyOrders, ...futureOrders]
      .filter((o) => o.status === 'Confirmed')
      .sort((a, b) => a.date.localeCompare(b.date));

    const lunchOrders = confirmed.filter((o) => o.mealType === 'Lunch');
    const dinnerOrders = confirmed.filter((o) => o.mealType === 'Dinner');

    const todayLunch = lunchOrders.find((o) => o.date === today) || null;
    const todayDinner = dinnerOrders.find((o) => o.date === today) || null;

    const output = {
      today,
      todayLunch,
      todayDinner,
      lunch: lunchOrders,
      dinner: dinnerOrders,
    };

    console.log(JSON.stringify(output, null, 2));
  } catch (err) {
    console.error(JSON.stringify({ error: err.message }));
    process.exitCode = 1;
  } finally {
    await browser.close();
  }
})();
