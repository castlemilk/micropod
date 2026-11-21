// Local browser validation. Every provider request is intercepted; no real analytics is sent.
const { chromium } = require('playwright');
const { readFileSync, mkdirSync } = require('node:fs');
const assert = require('node:assert/strict');
(async () => {
  const browser = await chromium.launch({channel:'chrome',headless:true});
  try {
    for (const width of [390, 1280]) {
      const context = await browser.newContext({viewport:{width,height:850}});
      const page = await context.newPage(); let vendorRequests = 0; let fixtureEnabled = false;
      await page.route('**/*', async route => {
        const url = new URL(route.request().url());
        if (url.hostname === 'www.googletagmanager.com') {vendorRequests++; return route.fulfill({contentType:'text/javascript',body:'/* intercepted test provider */'});}
        if (url.hostname !== 'analytics-fixture.invalid') return route.abort();
        if (url.pathname === '/micropod/analytics-config.js') return route.fulfill({contentType:'text/javascript',body:'window.MICROPOD_ANALYTICS={enabled:'+fixtureEnabled+',origin:"https://analytics-fixture.invalid",gaMeasurementId:"G-TEST123",gaPrivacyReviewed:true}'});
        const files = {'/micropod/':['landing/index.html','text/html'],'/micropod/analytics.js':['landing/analytics.js','text/javascript']};
        const file=files[url.pathname];
        return file ? route.fulfill({contentType:file[1],body:readFileSync(file[0])}) : route.fulfill({status:404,body:''});
      });
      await page.goto('https://analytics-fixture.invalid/micropod/');
      const baselineWidth = await page.evaluate(()=>document.documentElement.scrollWidth);
      assert.equal(await page.locator('#micropod-analytics-choice').count(),0);
      fixtureEnabled = true; await page.reload();
      await page.getByRole('button',{name:'Keep analytics off',exact:true}).click();
      assert.equal(vendorRequests,0);
      await page.getByRole('button',{name:'Allow website analytics',exact:true}).click();
      await page.waitForFunction(()=>!!document.querySelector('#micropod-ga-script'));
      const enabledWidth = await page.evaluate(()=>document.documentElement.scrollWidth);
      assert.ok(enabledWidth <= baselineWidth, 'Consent panel must not increase baseline overflow');
      if (baselineWidth > width) console.log(`Pre-existing landing overflow: ${baselineWidth}px at ${width}px viewport; analytics ${enabledWidth}px`);
      assert.equal(await page.locator('#micropod-analytics-choice').evaluate(n=>n.getBoundingClientRect().right <= innerWidth),true);
      assert.equal(await page.getByRole('status').innerText(),'Analytics allowed for this tab.');
      assert.equal(await page.evaluate(()=>window['ga-disable-G-TEST123']),false);
      assert.equal(await page.evaluate(()=>dataLayer.filter(args=>args[0]==='event'&&args[1]==='page_view').length),1);
      mkdirSync('/tmp/micropod-analytics-review',{recursive:true});
      await page.locator('#micropod-analytics-choice').screenshot({path:`/tmp/micropod-analytics-review/choice-${width}.png`});
      await page.getByRole('button',{name:'Turn analytics off',exact:true}).click();
      await page.waitForLoadState('load');
      await page.getByRole('button',{name:'Allow website analytics',exact:true}).waitFor();
      assert.equal(await page.locator('#micropod-ga-script').count(),0);
      const before=vendorRequests;
      await page.reload();assert.equal(vendorRequests,before);
      await page.goto('https://analytics-fixture.invalid/micropod/?secret=excluded');
      assert.equal(await page.locator('#micropod-analytics-choice').count(),0);
      await context.close();
    }
    console.log('Browser consent checks passed at 390px and 1280px; all provider requests intercepted.');
  } finally {await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
