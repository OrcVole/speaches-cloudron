const puppeteer = require('puppeteer-core');
(async () => {
  const [url, out] = [process.argv[2], process.argv[3]];
  const browser = await puppeteer.launch({
    executablePath: '/usr/bin/chromium-browser',
    args: ['--no-sandbox', '--disable-gpu', '--hide-scrollbars'],
    defaultViewport: { width: 1280, height: 560 },
  });
  const page = await browser.newPage();
  await page.goto(url, { waitUntil: 'networkidle2', timeout: 120000 });
  // Wait for Gradio to replace the loading splash with real controls.
  try {
    await page.waitForFunction(
      () => !document.body.innerText.includes('Loading') &&
            document.querySelectorAll('button, input, .tabs, .tabitem').length > 3,
      { timeout: 90000 });
  } catch (e) { console.error('render wait timed out, capturing anyway'); }
  await new Promise(r => setTimeout(r, 3000));
  await page.screenshot({ path: out });
  console.error('captured');
  await browser.close();
})();
