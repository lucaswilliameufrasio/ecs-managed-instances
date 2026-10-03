# Project guidance

For changes to `site/`, read `.agents/skills/frontend-design/SKILL.md` and follow
its design review process. Keep this benchmark dashboard focused on readable,
traceable measurements rather than decorative dashboard chrome.

- Preserve the white, petrol-blue and restrained orange palette in `site/style.css`.
- Support `pt-BR` and `en-US` through `site/i18n.js`, including accessible labels,
  chart axes and messages. Use `Intl` for dates and numbers; keep timestamps in UTC.
- Keep technical identifiers and source reports unchanged. Do not translate or
  compare AWS ARM64 and local x86_64 data as though they were equivalent workloads.
- Keep the published site static and dependency-free. Only copy allowlisted
  report fields into `_site`; do not publish raw logs, account IDs or credentials.
- Before publishing, run the full Go tests/build/vet/gofmt checks, Python report
  tests, JavaScript syntax checks, and Chromium/axe checks in both languages.
- Do not run AWS benchmarks or change infrastructure for dashboard work.
