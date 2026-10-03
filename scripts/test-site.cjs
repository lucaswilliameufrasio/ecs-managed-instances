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
  const data = JSON.parse(await fs.readFile(path.join(root, "data.json"), "utf8"));
  const latestAWS = data.runs.find((run) => run.kind === "aws");
  const fixtureID = "20261001T205742Z";
  const prefix = "/ecs-managed-instances/";
  const allowed = new Set(["index.html", "style.css", "i18n.js", "app.js", "data.json"]);
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
    const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, locale: "pt-BR" });
    const page = await context.newPage();
    const failures = [];
    page.on("pageerror", (error) => failures.push(error.message));
    const address = `http://127.0.0.1:${server.address().port}${prefix}`;
    await page.goto(address);
    await page.locator("#dashboard").waitFor({ state: "visible" });
    assert.equal(await page.locator("html").getAttribute("lang"), "pt-BR");
    assert.equal(await page.locator("#run").inputValue(), latestAWS.id);
    // Keep exact-value assertions on a fixed historical report, not the latest
    // run: adding a newer report must not break automatic Pages publication.
    await page.selectOption("#run", fixtureID);
    assert.equal(await page.locator("#rows tr").count(), 8);
    assert.match(await page.locator("#summary").innerText(), /569\.115/);
    assert.equal(await page.locator("svg").count(), 3);
    async function assertAxisLabels(locale = "pt-BR") {
      const english = locale === "en-US";
      for (const [id, label] of [["throughput", "Throughput (req/s)"], ["latency", english ? "Latency (ms)" : "Latência (ms)"], ["capacity", english ? "Tasks / hosts (count)" : "Tasks / hosts (quantidade)"]]) {
        const chart = page.locator(`#${id} svg`);
        assert.equal(await chart.locator(".axis-label-x").textContent(), english ? "Concurrent connections" : "Conexões simultâneas");
        assert.equal(await chart.locator(".axis-label-y").textContent(), label);
        assert.equal(await chart.evaluate((svg) => {
          const bounds = svg.getBoundingClientRect();
          return [...svg.querySelectorAll(".axis-label")].every((label) => {
            const box = label.getBoundingClientRect();
            return box.left >= bounds.left && box.right <= bounds.right && box.top >= bounds.top && box.bottom <= bounds.bottom;
          });
        }), true, `${id}: axis titles must fit inside the chart`);
      }
    }
    await assertAxisLabels();
    assert.equal(await page.evaluate(() => document.querySelector("#throughput svg").viewBox.baseVal.width === document.querySelector("#throughput").clientWidth), true);
    const comparison = await page.locator("#compare option").nth(1).getAttribute("value");
    await page.selectOption("#compare", comparison);
    assert.equal(await page.locator("#throughput polyline").count(), 2);
    assert.equal(await page.locator("#configuration section").count(), 2);
    const beforeLanguageChange = await page.locator("select:not(#language)").evaluateAll((nodes) => nodes.map((node) => node.value));
    await page.selectOption("#language", "en-US");
    assert.equal(await page.locator("html").getAttribute("lang"), "en-US");
    assert.equal(await page.locator("h1").textContent(), "Where load meets its limit.");
    assert.equal(await page.locator("#download").textContent(), "Download CSV");
    assert.match(await page.title(), /Performance lab/);
    assert.match(await page.locator("#summary").innerText(), /569,115/);
    assert.match(await page.locator("#run option:checked").textContent(), /10\/01\/2026/);
    assert.match(await page.locator("#run option:checked").textContent(), /UTC/);
    assert.deepEqual(await page.locator("select:not(#language)").evaluateAll((nodes) => nodes.map((node) => node.value)), beforeLanguageChange);
    await assertAxisLabels("en-US");
    const shareURL = page.url();
    assert.equal(new URL(shareURL).searchParams.get("lang"), "en-US");
    assert.equal(new URL(shareURL).searchParams.get("compare"), comparison);
    await page.reload();
    await page.locator("#dashboard").waitFor({ state: "visible" });
    assert.equal(await page.locator("#compare").inputValue(), comparison);
    assert.equal(await page.locator("html").getAttribute("lang"), "en-US");
    await page.selectOption("#language", "pt-BR");
    assert.equal(await page.locator("h1").textContent(), "Onde a carga encontra o limite.");
    assert.match(await page.locator("#run option:checked").textContent(), /01\/10\/2026/);
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
    await page.selectOption("#run", fixtureID);
    for (const language of ["en-US", "pt-BR"]) {
      await page.selectOption("#language", language);
      await assertAxisLabels(language);
      const accessibility = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa", "wcag21aa"]).analyze();
      assert.deepEqual(accessibility.violations.map((violation) => ({ id: violation.id, nodes: violation.nodes.length })), []);
      if (language === "en-US") await page.screenshot({ path: (process.env.SITE_SCREENSHOT || "/tmp/opencode/ecs-pages-desktop.png").replace(".png", "-en-US.png"), fullPage: true });
    }
    await page.screenshot({ path: process.env.SITE_SCREENSHOT || "/tmp/opencode/ecs-pages-desktop.png", fullPage: true });
    await page.setViewportSize({ width: 390, height: 844 });
    await page.waitForFunction(() => document.querySelector("#throughput svg").viewBox.baseVal.width <= 390);
    await assertAxisLabels();
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true);
    for (const language of ["en-US", "pt-BR"]) {
      await page.selectOption("#language", language);
      await assertAxisLabels(language);
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true);
      const mobile = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa", "wcag21aa"]).analyze();
      assert.deepEqual(mobile.violations.map((violation) => violation.id), []);
      if (language === "en-US") await page.screenshot({ path: (process.env.SITE_MOBILE_SCREENSHOT || "/tmp/opencode/ecs-pages-mobile.png").replace(".png", "-en-US.png"), fullPage: true });
    }
    await page.screenshot({ path: process.env.SITE_MOBILE_SCREENSHOT || "/tmp/opencode/ecs-pages-mobile.png", fullPage: true });
    await page.setViewportSize({ width: 320, height: 740 });
    await page.waitForFunction(() => document.querySelector("#throughput svg").viewBox.baseVal.width === 320);
    for (const language of ["pt-BR", "en-US"]) {
      await page.selectOption("#language", language);
      await assertAxisLabels(language);
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true);
    }
    await page.selectOption("#language", "pt-BR");
    assert.deepEqual(failures, []);

    await page.route("**/data.json", (route) => route.fulfill({ status: 404, body: "not found" }));
    await page.reload();
    await page.locator("#status").filter({ hasText: "Não foi possível" }).waitFor();
    assert.equal(await page.locator("#dashboard").isVisible(), false);
    await page.selectOption("#language", "en-US");
    assert.match(await page.locator("#status").textContent(), /Could not load the results/);
    await page.selectOption("#language", "pt-BR");
    await page.unroute("**/data.json");
    await page.route("**/data.json", (route) => route.fulfill({ contentType: "application/json", body: '{"runs":[]}' }));
    await page.reload();
    await page.locator("#status").filter({ hasText: "Não foi possível" }).waitFor();
    assert.equal(await page.locator("#dashboard").isVisible(), false);
    await page.unroute("**/data.json");

    // URL wins over saved preferences and browser language, even in a new tab.
    const englishContext = await browser.newContext({ locale: "en-US" });
    const englishPage = await englishContext.newPage();
    await englishPage.goto(address);
    await englishPage.locator("#dashboard").waitFor({ state: "visible" });
    assert.equal(await englishPage.locator("#language").inputValue(), "en-US");
    await englishPage.selectOption("#language", "pt-BR");
    await englishPage.goto(address);
    await englishPage.locator("#dashboard").waitFor({ state: "visible" });
    assert.equal(await englishPage.locator("#language").inputValue(), "pt-BR");
    await englishPage.goto(shareURL);
    await englishPage.locator("#dashboard").waitFor({ state: "visible" });
    assert.equal(await englishPage.locator("#language").inputValue(), "en-US");
    assert.equal(await englishPage.locator("#compare").inputValue(), comparison);
    await englishPage.evaluate(() => {
      history.pushState(null, "", "?lang=pt-BR&kind=local&run=20261001T144339Z&series=%2Fspots%7C8");
      window.dispatchEvent(new PopStateEvent("popstate"));
    });
    assert.equal(await englishPage.locator("#kind").inputValue(), "local");
    assert.equal(await englishPage.locator("#series").inputValue(), "/spots|8");
    assert.equal(await englishPage.locator("#language").inputValue(), "pt-BR");
    assert.equal(await englishPage.locator("#rows tr").count(), 7);
    await englishPage.goBack();
    assert.equal(await englishPage.locator("#language").inputValue(), "en-US");
    assert.equal(await englishPage.locator("#compare").inputValue(), comparison);

    const fallbackContext = await browser.newContext({ locale: "fr-FR" });
    const fallbackPage = await fallbackContext.newPage();
    await fallbackPage.addInitScript(() => {
      Object.defineProperty(window, "localStorage", { get() { throw new Error("Storage unavailable"); } });
    });
    await fallbackPage.goto(`${address}?lang=invalid&kind=invalid&run=invalid&series=invalid&compare=invalid`);
    await fallbackPage.locator("#dashboard").waitFor({ state: "visible" });
    assert.equal(await fallbackPage.locator("#language").inputValue(), "pt-BR");
    assert.equal(await fallbackPage.locator("#run").inputValue(), latestAWS.id);
    assert.equal(await fallbackPage.locator("#compare").inputValue(), "");
    await fallbackPage.selectOption("#language", "en-US");
    assert.equal(await fallbackPage.locator("html").getAttribute("lang"), "en-US");

    const keysMatch = await englishPage.evaluate(() => {
      const dictionaries = window.dashboardI18n.dictionaries;
      return JSON.stringify(Object.keys(dictionaries["pt-BR"]).sort()) === JSON.stringify(Object.keys(dictionaries["en-US"]).sort());
    });
    assert.equal(keysMatch, true);
    const missingTranslations = await englishPage.evaluate(() => [...document.querySelectorAll("[data-i18n], [data-i18n-aria-label], [data-i18n-content]")].flatMap((node) => [node.dataset.i18n, node.getAttribute("data-i18n-aria-label"), node.getAttribute("data-i18n-content")].filter(Boolean)).filter((key) => !Object.hasOwn(window.dashboardI18n.dictionaries["en-US"], key)));
    assert.deepEqual(missingTranslations, []);
    const loadingPage = await fallbackContext.newPage();
    let releaseData;
    const dataGate = new Promise((resolve) => { releaseData = resolve; });
    await loadingPage.route("**/data.json", async (route) => {
      await dataGate;
      await route.continue();
    });
    await loadingPage.goto(address, { waitUntil: "domcontentloaded" });
    await loadingPage.selectOption("#language", "en-US");
    assert.equal(await loadingPage.locator("#status").textContent(), "Loading reports…");
    releaseData();
    await loadingPage.locator("#dashboard").waitFor({ state: "visible" });
    assert.equal(await loadingPage.locator("#language").inputValue(), "en-US");
    console.log("Browser checks passed: runs/series, axes, i18n, locale precedence, shared filters, CSV, mobile, accessibility and load failures.");
  } finally {
    if (browser) await browser.close();
    await new Promise((resolve) => server.close(resolve));
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
