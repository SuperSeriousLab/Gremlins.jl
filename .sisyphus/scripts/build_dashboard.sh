#!/usr/bin/env bash
# build_dashboard.sh — generate the Sisyphus campaign dashboard.
#
# Reads coverage.jsonl + certified/*.card.md + the source tree and
# emits a single self-contained HTML file at
# .sisyphus/dashboard.html. The file embeds all data as JSON; open
# it from disk (file://...) and it renders without a server.
#
# Run after every session that touches coverage. The file is
# git-tracked so changes show up in diffs and the rendered view
# travels with the repo.

set -uo pipefail

root="$(git rev-parse --show-toplevel)"
out="$root/.sisyphus/dashboard.html"
cov="$root/.sisyphus/coverage.jsonl"
cert_dir="$root/.sisyphus/certified"
gen_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
commit=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)

# ---------------------------------------------------------------------------
# Gather data
# ---------------------------------------------------------------------------

# All source chunks under the watched directories (config-driven).
# shellcheck disable=SC1091
. "$root/.sisyphus/config.sh"
chunks=$(sisyphus_list_chunks "$root")

# Latest coverage entry per chunk (last line wins).
declare -A status_of reason_of fs_of cx_of dc_of visits_of ts_of
while IFS= read -r line; do
  [ -z "$line" ] && continue
  c=$(echo "$line" | grep -oE '"chunk":"file:[^"]+"' | sed -E 's/.*file:([^"]+)"/\1/')
  s=$(echo "$line" | grep -oE '"status":"[^"]+"' | head -1 | cut -d'"' -f4)
  r=$(echo "$line" | grep -oE '"reason":"[^"]*"' | head -1 | cut -d'"' -f4)
  fs=$(echo "$line" | grep -oE '"file_size":[0-9.]+' | head -1 | cut -d: -f2)
  cx=$(echo "$line" | grep -oE '"complexity":[0-9.]+' | head -1 | cut -d: -f2)
  dc=$(echo "$line" | grep -oE '"doc_accuracy":[0-9.]+' | head -1 | cut -d: -f2)
  v=$(echo "$line" | grep -oE '"visit_count":[0-9]+' | head -1 | cut -d: -f2)
  t=$(echo "$line" | grep -oE '"ts":"[^"]+"' | head -1 | cut -d'"' -f4)
  [ -z "$c" ] && continue
  status_of[$c]=$s
  reason_of[$c]=$r
  fs_of[$c]=$fs
  cx_of[$c]=$cx
  dc_of[$c]=$dc
  visits_of[$c]=$v
  ts_of[$c]=$t
done < "$cov"

# Certified chunks (cards).
declare -A certified_of
if [ -d "$cert_dir" ]; then
  for card in "$cert_dir"/*.card.md; do
    [ -f "$card" ] || continue
    base=$(basename "$card" .card.md)
    path=$(echo "$base" | sed 's|_|/|')
    certified_of[$path]=1
  done
fi

# ---------------------------------------------------------------------------
# Build the JSON data block.
# ---------------------------------------------------------------------------

build_chunks_json() {
  local first=1
  printf '['
  while IFS= read -r chunk; do
    [ -z "$chunk" ] && continue
    local pkg="${chunk%%/*}"
    local file="${chunk##*/}"
    local status="${status_of[$chunk]:-unvisited}"
    local reason="${reason_of[$chunk]:-not-yet-measured}"
    local fs="${fs_of[$chunk]:-null}"
    local cx="${cx_of[$chunk]:-null}"
    local dc="${dc_of[$chunk]:-null}"
    local v="${visits_of[$chunk]:-0}"
    local ts="${ts_of[$chunk]:-}"
    local cert="${certified_of[$chunk]:-0}"
    if [ "$cert" = "1" ]; then
      status="certified"
      reason="card.md present"
    fi
    [ "$first" = "1" ] && first=0 || printf ','
    printf '\n  {"chunk":"%s","pkg":"%s","file":"%s","status":"%s","reason":"%s","fs":%s,"cx":%s,"dc":%s,"visits":%s,"ts":"%s"}' \
      "$chunk" "$pkg" "$file" "$status" "$reason" \
      "${fs:-null}" "${cx:-null}" "${dc:-null}" "$v" "$ts"
  done <<< "$chunks"
  printf '\n]'
}

chunks_json=$(build_chunks_json)

# Recent passes (last 10 PASS_LOG entries).
recent_passes=$(grep -E '^## Pass [0-9]+' "$root/.sisyphus/PASS_LOG.md" 2>/dev/null \
  | tail -10 | sed 's/^## //' \
  | awk '{ printf "%s%s", (NR>1?"\\n":""), $0 }')

# ---------------------------------------------------------------------------
# Write the HTML.
# ---------------------------------------------------------------------------

cat > "$out" <<HTML_EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Sisyphus Coverage — DORIANG</title>
<style>
  :root {
    --bg: #1a1d20;
    --panel: #22262a;
    --line: #2e3338;
    --text: #e8e8e8;
    --dim: #8a8f95;
    --unvisited: #3a3f44;
    --visited: #d4a017;
    --done: #28a745;
    --certified: #ffd700;
    --certified-glow: #ffd70080;
    --bad: #d24040;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    background: var(--bg);
    color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, "SF Mono", Menlo, Consolas, monospace;
    font-size: 13px;
    line-height: 1.5;
    padding: 20px;
  }
  h1, h2, h3 { font-weight: 600; margin: 0 0 8px 0; }
  h1 { font-size: 18px; color: var(--certified); letter-spacing: 0.02em; }
  h2 { font-size: 14px; color: var(--text); margin-top: 24px; }
  h3 { font-size: 12px; color: var(--dim); text-transform: uppercase; letter-spacing: 0.05em; }
  .meta { color: var(--dim); font-size: 11px; margin-bottom: 16px; }
  .panel {
    background: var(--panel);
    border: 1px solid var(--line);
    padding: 16px;
    margin-bottom: 16px;
  }
  .topbar {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    flex-wrap: wrap;
    gap: 16px;
    margin-bottom: 16px;
  }
  .progress-bar {
    width: 100%;
    height: 6px;
    background: var(--unvisited);
    margin: 8px 0;
    position: relative;
    overflow: hidden;
  }
  .progress-bar .seg {
    height: 100%;
    float: left;
    transition: width 0.4s ease;
  }
  .legend {
    display: flex;
    gap: 16px;
    flex-wrap: wrap;
    margin: 12px 0 8px 0;
    font-size: 11px;
  }
  .swatch {
    display: inline-block;
    width: 12px;
    height: 12px;
    margin-right: 4px;
    vertical-align: middle;
  }
  .pkg-header {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    margin: 20px 0 8px 0;
  }
  .pkg-stats { color: var(--dim); font-size: 11px; }
  .grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(14px, 1fr));
    gap: 2px;
    margin-bottom: 8px;
  }
  .cell {
    aspect-ratio: 1;
    background: var(--unvisited);
    border: 1px solid transparent;
    cursor: pointer;
    transition: transform 0.1s ease, box-shadow 0.2s ease;
    position: relative;
  }
  .cell:hover {
    transform: scale(1.6);
    z-index: 10;
    border-color: var(--text);
  }
  .cell.unvisited   { background: var(--unvisited); }
  .cell.visited     { background: var(--visited); }
  .cell.done-ceiling { background: var(--done); }
  .cell.done-diminishing { background: var(--done); opacity: 0.7; }
  .cell.done-budget { background: var(--done); opacity: 0.5; }
  .cell.lost-cause  { background: var(--bad); }
  .cell.certified   {
    background: var(--certified);
    box-shadow: 0 0 4px var(--certified-glow);
  }
  .tooltip {
    position: fixed;
    background: var(--panel);
    border: 1px solid var(--certified);
    padding: 10px 12px;
    font-size: 11px;
    pointer-events: none;
    z-index: 100;
    max-width: 360px;
    display: none;
    line-height: 1.6;
  }
  .tooltip .name {
    color: var(--certified);
    font-weight: 600;
    margin-bottom: 4px;
  }
  .tooltip .row { color: var(--dim); }
  .tooltip .row .v { color: var(--text); float: right; }
  .next {
    background: linear-gradient(90deg, var(--panel) 0%, transparent 100%);
    border-left: 3px solid var(--certified);
    padding: 12px 16px;
    margin: 16px 0;
  }
  .next .label {
    color: var(--certified);
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.1em;
    margin-bottom: 4px;
  }
  .next .chunk { font-size: 14px; font-weight: 600; }
  .recent {
    font-size: 11px;
    color: var(--dim);
    line-height: 1.7;
  }
  .recent code {
    background: var(--bg);
    padding: 1px 4px;
    color: var(--text);
  }
  .boulder {
    text-align: center;
    color: var(--dim);
    font-size: 10px;
    line-height: 1.2;
    margin: 32px 0 8px 0;
    white-space: pre;
  }
  .footer {
    color: var(--dim);
    font-size: 10px;
    text-align: center;
    margin-top: 24px;
    padding-top: 16px;
    border-top: 1px solid var(--line);
  }
</style>
</head>
<body>

<div class="topbar">
  <div>
    <h1>Sisyphus Coverage — DORIANG</h1>
    <div class="meta">commit <code>${commit}</code> · generated ${gen_ts}</div>
  </div>
  <div id="overall-stats" class="meta"></div>
</div>

<div class="panel">
  <div class="progress-bar" id="overall-bar"></div>
  <div class="legend">
    <span><span class="swatch" style="background:var(--unvisited)"></span>unvisited</span>
    <span><span class="swatch" style="background:var(--visited)"></span>visited (work needed)</span>
    <span><span class="swatch" style="background:var(--done)"></span>done-ceiling</span>
    <span><span class="swatch" style="background:var(--certified); box-shadow:0 0 4px var(--certified-glow)"></span>certified</span>
    <span><span class="swatch" style="background:var(--bad)"></span>lost-cause</span>
  </div>
</div>

<div class="next" id="next-pick">
  <div class="label">Next pick</div>
  <div class="chunk" id="next-chunk-name">computing…</div>
</div>

<div id="packages"></div>

<div class="panel">
  <h3>Recent activity</h3>
  <div class="recent" id="recent"></div>
</div>

<div class="boulder">
   .                              .
  / \\        .—.        / \\
 / Σ \\______(   )______/ Σ \\        the climb shapes the boulder
( oooo )    \`-'    ( oooo )         each pass leaves a face polished
 \\___/              \\___/
</div>

<div class="footer">
  generated by .sisyphus/scripts/build_dashboard.sh ·
  source data in .sisyphus/coverage.jsonl + .sisyphus/certified/
</div>

<div class="tooltip" id="tooltip"></div>

<script>
const DATA = ${chunks_json};
const RECENT = "${recent_passes}";

// -------------------------------------------------------------------------
// Aggregate per status + package.
// -------------------------------------------------------------------------
const total = DATA.length;
const buckets = { certified: 0, "done-ceiling": 0, "done-diminishing": 0,
                  "done-budget": 0, visited: 0, "lost-cause": 0, unvisited: 0 };
const byPkg = {};
for (const d of DATA) {
  buckets[d.status] = (buckets[d.status] || 0) + 1;
  if (!byPkg[d.pkg]) byPkg[d.pkg] = [];
  byPkg[d.pkg].push(d);
}

// -------------------------------------------------------------------------
// Overall progress bar.
// -------------------------------------------------------------------------
function pct(n) { return (n / total * 100).toFixed(1); }
const overall = document.getElementById("overall-bar");
const segs = [
  ["certified",        "var(--certified)"],
  ["done-ceiling",     "var(--done)"],
  ["done-diminishing", "var(--done)"],
  ["done-budget",      "var(--done)"],
  ["visited",          "var(--visited)"],
  ["lost-cause",       "var(--bad)"],
  ["unvisited",        "var(--unvisited)"],
];
overall.innerHTML = segs.map(([k, color]) => {
  const c = buckets[k] || 0;
  return c > 0 ? \`<span class="seg" style="width:\${pct(c)}%;background:\${color}"></span>\` : "";
}).join("");

const cert = buckets.certified || 0;
const done = (buckets["done-ceiling"]||0) + (buckets["done-diminishing"]||0) + (buckets["done-budget"]||0);
const visited = buckets.visited || 0;
const lost = buckets["lost-cause"] || 0;
const unvisited = buckets.unvisited || 0;

document.getElementById("overall-stats").innerHTML =
  \`<b style="color:var(--certified)">\${cert}</b> certified ·
   <b style="color:var(--done)">\${done}</b> done ·
   <b style="color:var(--visited)">\${visited}</b> visited ·
   <b style="color:var(--unvisited)">\${unvisited}</b> unvisited
   <span style="color:var(--dim)">/ \${total} total</span>\`;

// -------------------------------------------------------------------------
// Next pick — the highest-priority chunk for the agent.
// Order: visited not done → unvisited → done-ceiling (cert candidate)
// -------------------------------------------------------------------------
let next = null;
const visitedNotDone = DATA.filter(d => d.status === "visited");
const unvisitedCands = DATA.filter(d => d.status === "unvisited");
const certCands = DATA.filter(d => d.status === "done-ceiling");
if (visitedNotDone.length) {
  visitedNotDone.sort((a,b) => (a.cx??1) - (b.cx??1));
  next = { chunk: visitedNotDone[0], action: "POLISH — score below ceiling" };
} else if (unvisitedCands.length) {
  next = { chunk: unvisitedCands[0], action: "VISIT — first measurement" };
} else if (certCands.length) {
  next = { chunk: certCands[0], action: "CERTIFY — run cascade T1→T5" };
} else {
  next = null;
}
const npe = document.getElementById("next-chunk-name");
if (next) {
  npe.innerHTML = \`<code>\${next.chunk.chunk}</code> <span style="color:var(--dim);font-weight:400">— \${next.action}</span>\`;
} else {
  npe.innerHTML = \`<span style="color:var(--certified)">CAMPAIGN COMPLETE — every chunk certified</span>\`;
}

// -------------------------------------------------------------------------
// Per-package grids.
// -------------------------------------------------------------------------
const pkgsEl = document.getElementById("packages");
const pkgOrder = Object.keys(byPkg).sort();
for (const pkg of pkgOrder) {
  const items = byPkg[pkg].sort((a,b) => a.file.localeCompare(b.file));
  const c = items.filter(d => d.status === "certified").length;
  const d_ = items.filter(d => d.status.startsWith("done-")).length;
  const v_ = items.filter(d => d.status === "visited").length;
  const u_ = items.filter(d => d.status === "unvisited").length;
  const wrap = document.createElement("div");
  wrap.className = "panel";
  wrap.innerHTML = \`
    <div class="pkg-header">
      <h2>\${pkg}/</h2>
      <div class="pkg-stats">
        <b style="color:var(--certified)">\${c}</b> cert ·
        <b style="color:var(--done)">\${d_}</b> done ·
        <b style="color:var(--visited)">\${v_}</b> visited ·
        <b style="color:var(--unvisited)">\${u_}</b> unvisited
        <span style="color:var(--dim)">/ \${items.length}</span>
      </div>
    </div>
    <div class="grid" id="grid-\${pkg}"></div>
  \`;
  pkgsEl.appendChild(wrap);
  const grid = wrap.querySelector(\`#grid-\${pkg}\`);
  for (const item of items) {
    const cell = document.createElement("div");
    cell.className = "cell " + item.status;
    cell.dataset.chunk = item.chunk;
    cell.dataset.status = item.status;
    cell.dataset.reason = item.reason;
    cell.dataset.fs = item.fs ?? "";
    cell.dataset.cx = item.cx ?? "";
    cell.dataset.dc = item.dc ?? "";
    cell.dataset.visits = item.visits ?? "0";
    cell.dataset.ts = item.ts ?? "";
    grid.appendChild(cell);
  }
}

// -------------------------------------------------------------------------
// Recent activity.
// -------------------------------------------------------------------------
const recentEl = document.getElementById("recent");
if (RECENT) {
  recentEl.innerHTML = RECENT.split("\\\\n").reverse().slice(0, 8)
    .map(l => \`<div>· \${l}</div>\`).join("");
} else {
  recentEl.textContent = "No PASS_LOG entries yet.";
}

// -------------------------------------------------------------------------
// Tooltip.
// -------------------------------------------------------------------------
const tt = document.getElementById("tooltip");
document.querySelectorAll(".cell").forEach(cell => {
  cell.addEventListener("mouseenter", e => {
    const d = cell.dataset;
    const fmt = v => v && v !== "null" ? Number(v).toFixed(2) : "—";
    tt.innerHTML = \`
      <div class="name">\${d.chunk}</div>
      <div class="row">status<span class="v">\${d.status}</span></div>
      <div class="row">reason<span class="v">\${d.reason || "—"}</span></div>
      <div class="row">file_size<span class="v">\${fmt(d.fs)}</span></div>
      <div class="row">complexity<span class="v">\${fmt(d.cx)}</span></div>
      <div class="row">doc<span class="v">\${fmt(d.dc)}</span></div>
      <div class="row">visits<span class="v">\${d.visits}</span></div>
      <div class="row">last touched<span class="v">\${d.ts || "—"}</span></div>
    \`;
    tt.style.display = "block";
  });
  cell.addEventListener("mousemove", e => {
    const padding = 12;
    const x = e.clientX + padding;
    const y = e.clientY + padding;
    tt.style.left = Math.min(x, window.innerWidth - tt.offsetWidth - padding) + "px";
    tt.style.top = Math.min(y, window.innerHeight - tt.offsetHeight - padding) + "px";
  });
  cell.addEventListener("mouseleave", () => { tt.style.display = "none"; });
});
</script>
</body>
</html>
HTML_EOF

echo "wrote $out"
HTML_EOF_grep=$(wc -l < "$out")
echo "($HTML_EOF_grep lines)"
