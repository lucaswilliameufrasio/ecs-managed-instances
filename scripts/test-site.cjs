"use strict";

// Run after build-site.py with Playwright and @axe-core/playwright on NODE_PATH.
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const http = require("node:http");
const path = require("node:path");
const { chromium } = require("playwright");
const AxeBuilder = require("@axe-core/playwright").default;

async function main() {
  const root = path.resolve(__dirname, "../_site");
  const prefix = "/ecs-managed-instances/";
  const allowed = new Set(["index.html", "style.css", "app.js", "data.json"]);
  const types = { ".html": "text/html", ".css": "text/css", ".js": "text/javascript", ".json": "application/json" };
  const server = http.createServer(async (request, response) => {
    const url = new URL(request.url, "http://localhost");
    const name = url.pathname === prefix ? "index.html" : url.pathname.slice(prefix.length);
    if (!url.pathname.startsWith(prefix) || !allowed.has(name)) {
      response.writeHead(404).end();
      return;
    }
    try {
      const body = await fs.readFile(path.join(root, name));
      response.writeHead(200, { "Content-Type": types[path.extname(name)] }).end(body);
    } catch {
      response.writeHead(404).end();
    }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  let browser;
  try {
    browser = await chromium.launch({ headless: true });
    const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
    const page = await context.newPage();
    const failures = [];
    page.on("pageerror", (error) => failures.push(error.message));
    const address = `http://127.0.0.1:${server.address().port}${prefix}`;
    await page.goto(address);
    await page.locator("#dashboard").waitFor({ state: "visible" });
    assert.equal(await page.locator("#run").inputValue(), "20261001T205742Z");
    assert.equal(await page.locator("#rows tr").count(), 8);
    assert.match(await page.locator("#summary").innerText(), /569\.115/);
    assert.equal(await page.locator("svg").count(), 3);
    assert.equal(await page.evaluate(() => document.querySelector("#throughput svg").viewBox.baseVal.width === document.querySelector("#throughput").clientWidth), true);
    const comparison = await page.locator("#compare option").nth(1).getAttribute("value");
    await page.selectOption("#compare", comparison);
    assert.equal(await page.locator("#throughput polyline").count(), 2);
    assert.equal(await page.locator("#configuration section").count(), 2);
    const downloadPromise = page.waitForEvent("download");
    await page.click("#download");
    const download = await downloadPromise;
    const csv = await fs.readFile(await download.path(), "utf8");
    assert.match(csv, /4096,569114\.73,2\.03,34\.108,54\.607,8,2,0/);

    for (const kind of ["aws", "local"]) {
      await page.selectOption("#kind", kind);
      await page.selectOption("#compare", "");
      const ids = await page.locator("#run option").evaluateAll((nodes) => nodes.map((node) => node.value));
      for (const id of ids) {
        await page.selectOption("#run", id);
        const keys = await page.locator("#series option").evaluateAll((nodes) => nodes.map((node) => node.value));
        for (const key of keys) {
          await page.selectOption("#series", key);
          assert.ok(await page.locator("#rows tr").count() > 0);
          assert.equal(await page.locator("#throughput polyline").count(), 1);
          assert.ok(!(await page.locator("#summary").innerText()).includes("NaN"));
          if (kind === "local") {
            assert.equal(await page.locator("#latency polyline").count(), 2);
            assert.equal(await page.locator("#capacity svg").count(), 0);
          }
        }
      }
    }
    await page.selectOption("#kind", "aws");
    const accessibility = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa", "wcag21aa"]).analyze();
    assert.deepEqual(accessibility.violations.map((violation) => ({ id: violation.id, nodes: violation.nodes.length })), []);
    await page.screenshot({ path: process.env.SITE_SCREENSHOT || "/tmp/opencode/ecs-pages-desktop.png", fullPage: true });
    await page.setViewportSize({ width: 390, height: 844 });
    await page.waitForFunction(() => document.querySelector("#throughput svg").viewBox.baseVal.width <= 390);
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true);
    const mobile = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa", "wcag21aa"]).analyze();
    assert.deepEqual(mobile.violations.map((violation) => violation.id), []);
    await page.screenshot({ path: process.env.SITE_MOBILE_SCREENSHOT || "/tmp/opencode/ecs-pages-mobile.png", fullPage: true });
    assert.deepEqual(failures, []);

    await page.route("**/data.json", (route) => route.fulfill({ status: 404, body: "not found" }));
    await page.reload();
    await page.locator("#status").filter({ hasText: "Não foi possível" }).waitFor();
    assert.equal(await page.locator("#dashboard").isVisible(), false);
    await page.unroute("**/data.json");
    await page.route("**/data.json", (route) => route.fulfill({ contentType: "application/json", body: '{"runs":[]}' }));
    await page.reload();
    await page.locator("#status").filter({ hasText: "Não foi possível" }).waitFor();
    assert.equal(await page.locator("#dashboard").isVisible(), false);
    console.log("Browser checks passed: all runs/series, comparisons, CSV, project subpath, mobile, accessibility and load failures.");
  } finally {
    if (browser) await browser.close();
    await new Promise((resolve) => server.close(resolve));
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
