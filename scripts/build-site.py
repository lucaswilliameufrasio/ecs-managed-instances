"""Build the public dashboard using only versioned, allowlisted report fields."""

import argparse
import json
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "https://github.com/lucaswilliameufrasio/ecs-managed-instances"


def number(value):
    match = re.match(r"^[\d,.]+", value.replace("`", "").strip())
    if not match:
        raise ValueError(f"Expected numeric measurement: {value!r}")
    return float(match[0].replace(",", ""))


def tables(text):
    header = None
    for line in text.splitlines():
        if not line.startswith("|"):
            header = None
            continue
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        if header is None:
            header = cells
        elif not all(re.fullmatch(r"[-:]+", cell) for cell in cells):
            if len(header) != len(cells):
                raise ValueError("Mismatched report table columns")
            yield dict(zip(header, cells))


def parse_report(path, kind):
    text = path.read_text()
    points = []
    for row in tables(text):
        if "RPS" not in row and "Median RPS" not in row:
            continue
        concurrency = row.get("Concurrency", row.get("Connections"))
        if concurrency is None:
            match = re.search(r"(\d+) concurrent", text)
            if not match:
                raise ValueError(f"Missing concurrency in {path}")
            concurrency = match[1]
        point = {
            "connections": int(number(concurrency)),
            "endpoint": row.get("Endpoint", "/spots").replace("`", "").replace("GET ", ""),
            "rps": number(row.get("RPS", row.get("Median RPS"))),
            "p50": number(row["p50"]) if "p50" in row else None,
            "p95": number(row.get("p95", row.get("Median p95"))),
            "p99": number(row.get("p99", row.get("Median p99"))),
            "errors": int(number(row.get("Errors", row.get("Errors (total)", "0")))),
            "gomaxprocs": row.get("GOMAXPROCS", ""),
        }
        for key, fragment in [("tasks", "running"), ("hosts", "MI hosts")]:
            value = next((v for k, v in row.items() if fragment.lower() in k.lower()), None)
            point[key] = int(number(value.split("→")[-1])) if value else None
        points.append(point)
    if not points:
        if kind == "aws" and "Interrupted" not in text.splitlines()[0]:
            raise ValueError(f"No measurements in {path}")
        return None
    # Do not copy report prose: images, account IDs, private addresses and logs
    # must not enter the Pages artifact. Only named configuration lines qualify.
    prefixes = (
        "- Region / AZ:", "- ECS managed instance:", "- Task:", "- ECS task:",
        "- Load generator:", "- Load tool:", "- Autoscaling:", "- Load ramp:",
        "- Ramp:", "- Test:", "- Duration:", "- Go:", "- Native app pinned",
        "- Sweep:",
    )
    config = [line[2:].replace("`", "") for line in text.splitlines() if line.startswith(prefixes)]
    direct = "internal ALB" not in text
    environment = "AWS · IP direto" if direct else "AWS · ALB interno"
    if kind == "local":
        environment = "Local · Docker" if "Native app pinned" not in text else "Local · nativo"
    return {
        "id": path.stem, "kind": kind, "environment": environment,
        "source": f"{REPOSITORY}/blob/main/benchmarks/{'runs' if kind == 'aws' else 'local'}/{path.name}",
        "config": config, "points": points,
        "sampled": "hey v0.1.4" in text,
    }


def build(root, output):
    runs = []
    for folder, kind in [("runs", "aws"), ("local", "local")]:
        for path in sorted((root / "benchmarks" / folder).glob("????????T??????Z.md"), reverse=True):
            run = parse_report(path, kind)
            if run:
                runs.append(run)
    if not runs:
        raise ValueError("No benchmark reports found")
    output.mkdir(parents=True, exist_ok=True)
    for name in ("index.html", "style.css", "app.js"):
        shutil.copyfile(root / "site" / name, output / name)
    (output / "data.json").write_text(json.dumps({"runs": runs}, ensure_ascii=False, indent=2) + "\n")
    (output / ".nojekyll").touch()
    print(f"Built {len(runs)} runs into {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "_site")
    args = parser.parse_args()
    build(ROOT, args.output)
