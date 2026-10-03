"use strict";

const $ = (id) => document.getElementById(id);
const fmt = (value, digits = 0) => value == null ? "—" : value.toLocaleString("pt-BR", { maximumFractionDigits: digits });
const colors = ["#176b91", "#b64c20", "#637941"];
let runs = [];

function element(tag, text, parent) {
  const node = document.createElement(tag);
  if (text != null) node.textContent = text;
  if (parent) parent.append(node);
  return node;
}

function option(select, value, label) {
  const node = element("option", label, select);
  node.value = value;
}

function date(id) {
  return `${id.slice(6, 8)}/${id.slice(4, 6)}/${id.slice(0, 4)} ${id.slice(9, 11)}:${id.slice(11, 13)} UTC`;
}

function seriesKey(point) {
  return `${point.endpoint}|${point.gomaxprocs}`;
}

function points(run) {
  return run.points.filter((point) => seriesKey(point) === $("series").value).sort((a, b) => a.connections - b.connections);
}

function selected() {
  return runs.find((run) => run.id === $("run").value && run.kind === $("kind").value);
}

function populateRuns() {
  $("run").replaceChildren();
  for (const run of runs.filter((run) => run.kind === $("kind").value)) {
    option($("run"), run.id, `${date(run.id)} · ${run.environment}`);
  }
  populateSeries();
}

function populateSeries() {
  const previous = $("series").value;
  $("series").replaceChildren();
  for (const key of new Set(selected().points.map(seriesKey))) {
    const [endpoint, procs] = key.split("|");
    option($("series"), key, `${endpoint}${procs ? ` · GOMAXPROCS ${procs}` : ""}`);
  }
  const defaultKey = [...$("series").options].find((node) => node.value.startsWith("/spots|"))?.value;
  $("series").value = [...$("series").options].some((node) => node.value === previous) ? previous : defaultKey || $("series").options[0].value;
  populateComparison();
}

function populateComparison() {
  const previous = $("compare").value;
  $("compare").replaceChildren();
  option($("compare"), "", "Sem comparação");
  for (const run of runs.filter((run) => run.kind === selected().kind && run.id !== selected().id && points(run).length)) {
    option($("compare"), run.id, `${date(run.id)} · ${run.environment}`);
  }
  if ([...$("compare").options].some((node) => node.value === previous)) $("compare").value = previous;
  render();
}

function chart(id, lines, unit) {
  const parent = $(id);
  parent.replaceChildren();
  lines = lines.filter((line) => line.values.some((point) => point.y != null));
  if (!lines.length) {
    element("p", "Contagens de tasks/hosts não foram registradas para esta execução.", parent);
    return;
  }
  const ns = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(ns, "svg");
  const width = Math.max(320, parent.clientWidth);
  const height = 300;
  const left = 65;
  const right = width - 24;
  const top = 20;
  const bottom = height - 44;
  svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
  svg.setAttribute("role", "img");
  svg.setAttribute("aria-label", `${parent.closest("article").querySelector("h3").textContent}. Valores completos na tabela por estágio; comparação no relatório de origem.`);
  const xs = [...new Set(lines.flatMap((line) => line.values.map((point) => point.x)))].sort((a, b) => a - b);
  const maximum = Math.max(1, ...lines.flatMap((line) => line.values.map((point) => point.y ?? 0))) * 1.1;
  const x = (value) => left + (xs.length === 1 ? 0.5 : xs.indexOf(value) / (xs.length - 1)) * (right - left);
  const y = (value) => bottom - value / maximum * (bottom - top);
  function shape(tag, attributes, text) {
    const node = document.createElementNS(ns, tag);
    for (const [key, value] of Object.entries(attributes)) node.setAttribute(key, value);
    if (text != null) node.textContent = text;
    svg.append(node);
    return node;
  }
  for (let tick = 0; tick <= 4; tick++) {
    const value = maximum * tick / 4;
    shape("line", { x1: left, x2: right, y1: y(value), y2: y(value), stroke: "#d8e6ec" });
    shape("text", { x: left - 10, y: y(value) + 4, "text-anchor": "end" }, unit === "req/s" && value >= 1000 ? `${fmt(value / 1000, 1)}k` : fmt(value, 1));
  }
  for (const value of xs) shape("text", { x: x(value), y: bottom + 25, "text-anchor": "middle" }, fmt(value));
  const legend = element("div");
  legend.className = "legend";
  lines.forEach((line, index) => {
    const color = colors[index % colors.length];
    const values = line.values.filter((point) => point.y != null);
    shape("polyline", { points: values.map((point) => `${x(point.x)},${y(point.y)}`).join(" "), fill: "none", stroke: color, "stroke-width": 2.5 });
    for (const point of values) {
      const circle = shape("circle", { cx: x(point.x), cy: y(point.y), r: 4, fill: color, tabindex: 0 });
      const description = `${line.name}: ${fmt(point.y, 3)} ${unit}, ${fmt(point.x)} conexões`;
      circle.setAttribute("aria-label", description);
      const title = document.createElementNS(ns, "title");
      title.textContent = description;
      circle.append(title);
    }
    const label = element("span", null, legend);
    const swatch = element("i", null, label);
    swatch.style.setProperty("--line", color);
    element("span", line.name, label);
  });
  parent.append(svg, legend);
}

function configuration(run, parent) {
  const section = element("section", null, parent);
  element("h4", `${date(run.id)} · ${run.environment}`, section);
  const list = element("ul", null, section);
  for (const text of run.config) element("li", text, list);
  if (run.sampled) element("p", "Hey: latência e status usam uma amostra limitada a 1 milhão de respostas; throughput cobre o teste inteiro.", section);
  const link = element("a", "Abrir relatório original", section);
  link.href = run.source;
}

function render() {
  const run = selected();
  const data = points(run);
  const comparison = runs.find((item) => item.kind === run.kind && item.id === $("compare").value);
  const peak = data.reduce((best, point) => point.rps > best.rps ? point : best);
  $("summary").replaceChildren();
  const metrics = [
    [fmt(peak.rps), "req/s no melhor estágio", `${fmt(peak.connections)} conexões`],
    [fmt(peak.p99, 3), "p99 em ms no pico de throughput", "Não é o maior p99 da execução"],
    [fmt(data.reduce((sum, point) => sum + point.errors, 0)), "erros reportados", "Soma dos estágios selecionados"],
    [fmt(Math.max(...data.map((point) => point.connections))), "conexões no último estágio", `${data.length} estágios medidos`],
  ];
  for (const [value, title, note] of metrics) {
    const node = element("div", null, $("summary"));
    node.className = "metric";
    element("strong", value, node);
    element("span", title, node);
    element("small", note, node);
  }
  const line = (name, values, field) => ({ name, values: values.map((point) => ({ x: point.connections, y: point[field] })) });
  const throughput = [line(date(run.id), data, "rps")];
  if (comparison) throughput.push(line(date(comparison.id), points(comparison), "rps"));
  chart("throughput", throughput, "req/s");
  chart("latency", ["p50", "p95", "p99"].map((field) => line(field, data, field)), "ms");
  chart("capacity", [line("Tasks running", data, "tasks"), line("MI hosts", data, "hosts")], "unidades");
  $("configuration").replaceChildren();
  $("configuration").className = "config-grid";
  configuration(run, $("configuration"));
  if (comparison) configuration(comparison, $("configuration"));
  $("table-caption").textContent = `${date(run.id)} · ${$("series").selectedOptions[0].textContent}${run.kind === "local" ? " · Medianas de amostras; erros somados" : ""}`;
  $("rows").replaceChildren();
  for (const point of data) {
    const row = element("tr", null, $("rows"));
    for (const field of ["connections", "rps", "p50", "p95", "p99", "tasks", "hosts", "errors"]) element("td", fmt(point[field], field.startsWith("p") ? 3 : field === "rps" ? 2 : 0), row);
  }
}

$("kind").addEventListener("change", populateRuns);
$("run").addEventListener("change", populateSeries);
$("series").addEventListener("change", populateComparison);
$("compare").addEventListener("change", render);
let resizeTimer;
window.addEventListener("resize", () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => { if (runs.length) render(); }, 100);
});
$("download").addEventListener("click", () => {
  const fields = ["connections", "rps", "p50", "p95", "p99", "tasks", "hosts", "errors"];
  const csv = [fields.join(","), ...points(selected()).map((point) => fields.map((field) => point[field] ?? "").join(","))].join("\n");
  const url = URL.createObjectURL(new Blob([csv], { type: "text/csv;charset=utf-8" }));
  const link = element("a");
  link.href = url;
  link.download = `${selected().kind}-${selected().id}.csv`;
  link.click();
  URL.revokeObjectURL(url);
});

async function load() {
  try {
    const response = await fetch("./data.json");
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const data = await response.json();
    if (!Array.isArray(data.runs) || !data.runs.length) throw new Error("No reports");
    runs = data.runs;
    $("dashboard").hidden = false;
    populateRuns();
    $("run-count").textContent = `${runs.length} execuções com resultados`;
    $("status").hidden = true;
  } catch (error) {
    $("dashboard").hidden = true;
    $("status").textContent = "Não foi possível carregar os resultados. Recarregue a página ou consulte os relatórios no GitHub. Para visualizar localmente, gere _site e use um servidor HTTP.";
    console.error(error);
  }
}

load();
