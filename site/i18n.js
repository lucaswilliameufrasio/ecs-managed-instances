"use strict";

// Portuguese source messages are stable keys. Both dictionaries have identical
// coverage; measurements and technical identifiers never enter these strings.
window.dashboardI18n = (() => {
  const english = {
    "ECS Managed Instances — Laboratório de desempenho": "ECS Managed Instances — Performance lab",
    "Resultados e curvas de desempenho de uma API Go em ECS Managed Instances, com benchmarks AWS e locais separados.": "Performance results and curves for a Go API on ECS Managed Instances, with separate AWS and local benchmarks.",
    "Ir para os resultados": "Skip to results",
    "Principal": "Main navigation",
    "Metodologia": "Methodology",
    "Idioma": "Language",
    "Onde a carga encontra o limite.": "Where load meets its limit.",
    "Uma API Go. Concorrência crescente. Resultados medidos em ECS Managed Instances — do primeiro request ao platô de throughput.": "One Go API. Increasing concurrency. Measurements on ECS Managed Instances — from the first request to the throughput plateau.",
    "Arquitetura do benchmark AWS com ALB": "AWS benchmark architecture with an ALB",
    "Graviton runner": "Graviton runner",
    "Oha · HTTP/1.1": "Oha · HTTP/1.1",
    "ALB interno": "Internal ALB",
    "Dois Availability Zones": "Two Availability Zones",
    "API Go · GET /spots": "Go API · GET /spots",
    "Explore as medições": "Explore the measurements",
    "Carregando relatórios…": "Loading reports…",
    "Ative JavaScript para explorar os gráficos.": "Enable JavaScript to explore the charts.",
    "Relatórios originais no GitHub": "Original reports on GitHub",
    "Ambiente": "Environment",
    "AWS · Graviton ARM64": "AWS · Graviton ARM64",
    "Local · x86_64": "Local · x86_64",
    "Execução": "Run",
    "Endpoint / GOMAXPROCS": "Endpoint / GOMAXPROCS",
    "Comparar execução": "Compare runs",
    "Comparação exploratória, não um ranking: hardware, runtime, caminho de rede e duração podem variar. Confira as configurações antes de concluir ganhos.": "An exploratory comparison, not a ranking: hardware, runtime, network path and duration may differ. Check the configurations before concluding there are performance gains.",
    "Throughput sob carga": "Throughput under load",
    "Requests por segundo × conexões simultâneas": "Requests per second × concurrent connections",
    "O custo em latência": "The latency trade-off",
    "Percentis em milissegundos · execução selecionada": "Percentiles in milliseconds · selected run",
    "Capacidade observada": "Observed capacity",
    "Contagens ao final de cada estágio · não uma série temporal": "Counts at the end of each stage · not a time series",
    "Configuração e origem dos dados": "Configuration and data sources",
    "Valores por estágio": "Measurements by stage",
    "Baixar CSV": "Download CSV",
    "Tabela de resultados, role horizontalmente para ver todas as colunas": "Results table; scroll horizontally to view all columns",
    "Conexões": "Connections",
    "Tasks": "Tasks",
    "Hosts": "Hosts",
    "Erros": "Errors",
    "O que estes números dizem. E o que não dizem.": "What these numbers tell you. And what they do not.",
    "Tráfego real, estado em memória": "Real traffic, in-memory state",
    "A API de estacionamento usa Go net/http, sem banco de dados. O runner envia HTTP para tasks Graviton; o histórico inclui IP direto e ALB interno. A infraestrutura é temporária.": "The parking API uses Go net/http without a database. The runner sends HTTP requests to Graviton tasks; the history includes direct IP and internal ALB paths. The infrastructure is temporary.",
    "Uma curva, não uma promessa": "A curve, not a promise",
    "Estágios aumentam a concorrência e registram throughput, latência e erros. Os testes AWS não têm warm-up separado. Aumento de latência com throughput estável indica um platô, não identifica sozinho o gargalo.": "Stages increase concurrency and record throughput, latency and errors. AWS tests have no separate warm-up. Rising latency with stable throughput indicates a plateau, but does not identify the bottleneck on its own.",
    "Local não é AWS": "Local is not AWS",
    "Medições locais x86_64 ajudam a investigar a aplicação, mas não são diretamente comparáveis a ARM64. Medianas locais agregam repetições; o histórico também inclui Docker com overhead de encaminhamento.": "Local x86_64 measurements help investigate the application, but are not directly comparable to ARM64. Local medians aggregate repeated samples; the history also includes Docker with forwarding overhead.",
    "Resultados rastreáveis": "Traceable results",
    "Os dados vêm apenas dos relatórios Markdown versionados. Tentativas interrompidas são excluídas. CPU sem série por estágio, memória e custos não são estimados nem inventados.": "Data comes only from versioned Markdown reports. Interrupted attempts are excluded. CPU without per-stage data, memory and costs are neither estimated nor invented.",
    "Próximas investigações": "Next investigations",
    "Política de testes AWS": "AWS testing policy",
    "Laboratório de desempenho · ECS Managed Instances": "Performance lab · ECS Managed Instances",
    "Dados estáticos. Sem conexão com sua conta AWS.": "Static data. No connection to your AWS account.",
    "Sem comparação": "No comparison",
    "AWS · IP direto": "AWS · Direct IP",
    "AWS · ALB interno": "AWS · Internal ALB",
    "Local · Docker": "Local · Docker",
    "Local · nativo": "Local · Native",
    "Contagens de tasks/hosts não foram registradas para esta execução.": "Task/host counts were not recorded for this run.",
    "Conexões simultâneas": "Concurrent connections",
    "Throughput (req/s)": "Throughput (req/s)",
    "Latência (ms)": "Latency (ms)",
    "Tasks / hosts (quantidade)": "Tasks / hosts (count)",
    "unidades": "units",
    "Valores completos na tabela por estágio; comparação no relatório de origem.": "Full measurements are in the stage table; comparison data is in the source report.",
    "{name}: {value} {unit}, {connections} conexões": "{name}: {value} {unit}, {connections} connections",
    "Hey: latência e status usam uma amostra limitada a 1 milhão de respostas; throughput cobre o teste inteiro.": "Hey: latency and status use a sample capped at 1 million responses; throughput covers the entire test.",
    "Abrir relatório original": "Open original report",
    "Configuração original do relatório (em inglês).": "Original report configuration (in English).",
    "req/s no melhor estágio": "req/s at the best stage",
    "{count} conexões": "{count} connections",
    "p99 em ms no pico de throughput": "p99 in ms at peak throughput",
    "Não é o maior p99 da execução": "Not the highest p99 in the run",
    "erros reportados": "reported errors",
    "Soma dos estágios selecionados": "Sum across the selected stages",
    "conexões no último estágio": "connections at the last stage",
    "{count} estágios medidos": "{count} measured stages",
    "Tasks em execução": "Running tasks",
    "MI hosts": "MI hosts",
    "Medianas de amostras; erros somados": "Sample medians; summed errors",
    "{count} execuções com resultados": "{count} runs with results",
    "Não foi possível carregar os resultados. Recarregue a página ou consulte os relatórios no GitHub. Para visualizar localmente, gere _site e use um servidor HTTP.": "Could not load the results. Reload the page or view the reports on GitHub. To preview locally, build _site and use an HTTP server.",
  };
  const dictionaries = { "pt-BR": Object.fromEntries(Object.keys(english).map((key) => [key, key])), "en-US": english };
  const supported = Object.keys(dictionaries);
  function detectLocale() {
    const query = new URL(location.href).searchParams.get("lang");
    if (supported.includes(query)) return query;
    try {
      const saved = localStorage.getItem("dashboard-language");
      if (supported.includes(saved)) return saved;
    } catch { /* Storage can be disabled; the selector and URL still work. */ }
    for (const language of navigator.languages || [navigator.language]) {
      const base = language.split("-")[0].toLowerCase();
      if (base === "pt") return "pt-BR";
      if (base === "en") return "en-US";
    }
    return "pt-BR";
  }
  let locale = detectLocale();
  function t(message, values = {}) {
    const translated = dictionaries[locale][message] ?? message;
    return translated.replace(/\{(\w+)\}/g, (match, key) => values[key] ?? match);
  }
  function apply() {
    document.documentElement.lang = locale;
    for (const node of document.querySelectorAll("[data-i18n]")) {
      if (!node.dataset.i18n) node.dataset.i18n = node.textContent.trim();
      node.textContent = t(node.dataset.i18n);
    }
    for (const attribute of ["aria-label", "content"]) {
      for (const node of document.querySelectorAll(`[data-i18n-${attribute}]`)) {
        node.setAttribute(attribute, t(node.getAttribute(`data-i18n-${attribute}`)));
      }
    }
    document.getElementById("language").value = locale;
  }
  function setLocale(value) {
    locale = supported.includes(value) ? value : detectLocale();
    try { localStorage.setItem("dashboard-language", locale); } catch { /* Optional persistence. */ }
    apply();
  }
  return { dictionaries, t, apply, setLocale, get locale() { return locale; } };
})();
