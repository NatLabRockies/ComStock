// ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
// See top level LICENSE.txt file for license terms.
const D = window.__DASHBOARD__;
const $ = s => document.querySelector(s);
/* ---------- one word per REASON a cell is empty ----------
   "n/a" was doing at least three jobs -- the number is missing, the release does
   not publish it, and it cannot exist by construction -- and a reader cannot
   tell a data gap from a tool gap from a deliberate omission. Each token below
   names its own cause, and the Coverage tab carries the same list as a legend. */
const ABSENT = {
  noValue:       "no value",        // the number itself is absent
  notPublished:  "not published",   // that release's tables lack the columns
  notApplicable: "not applicable",  // cannot exist by construction
  noneSurveyed:  "none surveyed",   // the reference holds zero records here
  stockWideOnly: "stock-wide only", // computed, but not at this scope
  measureAbsent: "measure absent",  // the measure is not in that release
  noRecords:     "no records",      // zero usable rows for this selection
};
const absentTag = (kind, tip) => `<span class="absent"${
  tip?` title="${String(tip).replace(/"/g,"&quot;")}"`:""}>${ABSENT[kind]}</span>`;

const fmt = (v, n=1) => (v===null||v===undefined||Number.isNaN(v)) ? ABSENT.noValue
  : v.toLocaleString(undefined,{minimumFractionDigits:n,maximumFractionDigits:n});
const pct = v => (v===null||v===undefined||Number.isNaN(v)) ? ABSENT.noValue
  : (v>0?"+":"") + v.toFixed(1) + "%";
const SVGNS = "http://www.w3.org/2000/svg";
const el = (n,a={}) => { const e=document.createElementNS(SVGNS,n);
  for(const k in a) e.setAttribute(k,a[k]); return e; };
/* Every figure renders 1:1 — one viewBox unit is one CSS pixel — so a font set
   to 11.5px is 11.5px on screen. The old `width:100%;max-width:Npx` did the
   opposite: in any container narrower than N the whole figure was scaled down,
   which is what shrank the by-category axis labels to 6-7px. A definite width
   also gives flex and grid parents something to measure, so they can wrap a row
   of figures instead of squeezing them. */
const figStyle = w => `width:${w}px;max-width:100%;display:block`;

/* The pipeline stores the violin density and the outlier list as JSON strings
   (they are computed from the raw per-model values, which only exist inside the
   query pass). Parsed defensively: an assessment produced before this existed
   simply has no `kde` column, and those figures fall back to box-and-whiskers.
   Shared by BOTH distribution figures — the vertical EUI box plot and the
   horizontal savings one — so the two cannot drift apart. */
const parseKde=v=>{
  if(!v||typeof v!=="string") return null;
  try{ const o=JSON.parse(v);
    return (o&&Array.isArray(o.d)&&o.d.length>2&&isFinite(o.x0)&&isFinite(o.x1)
            &&o.x1>o.x0) ? o : null; }
  catch(e){ return null; }
};
const parseOutliers=v=>{
  if(!v||typeof v!=="string") return [];
  try{ const a=JSON.parse(v); return Array.isArray(a)?a.filter(x=>isFinite(x)):[]; }
  catch(e){ return []; }
};
/* Left padding DERIVED from the widest tick label the axis will actually print,
   never a fixed number. Raising the font sizes made every hardcoded padL wrong
   at once: a normalized tick like "0.00023" is 7 characters, ~45px at 11.5px,
   and it ran straight through the rotated axis title sitting at x=12. Deriving
   it means a future font change cannot bring this class of overlap back.
   `hasTitle` reserves the band the rotated y-axis title occupies. */
const AX_CHAR_W = 6.45;                  // 11.5px sans, digit advance
const axisPadL = (tickLabels, hasTitle) => Math.ceil(
  (hasTitle ? 17 : 6)
  + AX_CHAR_W * Math.max(1, ...tickLabels.map(s => String(s).length))
  + 9);

/* RUNS/SECONDARY/MULTI are live: the header "compare" checkbox re-derives them
   so every view renders either the run comparison or the standard single-run
   version. Labels and colors always resolve against the full run list. */
const ALL_RUNS = D.runs, PRIMARY = D.primaryRun;
// Display order puts the run under review LAST, so every grouped bar reads
// oldest to newest left-to-right and the current run is the bar your eye ends
// on. The manifest order (primary first) is kept only for lookups.
const displayOrder = rs => rs.filter(r=>r.key!==PRIMARY).concat(rs.filter(r=>r.key===PRIMARY));
let RUNS = displayOrder(ALL_RUNS);
let SECONDARY = RUNS.length>1 ? RUNS.find(r=>r.key!==PRIMARY) : null;
let MULTI = RUNS.length > 1;
function applyRunToggle(){
  RUNS = displayOrder(state.showCompare ? ALL_RUNS : ALL_RUNS.filter(r=>r.key===PRIMARY));
  SECONDARY = RUNS.length>1 ? RUNS.find(r=>r.key!==PRIMARY) : null;
  MULTI = RUNS.length > 1;
}
const runLabel = k => (ALL_RUNS.find(r=>r.key===k)||{}).label || k;
/* Short form for figure titles: "2025 R3" rather than
   "2025 R3 (OEDI comstock_amy2018_release_3)". The full label stays in the page
   subtitle and the Coverage tab, where the source table matters. */
const runShort = k => String(runLabel(k)).replace(/\s*\(.*$/,"").trim() || k;
const runColor = k => (ALL_RUNS.find(r=>r.key===k)||{}).color || "#0072B2";
const CROSS = "__cross__";

const CROSS_METRICS = [
  ["electricity.total","Electricity"],["natural_gas.total","Natural gas"],
  ["site_energy.total","Site energy"],["all_fuel.heating","Heating (all fuel)"],
  ["electricity.cooling","Cooling"],["sqft","Floor area"],
];
const EUI_METRICS = [["site_energy","Site energy"],["electricity","Electricity"],
                     ["natural_gas","Natural gas"]];

const AMI_REGIONS = Object.keys(D.amiProfiles||{});
let state = { type: CROSS, tab: "overview", amiMode: "annual",
              amiRegion: AMI_REGIONS.includes("pepco") ? "pepco" : AMI_REGIONS[0],
              dimSig: false, rankDim: "building_type",
              rankFuel: "electricity.total", rankSig: true,
              measView: "single",
              measLoc: "",          // measure-timeseries location; "" = first available
              measSel: D.measures&&D.measures.summary.length
                ? String(D.measures.summary[0].upgrade) : "",
              measMulti: D.measures
                ? D.measures.summary.slice(0,3).map(r=>String(r.upgrade)) : [],
              measDistGroup: "end_use", measMenuOpen: false, measBasis: "stock",
              measPop: "app",
              measCatGroup: "building_type", euHidden: [], feHidden: [], measHidden: [],
              showCompare: true,
              annualMetric: "electricity.total", annualDim: "vintage",
              /* Which breakdown to show. These tabs carried EVERY breakdown
                 stacked one after another - by vintage, census division, floor
                 area bin, climate zone, each in two fuels and three columns -
                 which is a very long scroll to reach the one you want. One
                 breakdown shows at a time now, with "All" kept as an explicit
                 choice because the full grid was asked for deliberately. */
              xDim: "vintage", distDim: "building_type",
              dpGroup: "Loads", dpDim: "building_type", hfView: "diff",
              euiMetric: "site_energy", euiBasis: "count", euiDim: "vintage" };

const FUEL_SHORT = {electricity:"elec", natural_gas:"gas", fuel_oil:"oil", propane:"propane",
  district_heating:"dist heat", district_cooling:"dist cool", site_energy:"site", all_fuel:"all fuel"};
const USE_SHORT = {interior_lighting:"int lighting", exterior_lighting:"ext lighting",
  interior_equipment:"int equip", water_systems:"water htg", refrigeration:"refrig"};
function shortLabel(metric){
  const [fuel,use] = metric.split(".");
  const f = FUEL_SHORT[fuel] || fuel.replace(/_/g," ");
  if (use === "total") return f;
  return `${f} · ${USE_SHORT[use] || (use||"").replace(/_/g," ")}`;
}

/* ---------- lookups ---------- */
const annualBy = {};   // run -> category -> metric -> row
(D.byDim.building_type||[]).forEach(r => {
  ((annualBy[r.run] ||= {})[r.category] ||= {})[r.metric] = r;
});
const fuelMixBy = {};
(D.fuelByDim.building_type||[]).forEach(r => (fuelMixBy[r.run] ||= {})[r.category] = r);
const snake = t => D.typeToSnake[t];

/* ---------- tooltip ---------- */
const tip = document.createElement("div"); tip.className="tip"; document.body.appendChild(tip);
function showTip(html, ev){
  tip.innerHTML = html; tip.style.opacity = 1;
  const pad=14, w=tip.offsetWidth, h=tip.offsetHeight;
  let x=ev.clientX+pad, y=ev.clientY+pad;
  if (x+w > innerWidth-8) x = ev.clientX-w-pad;
  if (y+h > innerHeight-8) y = ev.clientY-h-pad;
  tip.style.left=x+"px"; tip.style.top=y+"px";
}
const hideTip = () => tip.style.opacity = 0;

function diffColor(p){
  if (p===null||p===undefined||Number.isNaN(p)) return "transparent";
  const t = Math.min(Math.abs(p)/60, 1);
  const a = 0.10 + 0.42*t;
  return `rgba(${p>0?"213,94,0":"0,114,178"},${a})`;
}
function minmax(vals){
  const ok = vals.filter(v=>v!==null&&v!==undefined&&!Number.isNaN(v));
  if(!ok.length) return vals.map(()=>null);
  const lo=Math.min(...ok), hi=Math.max(...ok);
  if(hi===lo) return vals.map(v=>(v===null||v===undefined)?null:0);
  return vals.map(v=>(v===null||v===undefined)?null:(v-lo)/(hi-lo));
}

/* ---------- axis helper ---------- */
function yAxis(svg, max, padL, padT, plotH, width, padR, dec, ticks=4){
  for(let i=0;i<=ticks;i++){
    const v = max*i/ticks, yy = padT+plotH-(v/max)*plotH;
    svg.appendChild(el("line",{x1:padL-6,y1:yy,x2:width-padR,y2:yy,class:"gl"}));
    const t = el("text",{x:padL-10,y:yy+4,class:"ax","text-anchor":"end"});
    t.textContent = fmt(v, dec); svg.appendChild(t);
  }
}

/* ---------- grouped bars, N series, optional CI on one of them ---------- */
function groupedBar(host, rows, series, opts={}){
  const padL=58, padR=12, padT=10;
  const n = rows.length;
  if(!n){ host.innerHTML='<p class="note">No records for this selection.</p>'; return; }
  /* Series bars TOUCH inside a group and the gap lives only between groups —
     the matplotlib convention these figures follow. It reads as one group per
     category instead of n*k separate bars, and the width it saves goes into
     slimmer bars and a narrower figure rather than into padding. A hairline of
     panel colour (the rect stroke below) still separates them. */
  const k = series.length, inner=0, gap=opts.compact?12:18;
  /* Bar width falls out of a target FIGURE width rather than the other way
     round, so a compact by-category figure lands at or under 544px and two of
     them sit side by side in the panel at 1:1. Sizing the bars first let a
     16-category figure reach 580px, which then got scaled to 0.52 to fit its
     column and took the axis labels down to 6px with it. */
  const FIG_CAP = opts.compact ? 544 : 900;
  const roomForBars = FIG_CAP - padL - padR - n*gap;
  const bw = Math.max(5, Math.min(opts.compact?13:22, roomForBars/(n*k)));
  const slot = k*bw+(k-1)*inner;
  // the tick plan needs the real slot width, so it comes after the bar sizing
  const plan = tickPlan(rows.map(r=>r.label), slot+gap);
  const padB = plan.pad;
  // Each category group is centred in an equal slot, so the outer margins match
  // each other and every gap is the same width (the stray +30 on the right used
  // to make the whole plot look shifted left).
  const catSlot = slot+gap;
  const plotW = n*catSlot;
  const width = padL+padR+plotW;
  // Extra room for steeper labels is added to the figure, never taken out of
  // the plot area — otherwise long category names flatten the bars.
  const H = (opts.height||250) + Math.max(0, padB-76), plotH = H-padT-padB;
  const all = rows.flatMap(r => series.map(s=>r.values[s.key]).concat([r.ciHigh]))
                  .filter(v=>v!==null&&v!==undefined&&!Number.isNaN(v));
  const max = Math.max(...all, 1e-9);
  const y = v => padT+plotH-(v/max)*plotH;

  const svg = el("svg",{viewBox:`0 0 ${width} ${H}`,
    style: opts.compact ? figStyle(width) : `width:${width}px;max-width:none`});
  const defs = el("defs");
  series.filter(s=>s.hatch).forEach(s=>{
    const pat = el("pattern",{id:`h-${host.id}-${s.key}`,width:6,height:6,
      patternTransform:"rotate(45)",patternUnits:"userSpaceOnUse"});
    pat.appendChild(el("rect",{width:6,height:6,fill:s.color,opacity:.30}));
    pat.appendChild(el("line",{x1:0,y1:0,x2:0,y2:6,stroke:s.color,"stroke-width":3}));
    defs.appendChild(pat);
  });
  svg.appendChild(defs);
  yAxis(svg, max, padL, padT, plotH, width, padR, max<10?1:0);
  const yl = el("text",{x:12,y:padT+plotH/2,class:"axl","text-anchor":"middle",
                        transform:`rotate(-90 12 ${padT+plotH/2})`});
  yl.textContent = opts.yLabel||"TBtu"; svg.appendChild(yl);

  rows.forEach((r,i)=>{
    const x0 = padL+i*catSlot+(catSlot-slot)/2;   // centred in its slot
    // Significance dimming: fade groups whose primary-run value sits inside the
    // CBECS 95% CI, so attention lands only on significant gaps.
    const dimmed = state.dimSig && r.ciLow!==null && r.ciLow!==undefined
      && r.values[PRIMARY]!==null && r.values[PRIMARY]!==undefined
      && r.values[PRIMARY]>=r.ciLow && r.values[PRIMARY]<=r.ciHigh;
    series.forEach((s,j)=>{
      const v = r.values[s.key];
      if(v===null||v===undefined||Number.isNaN(v)) return;
      const x = x0+j*(bw+inner);
      const fill = (s.hatch && r.hatched) ? `url(#h-${host.id}-${s.key})` : s.color;
      // Square corners and a hairline separator: touching bars with a 4px radius
      // and a 2px outset read as gapped lozenges rather than one grouped bar.
      const rect = el("rect",{x, y:y(v), width:bw, height:Math.max(y(0)-y(v),0),
        fill, stroke:"var(--panel)","stroke-width":0.8, opacity:dimmed?.22:1});
      rect.addEventListener("mousemove", ev => showTip(
        `<b>${r.label}</b>` +
        series.map(s2=>`<div class="row"><span>${s2.label}</span><span>${fmt(r.values[s2.key],2)}</span></div>`).join("") +
        (r.ciLow!==null&&r.ciLow!==undefined
          ? `<div class="row"><span>CBECS 95% CI</span><span>${fmt(r.ciLow,2)}–${fmt(r.ciHigh,2)}</span></div>`:"") +
        (r.note?`<div class="row"><span>${r.note}</span><span></span></div>`:""), ev));
      rect.addEventListener("mouseleave", hideTip);
      svg.appendChild(rect);
    });
    if(r.ciLow!==null&&r.ciLow!==undefined&&r.ciHigh){
      const ciIdx = series.findIndex(s=>s.ci);
      if(ciIdx>=0){
        const cx = x0+ciIdx*(bw+inner)+bw/2;
        const g = el("g",{stroke:"var(--ink-2)","stroke-width":1.5,fill:"none"});
        g.appendChild(el("line",{x1:cx,y1:y(r.ciLow),x2:cx,y2:y(r.ciHigh)}));
        g.appendChild(el("line",{x1:cx-5,y1:y(r.ciHigh),x2:cx+5,y2:y(r.ciHigh)}));
        g.appendChild(el("line",{x1:cx-5,y1:y(r.ciLow),x2:cx+5,y2:y(r.ciLow)}));
        svg.appendChild(g);
      }
    }
    const lx = x0+slot/2+6, ly = H-padB+18;
    tickLabel(svg, lx, ly, r.label, plan);
  });
  svg.appendChild(el("line",{x1:padL-6,y1:y(0),x2:width-padR,y2:y(0),class:"zero"}));
  plotFrame(svg, padL, padT, width-padR-padL, H-padT-padB);
  host.innerHTML=""; attachChart(host, svg, opts.copy);
}

/* mount a chart with right-aligned Fullscreen + Copy buttons above it */
/* Plot-area frame on all four sides, like the matplotlib subplots in the
   ComStock figures: it makes a chart read as a finished figure rather than
   floating marks, and it travels into the PNG export. Appended last so bars
   and lines cannot paint over it. */
/* ---------- rotated x tick labels ----------
   ONE angle for every categorical axis in the dashboard: 45 degrees.
   Rotated labels are PARALLEL, so two of them overlap only when the
   perpendicular gap between their baselines — slot*sin(45) — is smaller than
   the text height (~13 units), never because a label is long. The previous
   version escalated to vertical for long labels, which cost MORE vertical room
   (a label's vertical extent is L*sin(angle), and sin(90) > sin(45)) and made
   the axes read differently from one panel to the next. The bottom pad is sized
   from the real label extent, and a label past the cap is clipped with the full
   text kept in a tooltip. */
const TICK_CHAR_W = 5.6;               // ~11.5px sans, average glyph advance
const TICK_ANGLE = 45;
function tickPlan(labels, slot, capPx){
  const cap = capPx || 130;
  const longest = (labels||[]).reduce((m,s)=>Math.max(m,String(s==null?"":s).length),0)
    * TICK_CHAR_W;
  const shown = Math.min(longest, cap);
  return {angle: TICK_ANGLE, dx: 4,
          pad: Math.ceil(shown*Math.sin(Math.PI*TICK_ANGLE/180)) + 18,
          maxChars: Math.max(4, Math.floor(cap/TICK_CHAR_W))};
}
function tickLabel(svg, x, y, text, plan, style){
  const s = String(text==null?"":text);
  const t = el("text",{x, y, class:"ax", "text-anchor":"end",
    transform:`rotate(-${plan.angle} ${x} ${y})`});
  if(style) t.setAttribute("style", style);
  const clipped = s.length>plan.maxChars ? s.slice(0,plan.maxChars-1)+"\u2026" : s;
  t.textContent = clipped;
  if(clipped!==s){ const ti=el("title"); ti.textContent=s; t.appendChild(ti); }
  svg.appendChild(t);
  return t;
}

function plotFrame(svg, x, y, w, h){
  svg.appendChild(el("rect",{x, y, width:Math.max(w,1), height:Math.max(h,1),
    fill:"none", stroke:"var(--ink-2)", "stroke-width":1, "pointer-events":"none"}));
}

/* One legend renderer for the fullscreen overlay and the side rail, taking the
   same items the PNG export already receives — so a chart's on-screen legend,
   its expanded legend, and its exported legend can never disagree. */
function legendHTML(items, opts={}){
  if(!items||!items.length) return "";
  const row=i=>{
    // `chip` items carry the real fuel hatch, so the expanded legend shows the
    // same texture as the plot rather than a generic 45-degree stand-in.
    const sw = i.line
      ? `<span style="width:16px;height:0;border-top:${i.dash?"3px dashed":"3px solid"} ${
          i.color};display:inline-block;flex:none"></span>`
      : i.chip
      ? hatchChip(i.color,i.pattern)
      : `<span class="sw" style="background:${i.color}${i.hatch
          ?`;background-image:repeating-linear-gradient(45deg,rgba(255,255,255,.75),rgba(255,255,255,.75) 2px,transparent 2px,transparent 4px)`
          :""}"></span>`;
    return `<span class="key" style="white-space:nowrap">${sw}${i.label}</span>`;
  };
  return `<div class="legend" style="${opts.column
    ? "flex-direction:column;align-items:flex-start;gap:5px 0;flex-wrap:nowrap"
    : ""}">${items.map(row).join("")}</div>`;
}
/* `charts` is one or more {svg,label}: a single chart, or every subplot of a
   family expanded together the way the output folder shows them. */
function fullscreenChart(charts, legendItems, title){
  const list=Array.isArray(charts)?charts.filter(c=>c.svg):[{svg:charts}];
  if(!list.length) return;
  const many=list.length>1;
  const ov=document.createElement("div");
  ov.style.cssText="position:fixed;inset:0;z-index:80;background:var(--surface);"+
    "overflow:auto;padding:26px;cursor:zoom-out";
  const inner=document.createElement("div");
  inner.style.cssText="min-height:100%;display:flex;flex-direction:column;"+
    "align-items:center;justify-content:center;gap:10px";
  if(title){
    const h=document.createElement("div");
    h.style.cssText="font-size:15px;font-weight:600;color:var(--ink);text-align:center";
    h.textContent=title; inner.appendChild(h);
  }
  const wrap=document.createElement("div");
  // side-by-side for a subplot family, one big chart otherwise
  wrap.style.cssText=many
    ? "display:flex;flex-wrap:wrap;gap:14px;align-items:flex-start;justify-content:center"
    : "display:block";
  list.forEach(c=>{
    const cell=document.createElement("div");
    if(c.label&&many){
      const lb=document.createElement("div");
      lb.style.cssText="font-size:13px;font-weight:600;color:var(--ink);margin-bottom:2px;"+
        "text-align:center";
      lb.textContent=c.label; cell.appendChild(lb);
    }
    const clone=c.svg.cloneNode(true);
    clone.style.cssText=many
      ? `width:min(${Math.floor(92/Math.min(list.length,3))}vw,760px);height:auto`
      : "width:min(94vw,1700px);max-height:82vh;height:auto";
    cell.appendChild(clone);
    wrap.appendChild(cell);
  });
  inner.appendChild(wrap);
  if(legendItems&&legendItems.length){
    const lg=document.createElement("div");
    lg.style.cssText="max-width:min(94vw,1400px)";
    lg.innerHTML=legendHTML(legendItems);
    inner.appendChild(lg);
  }
  ov.appendChild(inner);
  const hint=document.createElement("div");
  hint.style.cssText="position:fixed;top:10px;right:16px;font-size:12px;color:var(--ink-3)";
  hint.textContent="click or Esc to close";
  ov.appendChild(hint);
  const esc=e=>{ if(e.key==="Escape") close(); };
  const close=()=>{ ov.remove(); document.removeEventListener("keydown",esc); };
  ov.addEventListener("click",close);
  document.addEventListener("keydown",esc);
  document.body.appendChild(ov);
}
function attachChart(host, svg, copy){
  const bar=document.createElement("div");
  bar.className="chart-ctl";
  const fs=document.createElement("button");
  fs.className="btn-mini"; fs.textContent="⛶"; fs.title="Full screen";
  // the export legend doubles as the expanded legend
  fs.addEventListener("click",()=>fullscreenChart(svg,(copy||{}).legend,(copy||{}).title));
  bar.appendChild(fs);
  if(copy){
    const b=document.createElement("button"); b.className="btn-mini"; b.textContent="Copy";
    bar.appendChild(b);
    wireCopy(b, ()=>[{svg}], 1, copy.title, copy.legend||[]);
  }
  /* Controls go on the chart's TITLE line, always. They used to occupy a band of
     their own between the title and the plot, which put them in a different
     place on every panel — right-aligned to the figure, so their position moved
     with the figure's width — and a reader had to hunt for them. On the title
     line they are in one predictable spot: the top-right of the panel's header,
     next to the name of the thing they act on. */
  const prev=host.previousElementSibling;
  if(prev && prev.classList && prev.classList.contains("head")){
    prev.appendChild(bar);                       // existing flex header row
  } else if(prev && /^H[2-4]$/.test(prev.tagName)){
    const row=document.createElement("div");
    row.className="head chart-title-row";
    prev.parentNode.insertBefore(row, prev);
    row.appendChild(prev);
    row.appendChild(bar);
  } else {
    /* Untitled chart: still give the control its own right-aligned header row,
       so it lands in the same place as the other 48 rather than floating above
       the plot on its own. */
    const row=document.createElement("div");
    row.className="head chart-title-row";
    row.appendChild(bar);
    host.appendChild(row);
  }
  host.appendChild(svg);
}

/* Group header: one ⛶ and one Copy covering every subplot of a family, so a
   three-panel emissions figure expands and copies as the single figure it is
   in the output folder. `hosts` are element ids in display order. */
function groupControls(id){
  return `<span class="spacer"></span><button class="btn-mini" data-gfs="${id}"
    title="Expand all panels">⛶ all</button>
    <button class="btn-mini" data-gcopy="${id}">Copy all</button>`;
}
const GROUPS={};
function registerGroup(id, hostIds, labels, legendItems, title, cols){
  GROUPS[id]={hostIds, labels, legendItems, title, cols:cols||hostIds.length};
}
/* Variant for grids built by appending chartboxes (the AMI and measure
   timeseries panels), where the subplots have no ids of their own: the charts
   and their captions are read out of the container at click time. */
function registerGroupContainer(id, containerSel, legendItems, title, cols){
  GROUPS[id]={containerSel, legendItems, title, cols:cols||2};
}
function groupCharts(g){
  if(g.charts) return g.charts.filter(c=>c.svg);
  if(g.containerSel){
    const c=$(g.containerSel);
    if(!c) return [];
    return [...c.querySelectorAll(".chartbox")].map(b=>({
      svg:b.querySelector("svg"),
      label:(b.querySelector("h3")||{}).textContent||""}));
  }
  return g.hostIds.map((h,i)=>({svg:$(`#${h} svg`),label:g.labels[i]}));
}
/* A group of ONE is not a group: its "⛶ all / Copy all" pair does exactly what
   the chart's own "⛶ / Copy" pair does, so the section showed two identical
   controls and the word "all" promised a family that was not there. Whether a
   family has one member or three is only known once the charts are rendered
   (the single-measure energy panels are one chart each; the emissions and bill
   families are three), so the decision is made here rather than in markup. */
function pruneSoloGroupControls(){
  document.querySelectorAll("[data-gfs],[data-gcopy]").forEach(b=>{
    const g=GROUPS[b.dataset.gfs||b.dataset.gcopy];
    if(g && groupCharts(g).length<=1){
      // drop the leading spacer too, or the head keeps its pushed-apart layout
      const sp=b.previousElementSibling;
      if(sp&&sp.className==="spacer") sp.remove();
      b.remove();
    }
  });
}
/* Use the slack in a row of small multiples. Every figure is laid out at 1:1
   and then, if its row leaves space, the whole row is magnified UNIFORMLY to
   fill it — the SVG is simply given a larger CSS width, and the viewBox turns
   that into proportional growth of the marks AND the text together. It is not a
   re-layout: the bars do not fatten and the gaps do not stretch, so the figure
   keeps the proportions it was designed with and only gets easier to read
   without expanding it.
   Figures are never scaled DOWN here — down-scaling is what put the by-category
   axis labels at 6px. The viewBox is the source of truth for the 1:1 size, so
   running this twice is idempotent. */
const MAX_FIG_SCALE = 1.35;
const ROW_SELECTOR = ".grid3fit,.grid2,.grid-dist,.chart-pair,.ami-grid";
function fillRows(){
  const vbW = s => parseFloat(String(s.getAttribute("viewBox")).split(/\s+/)[2]);
  const figs=[...document.querySelectorAll("svg[viewBox]")].filter(s=>{
    if(s.closest(".legend")) return false;                    // legend chips
    if(/max-width:\s*none/.test(s.getAttribute("style")||"")) return false;  // fixed + scroll
    return vbW(s)>60;                                         // not a swatch
  });
  if(!figs.length) return;
  // Back to 1:1 first, so grouping is done on the unscaled layout and running
  // this a second time cannot compound the magnification.
  figs.forEach(s=>{ s.style.width=vbW(s)+"px"; });
  // A visual row = figures sharing a top edge inside the same panel.
  const panels=[...document.querySelectorAll(".panel")];
  const groups=new Map();
  figs.forEach(s=>{
    const p=s.closest(".panel");
    const key=`${panels.indexOf(p)}:${Math.round(s.getBoundingClientRect().top+scrollY)}`;
    if(!groups.has(key)) groups.set(key,[]);
    groups.get(key).push(s);
  });
  groups.forEach(group=>{
    /* Room available to the row. A .chart-pair sits inside a content-sized
       .chart-main, so its own width is only what the figures already occupy —
       the room is the chart row minus the legend rail. */
    let avail=0;
    const cr=group[0].closest(".chart-row");
    if(cr){
      const side=cr.querySelector(".chart-side");
      const crGap=parseFloat(getComputedStyle(cr).gap)||0;
      avail=cr.clientWidth-(side?side.getBoundingClientRect().width+crGap:0);
    } else {
      const p=group[0].closest(".panel"); if(!p) return;
      const pcs=getComputedStyle(p);
      avail=p.clientWidth-(parseFloat(pcs.paddingLeft)||0)-(parseFloat(pcs.paddingRight)||0);
    }
    const row=group[0].closest(ROW_SELECTOR);
    const gap=row?(parseFloat(getComputedStyle(row).gap)||0):0;
    const w=group.map(vbW);
    const total=w.reduce((a,b)=>a+b,0)+gap*(group.length-1);
    if(!(total>0)||!(avail>0)) return;
    const k=Math.min(MAX_FIG_SCALE, avail/total);
    if(k<=1.01) return;
    group.forEach((s,i)=>{ s.style.width=Math.floor(w[i]*k)+"px"; });
    /* Some containers cannot grow with their figure — a grid with fixed px
       tracks, for one — and a figure that outgrows its slot draws over its
       neighbour. Check for that and back the whole row off to 1:1 rather than
       ship an overlap. */
    const spilled=group.some(s=>{
      const p=s.parentElement;
      return p && p.clientWidth>0 && s.getBoundingClientRect().width>p.clientWidth+1;
    });
    if(spilled) group.forEach((s,i)=>{ s.style.width=w[i]+"px"; });
  });
}
/* Line the legend rail up with the TOP OF THE PLOT FRAME, not with the top of
   the chart column. The column carries a subplot heading above its plot, so a
   fixed padding left the legend floating a heading's height too high. Measured
   rather than guessed, because the heading wraps to two lines at some widths. */
function alignLegendRails(){
  document.querySelectorAll(".chart-row").forEach(row=>{
    const side=row.querySelector(".chart-side");
    const main=row.querySelector(".chart-main");
    if(!side||!main) return;
    const svg=main.querySelector("svg[viewBox]");
    if(!svg) return;
    const frame=[...svg.querySelectorAll("rect")].find(r=>
      r.getAttribute("fill")==="none"&&r.getAttribute("stroke")==="var(--ink-2)");
    if(!frame) return;
    side.style.paddingTop="0px";
    const frameTop=frame.getBoundingClientRect().top;
    const railTop=side.getBoundingClientRect().top;
    side.style.paddingTop=Math.max(0,Math.round(frameTop-railTop))+"px";
  });
}
let FILL_TIMER=null;
addEventListener("resize",()=>{ clearTimeout(FILL_TIMER);
  FILL_TIMER=setTimeout(()=>{ fillRows(); alignLegendRails(); },120); });
function wireGroups(){
  pruneSoloGroupControls();
  fillRows();
  alignLegendRails();
  document.querySelectorAll("[data-gfs]").forEach(b=>b.addEventListener("click",ev=>{
    ev.stopPropagation();
    const g=GROUPS[b.dataset.gfs]; if(!g) return;
    fullscreenChart(groupCharts(g), g.legendItems, g.title);
  }));
  document.querySelectorAll("[data-gcopy]").forEach(b=>{
    const g=GROUPS[b.dataset.gcopy]; if(!g) return;
    wireCopy(b, ()=>groupCharts(g), g.cols, g.title, g.legendItems||[]);
  });
}

/* ---------- box plot: p05/p25/p50/p75/p95 per dataset per category ---------- */
function boxPlot(host, cats, series, opts={}){
  const padL=58, padR=12, padT=10;
  if(!cats.length){ host.innerHTML='<p class="note">No distribution data.</p>'; return; }
  // Bar width is capped, and the SVG is given an explicit pixel width, so a
  // one-category view renders at natural size instead of being stretched to the
  // panel. Wide charts overflow into the .scroll container.
  const k=series.length, inner=4, gap=opts.compact?12:14;
  const n=cats.length;
  const bw=Math.max(6, Math.min(opts.compact?14:28, (opts.compact?320:600)/(n*k)));
  const slot=k*bw+(k-1)*inner;
  const plan = tickPlan(cats.map(c=>c.label), slot+gap);
  const padB = plan.pad;
  const catSlot=slot+gap;                      // equal slots, group centred
  const plotW=n*catSlot;
  const width=padL+padR+plotW;
  const H=(opts.height||300) + Math.max(0, padB-88), plotH=H-padT-padB;
  /* The scale must clear whatever is actually drawn: the violin tail and any
     outlier dot reach past p95, and clipping them would misrepresent the
     spread rather than merely look wrong. */
  const vals = cats.flatMap(c=>series.map(s=>c.stats[s.key]).filter(Boolean).flatMap(v=>{
    const kd=parseKde(v.kde);
    return [v.p95].concat(kd?[kd.x1]:[]).concat(parseOutliers(v.outliers));
  }));
  const max = Math.max(...vals.filter(v=>Number.isFinite(v)), 1e-9)*1.05;
  const y = v => padT+plotH-(v/max)*plotH;
  // Compact charts scale DOWN to their container so side-by-side panels need no
  // scroll bars; they never scale up past natural size. Full-width charts keep a
  // fixed width and scroll, since shrinking 15 categories makes labels unreadable.
  const svg = el("svg",{viewBox:`0 0 ${width} ${H}`,
    style: opts.compact ? figStyle(width) : `width:${width}px;max-width:none`});
  yAxis(svg, max, padL, padT, plotH, width, padR, 0);
  const yl = el("text",{x:12,y:padT+plotH/2,class:"axl","text-anchor":"middle",
                        transform:`rotate(-90 12 ${padT+plotH/2})`});
  yl.textContent = opts.yLabel||"kBtu/ft²·yr"; svg.appendChild(yl);

  cats.forEach((c,i)=>{
    const x0=padL+i*catSlot+(catSlot-slot)/2;   // centred in its slot
    series.forEach((s,j)=>{
      const st=c.stats[s.key]; if(!st) return;
      const x=x0+j*(bw+inner), cx=x+bw/2;
      const g=el("g");
      /* Same style as the savings-distribution figures, turned on its side:
         KDE violin behind, box in front, median solid, MEAN DASHED, whiskers
         across p05..p95, 1.5-IQR outliers as dots. Drawn only where the
         pipeline stored a density computed from the raw per-building values. */
      const kd=parseKde(st.kde);
      if(kd){
        const half=bw*0.92, nP=kd.d.length;
        /* A KDE pads two bandwidths past the data, so a right-skewed EUI
           density runs negative — and this axis starts at 0. Clamp to the axis
           domain so the violin is truncated at the frame instead of drawn
           outside it. */
        const vAt=idx=>Math.min(max, Math.max(0, kd.x0+(kd.x1-kd.x0)*idx/(nP-1)));
        let left="", right="";
        for(let q=0;q<nP;q++) left+=`${q?"L":"M"}${(cx-kd.d[q]*half).toFixed(1)},${y(vAt(q)).toFixed(1)}`;
        for(let q=nP-1;q>=0;q--) right+=`L${(cx+kd.d[q]*half).toFixed(1)},${y(vAt(q)).toFixed(1)}`;
        g.appendChild(el("path",{d:left+right+"Z", fill:"var(--grid)",
          stroke:"var(--ink-2)","stroke-width":0.8,"pointer-events":"none"}));
      }
      // whiskers p05..p95
      g.appendChild(el("line",{x1:cx,y1:y(st.p05),x2:cx,y2:y(st.p95),
        stroke:"var(--ink-2)","stroke-width":1,opacity:.85}));
      [st.p05,st.p95].forEach(v=>g.appendChild(el("line",{x1:cx-bw/4,y1:y(v),x2:cx+bw/4,y2:y(v),
        stroke:"var(--ink-2)","stroke-width":1,opacity:.85})));
      // IQR box
      g.appendChild(el("rect",{x, y:y(st.p75), width:bw, height:Math.max(y(st.p25)-y(st.p75),1),
        fill:s.color, stroke:"var(--ink-2)", "stroke-width":0.9}));
      // median solid, mean dashed
      g.appendChild(el("line",{x1:x,y1:y(st.p50),x2:x+bw,y2:y(st.p50),
        stroke:"#111","stroke-width":1.6}));
      if(Number.isFinite(st.mean))
        g.appendChild(el("line",{x1:x,y1:y(st.mean),x2:x+bw,y2:y(st.mean),
          stroke:"#111","stroke-width":1.4,"stroke-dasharray":"2.5 2"}));
      parseOutliers(st.outliers).filter(v=>v>=0&&v<=max).forEach(v=>g.appendChild(el("circle",
        {cx, cy:y(v), r:1.15, fill:"var(--ink-2)","pointer-events":"none"})));
      g.addEventListener("mousemove", ev=>showTip(
        `<b>${c.label} · ${s.label}</b>`+
        `<div class="row"><span>p95</span><span>${fmt(st.p95,0)}</span></div>`+
        `<div class="row"><span>p75</span><span>${fmt(st.p75,0)}</span></div>`+
        `<div class="row"><span>median</span><span>${fmt(st.p50,0)}</span></div>`+
        `<div class="row"><span>p25</span><span>${fmt(st.p25,0)}</span></div>`+
        `<div class="row"><span>p05</span><span>${fmt(st.p05,0)}</span></div>`+
        `<div class="row"><span>mean (dashed)</span><span>${fmt(st.mean,0)}</span></div>`+
        `<div class="row"><span>models sampled</span><span>${fmt(st.n_models,0)}</span></div>`, ev));
      g.addEventListener("mouseleave", hideTip);
      svg.appendChild(g);
    });
    const lx=x0+slot/2+6, ly=H-padB+18;
    tickLabel(svg, lx, ly, c.label, plan);
  });
  svg.appendChild(el("line",{x1:padL-6,y1:y(0),x2:width-padR,y2:y(0),class:"zero"}));
  plotFrame(svg, padL, padT, width-padR-padL, H-padT-padB);
  host.innerHTML=""; attachChart(host, svg, opts.copy);
}

/* ---------- overlaid step histograms ---------- */
function histChart(host, bins, series, opts={}){
  opts={yLabel:"Share of weighted total", ...opts};
  const W=680,H=250,padL=58,padR=14,padT=12,padB=44;
  const keys = series.map(s=>s.key);
  const any = bins.some(b=>keys.some(k=>b.shares[k]!==undefined));
  if(!bins.length||!any){ host.innerHTML='<p class="note">No histogram data.</p>'; return; }
  const plotW=W-padL-padR, plotH=H-padT-padB;
  const xMax=bins[bins.length-1].right, xMin=bins[0].left;
  const yMax=Math.max(...bins.flatMap(b=>keys.map(k=>b.shares[k]||0)),1e-9)*1.1;
  const x=v=>padL+((v-xMin)/(xMax-xMin))*plotW, y=v=>padT+plotH-(v/yMax)*plotH;
  // No style at all meant the global `svg{width:100%}` rule stretched this one
  // to the full panel — a 680-unit figure at 1098px, magnifying its text to 18px.
  const svg=el("svg",{viewBox:`0 0 ${W} ${H}`, style:figStyle(W)});
  for(let i=0;i<=4;i++){
    const v=yMax*i/4, yy=y(v);
    svg.appendChild(el("line",{x1:padL,y1:yy,x2:W-padR,y2:yy,class:"gl"}));
    const t=el("text",{x:padL-8,y:yy+4,class:"ax","text-anchor":"end"});
    t.textContent=(v*100).toFixed(0)+"%"; svg.appendChild(t);
  }
  for(let i=0;i<=5;i++){
    const v=xMin+(xMax-xMin)*i/5;
    const t=el("text",{x:x(v),y:H-padB+16,class:"ax","text-anchor":"middle"});
    t.textContent=fmt(v,0); svg.appendChild(t);
  }
  const xl=el("text",{x:padL+plotW/2,y:H-6,class:"axl","text-anchor":"middle"});
  xl.textContent=opts.xLabel||"kBtu/ft²·yr"; svg.appendChild(xl);
  const ylb=el("text",{x:12,y:padT+plotH/2,class:"axl","text-anchor":"middle",
    transform:`rotate(-90 12 ${padT+plotH/2})`});
  ylb.textContent=opts.yLabel; svg.appendChild(ylb);
  series.forEach(s=>{
    let d=`M${x(bins[0].left)},${y(0)}`;
    bins.forEach(b=>{
      const v=b.shares[s.key]; if(v===undefined) return;
      d+=`L${x(b.left)},${y(v)}L${x(b.right)},${y(v)}`;
    });
    d+=`L${x(bins[bins.length-1].right)},${y(0)}Z`;
    svg.appendChild(el("path",{d,fill:s.color,opacity:.22}));
    svg.appendChild(el("path",{d,fill:"none",stroke:s.color,"stroke-width":2,
      "stroke-linejoin":"round"}));
  });
  const hit=el("rect",{x:padL,y:padT,width:plotW,height:plotH,fill:"transparent"});
  hit.addEventListener("mousemove", ev=>{
    const bb=svg.getBoundingClientRect();
    const vx=xMin+((ev.clientX-bb.left)/bb.width*W-padL)/plotW*(xMax-xMin);
    const b=bins.find(b0=>vx>=b0.left&&vx<b0.right); if(!b) return;
    showTip(`<b>${fmt(b.left,0)}–${fmt(b.right,0)} kBtu/ft²</b>`+
      series.map(s=>`<div class="row"><span>${s.label}</span><span>${
        b.shares[s.key]===undefined?ABSENT.noValue:(b.shares[s.key]*100).toFixed(1)+"%"}</span></div>`).join(""), ev);
  });
  hit.addEventListener("mouseleave", hideTip);
  svg.appendChild(hit);
  plotFrame(svg, padL, padT, plotW, plotH);
  host.innerHTML=""; attachChart(host, svg, opts.copy);
}

/* ONE y scale for a grid of small multiples, computed the same way profileChart
   computes its own so the two cannot disagree. Six seasonal panels each
   autoscaled to itself cannot be read against each other, which is the only
   reason to put them in a grid in the first place. */
function sharedProfileMax(panels){
  let m=0;
  panels.forEach(({sub,opts})=>{
    (sub||[]).forEach(p=>{
      [p.comstock,p.ami,p.amiHi,p.comstock2]
        .concat(((opts||{}).extraLines||[]).map(l=>p[l.key]))
        .forEach(v=>{ if(v!==null&&v!==undefined&&isFinite(v)&&v>m) m=v; });
    });
  });
  return m>0 ? m*1.1 : 1;
}
/* ---------- 24-h profile: stacked ComStock end uses + AMI line & CI band ---------- */
function profileChart(host, pts, opts={}){
  const W=330,H=182,padR=10,padT=10,padB=40;
  const plotH=H-padT-padB;
  const stack = opts.stack && opts.stackKeys && opts.stackKeys.length;
  const vals = pts.flatMap(p=>[p.comstock,p.ami,p.amiHi,p.comstock2]
      .concat((opts.extraLines||[]).map(l=>p[l.key])))
    .filter(v=>v!==null&&v!==undefined);
  if(!vals.length){ host.innerHTML='<p class="note">No overlap.</p>'; return; }
  /* An end use that is exactly zero over the whole selection — heat rejection on
     a narrow applicability intersection, say — is a legitimate result, but it
     made `max` 0, so every tick and every path coordinate became 0/0 = NaN and
     the panel drew its frame, axes and band with NO series at all. Give the axis
     a unit span in that case so the series draws flat along the baseline, which
     is what "zero everywhere" should look like. */
  const rawMax = Math.max(...vals);
  /* `opts.yMax` lets a grid of small multiples share ONE scale: six seasonal
     panels each autoscaled to itself cannot be compared by eye, which is the
     only reason to put them in a grid. */
  const max = opts.yMax || (rawMax>0 ? rawMax*1.1 : 1);
  // Constant decimals per axis, chosen so the top tick has two significant
  // figures — every tick on one axis then shows the same digit count, and
  // annual-normalized ticks (~1e-4) stay distinct.
  const dec = Math.min(6, Math.max(0, 1-Math.floor(Math.log10(max))));
  const tickFmt = v => v.toFixed(dec);
  // padL after the tick format is known, so it fits the labels it must clear
  const padL = axisPadL([0,1,2,3].map(i=>tickFmt(max*i/3)), true);
  const plotW = W-padL-padR;
  const x=h=>padL+(h/23)*plotW, y=v=>padT+plotH-(v/max)*plotH;
  // Needs figStyle like every other figure: without it the global
  // `svg{width:100%}` rule sized this one to whatever box it landed in, and
  // nothing capped it when the row-fill pass widened it — in a grid with fixed
  // 310px tracks the seasonal panels then drew over each other.
  const svg=el("svg",{viewBox:`0 0 ${W} ${H}`, style:figStyle(W)});
  for(let i=0;i<=3;i++){
    const v=max*i/3, yy=y(v);
    svg.appendChild(el("line",{x1:padL,y1:yy,x2:W-padR,y2:yy,class:"gl"}));
    const t=el("text",{x:padL-7,y:yy+4,class:"ax","text-anchor":"end"});
    t.textContent=tickFmt(v); svg.appendChild(t);
  }
  [0,6,12,18,23].forEach(h=>{
    const t=el("text",{x:x(h),y:H-padB+15,class:"ax","text-anchor":"middle"});
    t.textContent=h; svg.appendChild(t);
  });
  // Units on a profile subplot depend on the caller (kWh/ft², a normalized
  // fraction, or MW), so both axes are labeled explicitly rather than left as
  // bare numbers.
  const xl=el("text",{x:padL+plotW/2,y:H-3,class:"axl","text-anchor":"middle"});
  xl.textContent=opts.xLabel||"Hour of day"; svg.appendChild(xl);
  if(opts.yLabel){
    const ylb=el("text",{x:11,y:padT+plotH/2,class:"axl","text-anchor":"middle",
      transform:`rotate(-90 11 ${padT+plotH/2})`});
    ylb.textContent=opts.yLabel; svg.appendChild(ylb);
  }
  // overnight band (hours 0-5) — screen only; the export strips it (class
  // "band"), since without the caption it reads as an artifact in a report.
  svg.appendChild(el("rect",{x:x(0),y:padT,width:x(5)-x(0),height:plotH,
    fill:"var(--ink-3)",opacity:.055,class:"band"}));

  if(stack){
    // Stack layers are clipped to the plot area: under min-max normalization the
    // stack's baseline sits below zero (the daily minimum has been subtracted),
    // while layer thicknesses and the stack top stay exact.
    const clipId = `clip-${host.id}`;
    const defs = el("defs");
    const cp = el("clipPath",{id:clipId});
    cp.appendChild(el("rect",{x:padL,y:padT,width:plotW,height:plotH}));
    defs.appendChild(cp); svg.appendChild(defs);
    const layer = el("g",{"clip-path":`url(#${clipId})`});
    let base = pts.map(()=>opts.stackBase||0);
    opts.stackKeys.forEach(k=>{
      const top = pts.map((p,i)=>base[i]+(p.eu[k]||0));
      let d = `M${x(pts[0].hour)},${y(base[0])}`;
      pts.forEach((p,i)=>{ d+=`L${x(p.hour)},${y(top[i])}`; });
      for(let i=pts.length-1;i>=0;i--) d+=`L${x(pts[i].hour)},${y(base[i])}`;
      d+="Z";
      const path=el("path",{d,fill:D.enduseColors[k]||"#888",opacity:.92,
        stroke:"var(--panel)","stroke-width":.4});
      path.addEventListener("mousemove", ev=>showTip(
        `<b>${k.replace(/_/g," ")}</b><div class="row"><span>OpenStudio end use</span>`+
        `<span style="display:inline-block;width:10px;height:10px;border-radius:2px;background:${D.enduseColors[k]}"></span></div>`, ev));
      path.addEventListener("mouseleave", hideTip);
      layer.appendChild(path);
      base = top;
    });
    svg.appendChild(layer);
  }
  const line=(key,color,dash,width)=>{
    const d=pts.filter(p=>p[key]!==null&&p[key]!==undefined)
      .map((p,i)=>`${i?"L":"M"}${x(p.hour).toFixed(1)},${y(p[key]).toFixed(1)}`).join(" ");
    svg.appendChild(el("path",{d,fill:"none",stroke:color,"stroke-width":width||2,
      "stroke-linejoin":"round","stroke-linecap":"round",...(dash?{"stroke-dasharray":dash}:{})}));
  };
  // AMI 80% CI as dashed lines, matching the repo's comparison plots. The
  // uncertainty is multiplicative, so the lines are valid in every scale mode.
  if(pts.some(p=>p.amiHi!==null&&p.amiHi!==undefined)){
    line("amiHi","var(--ink)","4 3",1.3);
    line("amiLo","var(--ink)","4 3",1.3);
  }
  // With a full stack the stack top IS the ComStock total, so no separate line
  // is drawn. When end uses are filtered out the top no longer means that, and
  // the total has to be drawn explicitly or it disappears from the figure.
  if(!stack || opts.showTotalLine) line("comstock", opts.comstockColor||"#0072B2","");
  if(pts.some(p=>p.comstock2!==null&&p.comstock2!==undefined))
    line("comstock2", opts.comstock2Color||"#56B4E9","7 4",2);
  (opts.extraLines||[]).forEach(l=>{
    if(pts.some(p=>p[l.key]!==null&&p[l.key]!==undefined))
      line(l.key, l.color, l.dash===undefined?"7 4":l.dash, l.width||2);
  });
  if(pts.some(p=>p.ami!==null&&p.ami!==undefined)) line("ami","var(--ink)","");
  // axes spines on all four sides, like the repo's matplotlib subplots
  svg.appendChild(el("rect",{x:padL,y:padT,width:plotW,height:plotH,
    fill:"none",stroke:"var(--ink-2)","stroke-width":1}));
  const cross=el("line",{x1:0,y1:padT,x2:0,y2:padT+plotH,stroke:"var(--ink-3)",
    "stroke-width":1,opacity:0});
  svg.appendChild(cross);
  const hit=el("rect",{x:padL,y:padT,width:plotW,height:plotH,fill:"transparent"});
  hit.addEventListener("mousemove", ev=>{
    const bb=svg.getBoundingClientRect();
    const rel=(ev.clientX-bb.left)/bb.width*W;
    const h=Math.max(0,Math.min(23,Math.round((rel-padL)/plotW*23)));
    const p=pts.find(q=>q.hour===h); if(!p) return;
    cross.setAttribute("x1",x(h)); cross.setAttribute("x2",x(h)); cross.setAttribute("opacity",1);
    const rel_=(p.rawComstock!==null&&p.rawAmi)?(p.rawComstock-p.rawAmi)/p.rawAmi*100:null;
    let html = `<b>${opts.title||""} · hour ${h}</b>`;
    if(opts.normalized){
      html += `<div class="row"><span>ComStock (norm)</span><span>${fmt(p.comstock,4)}</span></div>`+
              `<div class="row"><span>AMI (norm)</span><span>${fmt(p.ami,4)}</span></div>`+
              `<div class="row"><span>kWh/ft² ComStock</span><span>${fmt(p.rawComstock,4)}</span></div>`+
              `<div class="row"><span>kWh/ft² AMI</span><span>${fmt(p.rawAmi,4)}</span></div>`;
      const top = opts.stackKeys.map(k=>[k,p.eu[k]||0]).sort((a,b)=>b[1]-a[1]).slice(0,3);
      html += top.map(([k,v])=>`<div class="row"><span>&nbsp;&nbsp;${k.replace(/_/g," ")}</span><span>${fmt(v,4)}</span></div>`).join("");
    } else {
      html += `<div class="row"><span>${opts.baseLabel||"ComStock total"}</span><span>${fmt(p.rawComstock,4)}</span></div>`;
      if(p.rawAmi!==null&&p.rawAmi!==undefined)
        html += `<div class="row"><span>AMI metered</span><span>${fmt(p.rawAmi,4)}</span></div>`;
      if(stack){
        const top = opts.stackKeys.map(k=>[k,p.eu[k]||0]).sort((a,b)=>b[1]-a[1]).slice(0,3);
        html += top.map(([k,v])=>`<div class="row"><span>&nbsp;&nbsp;${k.replace(/_/g," ")}</span><span>${fmt(v,4)}</span></div>`).join("");
      }
    }
    if(p.comstock2!==null&&p.comstock2!==undefined)
      html += `<div class="row"><span>${opts.comstock2Label||"comparison run"}</span><span>${fmt(p.comstock2,opts.normalized?4:4)}</span></div>`;
    (opts.extraLines||[]).forEach(l=>{
      if(p[l.key]!==null&&p[l.key]!==undefined)
        html += `<div class="row"><span>${l.label}</span><span>${fmt(p[l.key],4)}</span></div>`;
    });
    if(rel_!==null) html += `<div class="row"><span>level difference</span><span>${pct(rel_)}</span></div>`;
    showTip(html, ev);
  });
  hit.addEventListener("mouseleave", ()=>{ hideTip(); cross.setAttribute("opacity",0); });
  svg.appendChild(hit);
  host.innerHTML=""; attachChart(host, svg, opts.copy);
}

/* ---------- report export: copy a chart as PNG with title + legend ---------- */
// Always exported on a white background with light-theme ink, whatever the
// dashboard theme, so the image drops straight into a report.
const EXPORT_LIGHT = {"--surface":"#ffffff","--panel":"#ffffff","--ink":"#1a1d1f",
  "--ink-2":"#4a5157","--ink-3":"#767f87","--line":"#e3e6e8","--grid":"#eef1f2"};

// charts: [{svg, label?}] laid out in `cols` columns (1 chart = 1x1, no label row).
// Widest of a set of labels, in px, via canvas text metrics.
let MEAS_CTX=null;
function measureLabel(labels, font){
  if(!MEAS_CTX) MEAS_CTX=document.createElement("canvas").getContext("2d");
  MEAS_CTX.font=font;
  return Math.max(0,...labels.map(s=>MEAS_CTX.measureText(String(s)).width));
}
async function copyCharts(charts, cols, title, legendItems){
  const NS="http://www.w3.org/2000/svg";
  const defs=charts.filter(c=>c.svg);
  if(!defs.length) throw new Error("no charts");
  const dims=defs.map(c=>(c.svg.getAttribute("viewBox")||"0 0 320 200").split(/\s+/).map(Number));
  const cw=Math.max(...dims.map(d=>d[2])), ch=Math.max(...dims.map(d=>d[3]));
  const pad=14, gap=10, titleH=title?26:0;
  const labelH=defs.some(c=>c.label)?18:0;
  const rows=Math.ceil(defs.length/cols);
  const cellH=labelH+ch, cellW=cw;
  // Width from the actual text metrics: a fixed 196px clipped the longest
  // "end use, fuel" labels off the right edge of the copied image.
  const legW=legendItems.length?Math.min(300,Math.max(150,26+measureLabel(
    legendItems.map(i=>i.label),"11.5px Arial,Helvetica,sans-serif"))):0, rowH=19;
  const legH=legendItems.length*rowH+10;
  const gridW=cols*cellW+(cols-1)*gap, gridH=rows*cellH+(rows-1)*gap;
  const W=gridW+legW+pad*2, H=Math.max(gridH,legH)+titleH+pad;
  const out=document.createElementNS(NS,"svg");
  out.setAttribute("xmlns",NS);
  out.setAttribute("viewBox",`0 0 ${W} ${H}`);
  out.setAttribute("width",W); out.setAttribute("height",H);
  const st=document.createElementNS(NS,"style");
  st.textContent=`svg{${Object.entries(EXPORT_LIGHT).map(([k,v])=>`${k}:${v}`).join(";")};
      font-family:Arial,Helvetica,sans-serif}
    .ax{font-size:11px;fill:${EXPORT_LIGHT["--ink-3"]}}
    .axl{font-size:11.5px;fill:${EXPORT_LIGHT["--ink-2"]}}
    .gl{stroke:${EXPORT_LIGHT["--grid"]};stroke-width:1}
    .zero{stroke:${EXPORT_LIGHT["--line"]};stroke-width:1.5}`;
  out.appendChild(st);
  const bg=document.createElementNS(NS,"rect");
  bg.setAttribute("width",W); bg.setAttribute("height",H); bg.setAttribute("fill","#ffffff");
  out.appendChild(bg);
  // The legend's hatch fills must resolve inside the serialized document, not
  // by luck against a cloned chart's defs.
  if(legendItems.some(i=>i.pattern)) fuelPatternDefs(out);
  const txt=(x,y,s,style,fill)=>{
    const t=document.createElementNS(NS,"text");
    t.setAttribute("x",x); t.setAttribute("y",y); t.setAttribute("style",style);
    t.setAttribute("fill",fill); t.textContent=s; out.appendChild(t);
  };
  if(title) txt(pad,18,title,"font-size:13px;font-weight:600",EXPORT_LIGHT["--ink"]);
  defs.forEach((c,i)=>{
    const col=i%cols, row=Math.floor(i/cols);
    const x=pad+col*(cellW+gap), y=titleH+row*(cellH+gap);
    if(c.label) txt(x+2,y+13,c.label,"font-size:12px;font-weight:600",EXPORT_LIGHT["--ink-2"]);
    const clone=c.svg.cloneNode(true);
    clone.setAttribute("x",x); clone.setAttribute("y",y+labelH);
    clone.setAttribute("width",cw); clone.setAttribute("height",ch);
    clone.removeAttribute("style");
    // Screen-only decorations (overnight shading) come out of report exports —
    // without the caption they read as artifacts.
    clone.querySelectorAll(".band").forEach(b=>b.remove());
    out.appendChild(clone);
  });
  legendItems.forEach((it,i)=>{
    const y=titleH+12+i*rowH, x=gridW+pad+8;
    if(it.line){
      const l=document.createElementNS(NS,"line");
      l.setAttribute("x1",x); l.setAttribute("x2",x+13);
      l.setAttribute("y1",y+5); l.setAttribute("y2",y+5);
      l.setAttribute("stroke",it.color); l.setAttribute("stroke-width",2.5);
      if(it.dash) l.setAttribute("stroke-dasharray","4 2");
      out.appendChild(l);
    } else if(it.chip){
      // Real fill + real fuel hatch, from the same defs the plot uses, so the
      // copied key matches the copied bars exactly.
      const box=(fill,op)=>{ const r=document.createElementNS(NS,"rect");
        r.setAttribute("x",x); r.setAttribute("y",y); r.setAttribute("width",13);
        r.setAttribute("height",11); r.setAttribute("fill",fill);
        if(op!==undefined) r.setAttribute("opacity",op);
        out.appendChild(r); return r; };
      box(it.color);
      if(it.pattern) box(`url(#pat-${it.pattern}-${YIQ(it.color)<128?"d":"l"})`);
      const b=box("none"); b.setAttribute("stroke","rgba(0,0,0,.3)");
    } else {
      const r=document.createElementNS(NS,"rect");
      r.setAttribute("x",x); r.setAttribute("y",y); r.setAttribute("width",11);
      r.setAttribute("height",11); r.setAttribute("rx",2); r.setAttribute("fill",it.color);
      if(it.band) r.setAttribute("opacity",.25);
      if(it.hatch) r.setAttribute("opacity",.35);
      out.appendChild(r);
      if(it.hatch){
        for(let k=0;k<3;k++){
          const l=document.createElementNS(NS,"line");
          l.setAttribute("x1",x+2+k*4); l.setAttribute("y1",y+11);
          l.setAttribute("x2",x+2+k*4+4); l.setAttribute("y2",y);
          l.setAttribute("stroke",it.color); l.setAttribute("stroke-width",1.6);
          out.appendChild(l);
        }
      }
    }
    txt(x+18,y+9.5,it.label,"font-size:11.5px",EXPORT_LIGHT["--ink-2"]);
  });
  const xml=new XMLSerializer().serializeToString(out);
  const url=URL.createObjectURL(new Blob([xml],{type:"image/svg+xml;charset=utf-8"}));
  try{
    const img=new Image();
    await new Promise((res,rej)=>{ img.onload=res; img.onerror=rej; img.src=url; });
    const scale=2, cv=document.createElement("canvas");
    cv.width=W*scale; cv.height=H*scale;
    cv.getContext("2d").drawImage(img,0,0,W*scale,H*scale);
    const blob=await new Promise(res=>cv.toBlob(res,"image/png"));
    try{
      await navigator.clipboard.write([new ClipboardItem({"image/png":blob})]);
      return "copied";
    }catch(e){
      // Clipboard blocked (permission policy) — save the PNG instead so the
      // button always yields the image.
      const a=document.createElement("a");
      a.href=URL.createObjectURL(blob);
      a.download=(title||"chart").replace(/[^\w()=·-]+/g,"_").replace(/_+/g,"_")+".png";
      document.body.appendChild(a); a.click(); a.remove();
      setTimeout(()=>URL.revokeObjectURL(a.href),4000);
      return "saved";
    }
  } finally { URL.revokeObjectURL(url); }
}

function wireCopy(btn, getCharts, cols, title, legendItems){
  btn.addEventListener("click", async ()=>{
    btn.textContent="…";
    try{
      const how=await copyCharts(getCharts(), cols, title, legendItems);
      btn.textContent=how==="copied"?"Copied":"Saved PNG";
    }
    catch(e){ btn.textContent="Failed"; }
    setTimeout(()=>btn.textContent="Copy",1800);
  });
}

/* export legend builders */
function runLegendItems(withEnduseHatch){
  const items=[{color:D.cbecsColor,label:"CBECS 2018"}];
  if(withEnduseHatch) items.push({color:D.cbecsColor,label:"CBECS (modeled end use)",hatch:true});
  return items.concat(RUNS.map(r=>({color:r.color,label:r.label})));
}
function datasetLegendItems(){
  return [{color:D.cbecsColor,label:"CBECS 2018"}]
    .concat(RUNS.map(r=>({color:r.color,label:runShort(r.key)})));
}

/* ---------- gap decomposition ----------
   ΔT = ΔA·I_cb + A_cs·ΔI  (exact): the area term is what the floor-area
   mismatch alone would contribute at CBECS intensity; the intensity term is the
   behavioral difference over ComStock's own floor area. Attribution goes to a
   term holding ≥70% of the combined magnitude, else "both". */
function decompose(row, sqftRow){
  if(!row||!sqftRow||row.cbecs_value===null||row.cbecs_value===undefined) return null;
  const A_cs=sqftRow.comstock_value, A_cb=sqftRow.cbecs_value;
  const I_cs=row.comstock_eui, I_cb=row.cbecs_eui;
  if([A_cs,A_cb,I_cs,I_cb].some(v=>v===null||v===undefined)) return null;
  const areaEff=(A_cs-A_cb)*I_cb/1e9, intEff=A_cs*(I_cs-I_cb)/1e9;
  const tot=Math.abs(areaEff)+Math.abs(intEff);
  const attr = !tot ? "—" : Math.abs(intEff)/tot>=0.7 ? "intensity"
             : Math.abs(areaEff)/tot>=0.7 ? "area" : "both";
  return {areaEff, intEff, attr};
}
function rowWithin(r){
  const v=r.comstock_value;
  return r.cbecs_ci95_low!==null&&r.cbecs_ci95_low!==undefined&&v!==null&&v!==undefined
    &&v>=r.cbecs_ci95_low&&v<=r.cbecs_ci95_high;
}

/* ---------- waterfall: signed contributions accumulating to the total ---------- */
function waterfall(host, items, opts={}){
  const padL=58,padR=12,padT=10;
  if(!items.length){ host.innerHTML='<p class="note">No records for this selection.</p>'; return; }
  const bw=Math.max(14,Math.min(30,700/(items.length+1))), gap=12;
  const plan = tickPlan(items.map(s=>s.label).concat([opts.totalLabel||"National gap"]),
                        bw+gap);
  const padB = plan.pad;
  const H=(opts.height||270) + Math.max(0, padB-76);
  const n=items.length+1;
  const plotW=n*bw+(n-1)*gap, width=padL+padR+plotW+30;
  let cum=0; const steps=items.map(it=>{const s=cum; cum+=it.delta; return {...it,start:s,end:cum};});
  const lo=Math.min(0,...steps.map(s=>Math.min(s.start,s.end)));
  const hi=Math.max(0,...steps.map(s=>Math.max(s.start,s.end)));
  const plotH=H-padT-padB, y=v=>padT+plotH-((v-lo)/(hi-lo||1))*plotH;
  const svg=el("svg",{viewBox:`0 0 ${width} ${H}`, style:figStyle(width)});
  for(let i=0;i<=4;i++){
    const v=lo+(hi-lo)*i/4, yy=y(v);
    svg.appendChild(el("line",{x1:padL-6,y1:yy,x2:width-padR,y2:yy,class:"gl"}));
    const t=el("text",{x:padL-10,y:yy+4,class:"ax","text-anchor":"end"});
    t.textContent=fmt(v,0); svg.appendChild(t);
  }
  const yl=el("text",{x:12,y:padT+plotH/2,class:"axl","text-anchor":"middle",
    transform:`rotate(-90 12 ${padT+plotH/2})`});
  yl.textContent="TBtu"; svg.appendChild(yl);
  steps.forEach((s,i)=>{
    const x=padL+i*(bw+gap);
    const rect=el("rect",{x, y:y(Math.max(s.start,s.end)),
      width:bw, height:Math.max(Math.abs(y(s.start)-y(s.end)),1.5), rx:3,
      fill:s.color||(s.delta>=0?"#D55E00":"#0072B2"), opacity:.85});
    rect.addEventListener("mousemove",ev=>showTip(
      `<b>${s.label}</b><div class="row"><span>contribution</span><span>${pct(null)===pct(null)&&""}${(s.delta>0?"+":"")+fmt(s.delta,1)} TBtu</span></div>`+
      `<div class="row"><span>running total</span><span>${fmt(s.end,1)} TBtu</span></div>`,ev));
    rect.addEventListener("mouseleave",hideTip);
    svg.appendChild(rect);
    svg.appendChild(el("line",{x1:x+bw,y1:y(s.end),x2:x+bw+gap,y2:y(s.end),
      stroke:"var(--ink-3)","stroke-width":1,"stroke-dasharray":"2 2"}));
    const lx=x+bw/2+plan.dx, ly=H-padB+16;
    tickLabel(svg, lx, ly, s.label, plan);
  });
  const x=padL+items.length*(bw+gap);
  const tot=el("rect",{x, y:y(Math.max(0,cum)), width:bw,
    height:Math.max(Math.abs(y(0)-y(cum)),1.5), rx:3, fill:"var(--ink-2)"});
  svg.appendChild(tot);
  const lx=x+bw/2+plan.dx, ly=H-padB+16;
  tickLabel(svg, lx, ly, opts.totalLabel||"National gap", plan, "font-weight:600");
  svg.appendChild(el("line",{x1:padL-6,y1:y(0),x2:width-padR,y2:y(0),class:"zero"}));
  plotFrame(svg, padL, padT, width-padR-padL, H-padT-padB);
  host.innerHTML=""; attachChart(host, svg, opts.copy);
}

/* ---------- legends ---------- */
function swatch(color,label){
  return `<span class="key"><span class="sw" style="background:${color}"></span>${label}</span>`;
}
// The hatch key only belongs on charts that actually break CBECS into end uses;
// showing it elsewhere legends a pattern that never appears (and disagreed with
// the PNG export, which already omitted it).
function annualLegend(withEnduseHatch=true){
  return `<div class="legend">${swatch(D.cbecsColor,"CBECS 2018")}
    ${withEnduseHatch?`<span class="key"><span class="sw" style="background:repeating-linear-gradient(45deg,${D.cbecsColor},${D.cbecsColor} 2px,transparent 2px,transparent 4px)"></span>CBECS (modeled end use)</span>`:""}
    ${RUNS.map(r=>swatch(r.color,r.label)).join("")}
  </div>`;
}
function enduseLegend(withAmi=true){
  // Reversed so the legend reads top-of-stack first, matching the plots in the
  // ComStock repo (which reverse their handles for the same reason).
  return `<div class="legend">${D.enduseOrder.slice().reverse().map(k=>
    swatch(D.enduseColors[k], k.replace(/_/g," "))).join("")}
    ${withAmi?`<span class="key"><span class="sw" style="background:var(--ink)"></span>AMI metered</span>`:""}</div>`;
}

/* ---------- clickable end-use legend ----------
   The end-use keys double as visibility switches: hiding a dominant end use is
   how you see what the rest of the stack is doing. Hidden end uses drop out of
   every stack that uses this legend (measure bars, AMI and measure profiles)
   and out of the exported legend, so the figure and its key stay in step. */
const euHidden = () => new Set(state.euHidden||[]);
const euVisible = k => !euHidden().has(k);
const euOrderVisible = () => (D.enduseOrder||[]).filter(euVisible);
const euAnyHidden = () => (D.enduseOrder||[]).some(k=>euHidden().has(k));
/* A figure whose stack is filtered must say so, because its bar totals and
   percent labels are deliberately still computed over ALL end uses — a
   percentage that moves when you hide an unrelated end use is a wrong number
   waiting to be quoted. */
function euFilterBadge(){
  const n=(D.enduseOrder||[]).filter(k=>euHidden().has(k)).length;
  if(!n) return "";
  return `<span class="badge" style="color:var(--bad)">${n} end use${n>1?"s":""} hidden —
    bars show a subset; totals and percentages are still over all end uses</span>`;
}
function enduseLegendToggle(opts={}){
  const hid=euHidden();
  const keys=(D.enduseOrder||[]).slice().reverse();
  const anyHidden=keys.some(k=>hid.has(k));
  return `<div class="legend"${opts.column?' style="flex-direction:column;align-items:flex-start;gap:5px 0;flex-wrap:nowrap"':''}>
    ${keys.map(k=>`<span class="key" data-eu="${k}" role="button"
      aria-pressed="${!hid.has(k)}" title="click to hide or show this end use">
      <span class="sw" style="background:${D.enduseColors[k]}"></span>${k.replace(/_/g," ")}</span>`).join("")}
    ${opts.extra||""}
    ${anyHidden?`<span class="key" data-eu="__all__" role="button" aria-pressed="true"
      style="cursor:pointer;font-weight:600">show all</span>`:""}</div>`;
}
function wireEnduseLegend(rerender){
  document.querySelectorAll("[data-eu]").forEach(k=>k.addEventListener("click",()=>{
    const key=k.dataset.eu;
    const hid=euHidden();
    if(key==="__all__") hid.clear();
    else if(hid.has(key)) hid.delete(key);
    else hid.add(key);
    state.euHidden=[...hid];
    rerender(); syncHash();
  }));
}
const enduseLegendItemsVisible = () => euOrderVisible().slice().reverse()
  .map(k=>({color:D.enduseColors[k],label:k.replace(/_/g," ")}));

/* The fuel x end-use figure keys its legend by (end use, FUEL) — that is what
   its entries are — so it hides at that granularity too. Hiding by end use
   alone took all five fuels of Water Systems out at once, which is not what a
   reader clicking "Water Systems, Natural Gas" is asking for. Kept separate
   from `euHidden`, which drives the legends whose entries really are end uses
   (the AMI and measure profiles), so neither figure surprises the other. */
const feKey = (eu, f) => `${eu}|${f}`;
const feHidden = () => new Set(state.feHidden||[]);
const feVisible = (eu, f) => !feHidden().has(feKey(eu,f));
const feAnyHidden = () => (state.feHidden||[]).length > 0;
function feFilterBadge(){
  const n=(state.feHidden||[]).length;
  if(!n) return "";
  return `<span class="badge" style="color:var(--bad)">${n} series hidden —
    bars show a subset; totals and percentages are still over all of them</span>`;
}
function wireFeLegend(rerender){
  document.querySelectorAll("[data-fe]").forEach(k=>k.addEventListener("click",()=>{
    const key=k.dataset.fe;
    const hid=feHidden();
    if(key==="__all__") hid.clear();
    else if(hid.has(key)) hid.delete(key);
    else hid.add(key);
    state.feHidden=[...hid];
    rerender(); syncHash();
  }));
}

/* Zero-gas floor-area share: a fuel-ASSIGNMENT check rather than a headline
   number, so it belongs with the detailed CBECS comparisons rather than on the
   Overview. Percent shares on both sides, so the difference is in points. */
function fuelMixPanel(){
  let t=`<div class="panel" id="sec-gasmix"><h2>Share of floor area with no natural gas by
      building type — %
      <span class="badge">CBECS 2018 vs ${RUNS.map(r=>runShort(r.key)).join(" vs ")}</span>
      <span class="badge">difference in pp</span></h2>
    <p class="note">A heating-fuel gap shows up here rather than in an end-use total. Where the
    columns disagree, a gas difference is a fuel-assignment question, not a thermostat one.</p>
    <div class="scroll"><table><thead><tr><th>Building type</th><th>CBECS</th>
    ${RUNS.map(r=>`<th>${runShort(r.key)}</th>`).join("")}
    <th>${runShort(PRIMARY)} − CBECS (pp)</th>
    </tr></thead><tbody>`;
  ["All",...D.buildingTypes].forEach(bt=>{
    const cb=(fuelMixBy[PRIMARY]||{})[bt];
    if(!cb) return;
    const cbv=cb.cbecs_zero_gas_share*100;
    t+=`<tr${bt==="All"?' style="font-weight:650;background:var(--grid)"':""}><td>${bt}</td>
      <td>${fmt(cbv)}%</td>`;
    RUNS.forEach(r=>{
      const f=(fuelMixBy[r.key]||{})[bt];
      t+=`<td>${f?fmt(f.comstock_zero_gas_share*100)+"%":absentTag("noValue")}</td>`;
    });
    // A difference of two percent shares is percentage POINTS, not a percent.
    const dpp=cb.comstock_zero_gas_share*100-cbv;
    t+=`<td><span class="cell" style="background:${diffColor(dpp)}">${
      (dpp>0?"+":"")+dpp.toFixed(1)+" pp"}</span></td></tr>`;
  });
  return t+`</tbody></table></div></div>`;
}

/* ---------- the verdict strip ----------
   The answer to "is this run any good" used to be the All row of the second
   panel, below the fold and under ~320 words of notes. This puts the national
   numbers, their test status, and the run-over-run direction on the first
   screen, and says in one sentence where the biggest problem is. */
/* Only metrics CBECS actually measures belong here. Heating (all fuel) and
   cooling are EIA statistical disaggregations of a surveyed fuel total, so a
   difference against them is weaker evidence and does not belong in the
   headline; those comparisons stay in the scorecard below, where the hatch and
   the caveat travel with them. */
const VERDICT_EXCLUDE=["all_fuel.heating","electricity.cooling"];
function verdictStrip(){
  const all=(annualBy[PRIMARY]||{})["All"]||{};
  const cards=D.headline.filter(([k])=>!VERDICT_EXCLUDE.includes(k)).map(([k,l])=>{
    const r=all[k];
    if(!r||r.pct_diff===null||r.pct_diff===undefined) return null;
    const p=r.pct_diff;
    const tested=r.within_cbecs_ci95===true||r.within_cbecs_ci95===false;
    const outside=r.within_cbecs_ci95===false;
    let dir=null;
    if(MULTI&&SECONDARY){
      const o=((annualBy[SECONDARY.key]||{})["All"]||{})[k];
      if(o&&o.pct_diff!==null&&o.pct_diff!==undefined){
        const d=Math.abs(p)-Math.abs(o.pct_diff);
        dir = d<-0.5?"better" : d>0.5?"worse" : "same";
      }
    }
    return {k, label:l, p, tested, outside, dir};
  }).filter(Boolean);
  if(!cards.length) return "";
  const worst=cards.slice().sort((a,b)=>Math.abs(b.p)-Math.abs(a.p))[0];
  const nOut=cards.filter(c=>c.outside).length;
  const nUntested=cards.filter(c=>!c.tested).length;
  const nWorse=cards.filter(c=>c.dir==="worse").length;
  const nBetter=cards.filter(c=>c.dir==="better").length;
  const arrow=d=>d==="better"?`<span style="color:var(--good)" title="gap shrank vs ${
      runShort(SECONDARY.key)}">▼ closer</span>`
    : d==="worse"?`<span style="color:var(--bad)" title="gap grew vs ${
      runShort(SECONDARY.key)}">▲ further</span>`
    : d==="same"?`<span style="color:var(--ink-3)">· unchanged</span>` : "";
  return `<div class="panel"><h2>Where ${runShort(PRIMARY)} stands against CBECS 2018
      <span class="badge">national totals, whole stock</span>
      <span class="badge">% of CBECS</span></h2>
    <p class="note" style="margin-top:6px">Largest difference: <b>${worst.label}</b>,
    <b>${pct(worst.p)}</b> of CBECS. ${nOut} of ${cards.length} metrics fall outside the CBECS 95%
    confidence interval${nUntested?`; ${nUntested} has no interval to test against (†)`:""}.
    ${MULTI&&SECONDARY?`Relative to <b>${runShort(SECONDARY.key)}</b>, ${nBetter} moved toward CBECS and
      ${nWorse} moved away.`:""}</p>
    <div class="verdict">${cards.map(c=>`<div class="vcard">
      <div class="vlabel">${c.label}</div>
      <div class="vval" style="color:${Math.abs(c.p)>=25?"var(--bad)":"var(--ink)"}">${pct(c.p)}${
        c.tested?"":'<span class="ci-na" title="CBECS carries no confidence interval for this metric">†</span>'}</div>
      <div class="vsub">${c.outside?"outside CBECS 95% CI"
        :c.tested?"within CBECS 95% CI":"no CBECS interval"}</div>
      ${c.dir?`<div class="vsub">${arrow(c.dir)}</div>`:""}
    </div>`).join("")}</div></div>`;
}

/* ---------- views ---------- */
function renderOverview(){
  const cols = D.headline;
  /* Electricity and gas by building type lead the tab: they are the comparison
     the rest of the dashboard elaborates, and they are per fuel because a
     site-energy total hides a gas-for-electricity trade. Shown whether or not
     there is a second run — with one run it is simply CBECS vs that run. */
  let h = "";
  {
    h+=`<div class="panel"><h2>Annual energy consumption by building type — TBtu
        <span class="badge">CBECS 2018 vs ${RUNS.map(r=>runShort(r.key)).join(" vs ")}</span></h2>
      <p class="note">Whiskers are the CBECS 95% jackknife confidence interval.</p>
      <div class="legend">${datasetLegendItems().map(i=>swatch(i.color,i.label)).join("")}</div>
      <div><h3>Electricity — TBtu</h3><div id="rvr-elec"></div></div>
      <div style="margin-top:10px"><h3>Natural gas — TBtu</h3><div id="rvr-gas"></div></div></div>`;
  }
  h += verdictStrip();
  h += `<div class="panel"><h2>Percent difference vs CBECS by building type and metric — % of CBECS
      <span class="badge">${runShort(PRIMARY)} − CBECS 2018</span>
      <span class="badge">AMI columns in pts and pp</span></h2>
    <p class="note"><b>Cell value:</b> (${runLabel(PRIMARY)} − CBECS) ÷ CBECS. Blue = under CBECS,
    orange = over.<br>
    <b>Bold:</b> outside the CBECS 95% confidence interval. <b>†:</b> CBECS has no interval for
    this metric, so the difference is untested — not passed. Cross-fuel metrics are always
    daggered because the jackknife interval is not additive across fuels.
    ${MULTI&&SECONDARY?`<br><b>Arrow</b> (vs ${runShort(SECONDARY.key)}): ▼ gap narrowed, ▲ gap widened,
    · within 0.5 pp. It tracks the gap's <i>magnitude</i>.`:""}<br>
    <b>AMI columns:</b> ${runLabel(PRIMARY)} vs metered, region <b>${state.amiRegion}</b> only,
    on day-sum-normalized profiles (not kWh/ft², whose floor-area denominator is uncertain).
    Shape RMSE in points, overnight share Δ in percentage points.<br>
    Click a row to open that building type.</p>
    <div class="scroll"><table><thead><tr><th>Building type</th>`;
  cols.forEach(([,l])=>h+=`<th>${l}</th>`);
  // The AMI columns are one region's numbers, picked by a selector on another
  // tab, so the region is named in the header rather than left to the note.
  h += `<th>AMI shape RMSE, mean over season × day type · ${state.amiRegion}</th>
        <th>AMI overnight share Δ, mean over season × day type · ${state.amiRegion}</th>
        </tr></thead><tbody>`;
  const shapeBy={};
  (D.amiShape[state.amiRegion]||[]).forEach(r=>{ (shapeBy[r.building_type] ||= []).push(r); });
  const mean=(a,k)=>{const v=a.map(r=>r[k]).filter(x=>x!==null&&x!==undefined);
    return v.length?v.reduce((s,x)=>s+x,0)/v.length:null;};
  const prim = annualBy[PRIMARY]||{};
  ["All",...D.buildingTypes].forEach(bt=>{
    const row=prim[bt]||{}, isAll=bt==="All";
    h+=`<tr class="${isAll?"":"clickable"}" ${isAll?"":`data-type="${bt}"`}
        style="${isAll?"font-weight:650;background:var(--grid)":""}"><td>${bt}</td>`;
    cols.forEach(([k])=>{
      const r=row[k], p=r?r.pct_diff:null, out=r&&r.within_cbecs_ci95===false;
      // Three states, not two: tested-and-outside (bold), tested-and-inside
      // (plain), and NOT TESTABLE (dagger). Derived cross-fuel metrics have no
      // CBECS interval, so treating null as "inside" made a +102% heating miss
      // read as consistent with the survey.
      const untested = r && (r.within_cbecs_ci95===null||r.within_cbecs_ci95===undefined)
        && p!==null && p!==undefined;
      let arrow="";
      if(MULTI&&SECONDARY&&p!==null&&p!==undefined){
        const o=((annualBy[SECONDARY.key]||{})[bt]||{})[k];
        const po=o?o.pct_diff:null;
        if(po!==null&&po!==undefined){
          const d=Math.abs(p)-Math.abs(po);
          arrow = d<-0.5 ? ` <span style="color:var(--good)" title="gap shrank vs ${runShort(SECONDARY.key)}">▼</span>`
                : d>0.5  ? ` <span style="color:var(--bad)" title="gap grew vs ${runShort(SECONDARY.key)}">▲</span>`
                : ` <span style="color:var(--ink-3)" title="unchanged vs ${runShort(SECONDARY.key)}">·</span>`;
        }
      }
      h+=`<td><span class="cell ${out?"ci-out":""}" style="background:${diffColor(p)}"
        ${untested?'title="CBECS carries no confidence interval for this metric — untested, not passed"':""}
        >${pct(p)}${untested?'<span class="ci-na">†</span>':""}</span>${arrow}</td>`;
    });
    const sh=shapeBy[snake(bt)]||[];
    const csS=mean(sh,"overnight_share_comstock"), amS=mean(sh,"overnight_share_ami");
    const dS=(csS===null||amS===null)?null:100*(csS-amS);
    h+=`<td>${fmt(mean(sh,"daytype_shape_rmse_pts"),2)}</td>`;
    h+=`<td><span class="cell" style="background:${diffColor(dS===null?null:dS*4)}">${
      dS===null?absentTag("noValue"):(dS>0?"+":"")+dS.toFixed(1)+" pp"}</span></td></tr>`;
  });
  h+=`</tbody></table></div></div>`;

  // ----- ranked "where to look" -----
  const rankDims={building_type:"Building type", vintage:"Building type × vintage",
    census_division:"Building type × census division", size_bin:"Building type × floor area bin"};
  const rankFuels=[["electricity.total","Electricity"],["natural_gas.total","Natural gas"]];
  const rankFuelLab=(rankFuels.find(f=>f[0]===state.rankFuel)||["","Electricity"])[1];
  h+=`<div class="panel"><div class="head"><h2>Largest ${rankFuelLab.toLowerCase()} gaps by segment
      — TBtu (ComStock − CBECS)
      <span class="badge">${runShort(PRIMARY)} vs CBECS 2018</span>
      <span class="badge">ranked by absolute miss</span></h2>
      <span class="spacer"></span>
      <select id="rankDim">${Object.entries(rankDims).map(([k,v])=>
        `<option value="${k}" ${k===state.rankDim?"selected":""}>${v}</option>`).join("")}</select>
      <select id="rankFuel">${rankFuels.map(([k,v])=>
        `<option value="${k}" ${k===state.rankFuel?"selected":""}>${v}</option>`).join("")}</select>
      <label style="font-size:12.5px;color:var(--ink-2)"><input type="checkbox" id="rankSig"
        ${state.rankSig?"checked":""}> outside CBECS 95% CI only</label></div>
    <p class="note">Segments ordered by how many TBtu they contribute to the national gap — a
    ranking by absolute miss, so a huge percentage error on a tiny segment cannot outrank a modest
    error on a big one. Attribution splits each gap exactly: ΔT = ΔA·I<sub>CBECS</sub> +
    A<sub>CS</sub>·ΔI — the <b>area</b> term is what the floor-area mismatch alone would produce at
    CBECS intensity, the <b>intensity</b> term is the behavioral difference over ComStock's own
    floor area; a segment is labeled by a term carrying ≥70% of the combined magnitude. Click a row
    to open that building type.</p>
    <div class="scroll" id="rankTable"></div></div>`;

  /* Both fuels, always. This used to follow the ranked table's fuel selector,
     which sits in a different panel — so the waterfall could read as
     arbitrarily gas-only with nothing nearby to explain why. */
  h+=`<div class="panel"><h2>National gap by building type — TBtu (${runShort(PRIMARY)} − CBECS
      2018) <span class="badge">cumulative</span></h2>
    <p class="note">Orange = ComStock over CBECS, blue = under. Over- and under-predictions
    partially cancel, so the national total understates the gross modeling error.</p>
    <div class="grid2">
      <div><h3>Electricity — TBtu</h3><div id="wf-elec"></div></div>
      <div><h3>Natural gas — TBtu</h3><div id="wf-gas"></div></div>
    </div></div>`;


  $("#view").innerHTML=h;

  // Drawn whether or not there is a comparison run: with one run it is simply
  // CBECS against that run, which is still the headline comparison.
  [["electricity.total","Electricity","#rvr-elec"],
   ["natural_gas.total","Natural gas","#rvr-gas"]].forEach(([metric,lab,id])=>{
    const rows = D.buildingTypes.map(bt=>{
      const values={};
      RUNS.forEach(r=>{ const x=(annualBy[r.key]||{})[bt]||{};
        values[r.key]=(x[metric]||{}).comstock_value; });
      const cb=(annualBy[PRIMARY]||{})[bt]||{};
      const c=cb[metric]||{};
      values.cbecs=c.cbecs_value;
      return {label:bt, values, ciLow:c.cbecs_ci95_low, ciHigh:c.cbecs_ci95_high};
    });
    groupedBar($(id), rows,
      [{key:"cbecs",label:"CBECS 2018",color:D.cbecsColor,ci:true}]
        .concat(RUNS.map(r=>({key:r.key,label:runShort(r.key),color:r.color}))),
      {height:250, yLabel:"TBtu",
       copy:{title:`Annual ${lab.toLowerCase()} consumption by building type — CBECS 2018 vs `
               +`${RUNS.map(r=>runShort(r.key)).join(" vs ")} (TBtu, stock totals)`,
             legend:datasetLegendItems()}});
  });
  renderRankTable();
  renderWaterfall();
  /* Re-render the whole tab, not just the table: the panel HEADING names the
     selected fuel and granularity, and it lives in the markup built above. A
     partial re-render swapped the table's contents while leaving the title
     saying the other fuel — which read as "the chart did not change until I
     refreshed". */
  const rerankAll=()=>{ renderOverview(); syncHash(); };
  $("#rankDim").addEventListener("change",e=>{ state.rankDim=e.target.value; rerankAll(); });
  $("#rankFuel").addEventListener("change",e=>{ state.rankFuel=e.target.value; rerankAll(); });
  $("#rankSig").addEventListener("change",e=>{ state.rankSig=e.target.checked; rerankAll(); });
  document.querySelectorAll("tr.clickable").forEach(tr=>
    tr.addEventListener("click",()=>{ state.type=tr.dataset.type; setTab("annual"); }));
}

/* build ranked segment rows for one fuel at one granularity */
function rankedRows(dim, fuel){
  const out=[];
  const push=(label, bt, fuelRow, sqftRow)=>{
    if(!fuelRow||!sqftRow) return;
    const d=decompose(fuelRow, sqftRow);
    if(fuelRow.cbecs_value===null||fuelRow.cbecs_value===undefined) return;
    out.push({label, bt,
      cbecs:fuelRow.cbecs_value, comstock:fuelRow.comstock_value,
      delta:fuelRow.comstock_value-fuelRow.cbecs_value,
      within:rowWithin(fuelRow), attr:d?d.attr:"—",
      areaEff:d?d.areaEff:null, intEff:d?d.intEff:null});
  };
  if(dim==="building_type"){
    const src=(D.byDim.building_type||[]).filter(r=>r.run===PRIMARY);
    D.buildingTypes.forEach(bt=>{
      push(bt, bt,
        src.find(r=>r.category===bt&&r.metric===fuel),
        src.find(r=>r.category===bt&&r.metric==="sqft"));
    });
  } else {
    const src=(D.byPair[dim]||[]).filter(r=>r.run===PRIMARY);
    const keys=[...new Set(src.map(r=>r.building_type+"||"+r.category))];
    keys.forEach(k=>{
      const [bt,cat]=k.split("||");
      push(`${bt} · ${cat}`, bt,
        src.find(r=>r.building_type===bt&&r.category===cat&&r.metric===fuel),
        src.find(r=>r.building_type===bt&&r.category===cat&&r.metric==="sqft"));
    });
  }
  return out;
}

function renderRankTable(){
  const fuel=state.rankFuel;
  const natRow=(D.byDim.building_type||[]).find(r=>
    r.run===PRIMARY&&r.category==="All"&&r.metric===fuel);
  const natGap=natRow?natRow.comstock_value-natRow.cbecs_value:null;
  let rows=rankedRows(state.rankDim, fuel);
  if(state.rankSig) rows=rows.filter(r=>!r.within);
  rows.sort((a,b)=>Math.abs(b.delta)-Math.abs(a.delta));
  const top=rows.slice(0,20);
  let t=`<table><thead><tr><th>#</th><th>Segment</th><th>CBECS TBtu</th><th>ComStock TBtu</th>
    <th>Δ TBtu</th><th>share of national gap</th><th>area term</th><th>intensity term</th>
    <th>attribution</th></tr></thead><tbody>`;
  top.forEach((r,i)=>{
    const share=natGap?100*r.delta/natGap:null;
    t+=`<tr class="clickable" data-type="${r.bt}"><td>${i+1}</td>
      <td style="text-align:left">${r.label}${r.within?' <span class="badge">inside CI</span>':""}</td>
      <td>${fmt(r.cbecs,1)}</td><td>${fmt(r.comstock,1)}</td>
      <td><span class="cell" style="background:${diffColor(r.delta>0?30:-30)}">${(r.delta>0?"+":"")+fmt(r.delta,1)}</span></td>
      <td>${share===null?absentTag("noValue"):fmt(share,0)+"%"}</td>
      <td>${r.areaEff===null?"—":(r.areaEff>0?"+":"")+fmt(r.areaEff,1)}</td>
      <td>${r.intEff===null?"—":(r.intEff>0?"+":"")+fmt(r.intEff,1)}</td>
      <td><b>${r.attr}</b></td></tr>`;
  });
  t+=`</tbody></table>`;
  if(!top.length) t=`<p class="note">Nothing outside the CBECS 95% CI at this granularity — uncheck
    the filter to see all segments.</p>`;
  $("#rankTable").innerHTML=t;
  document.querySelectorAll("#rankTable tr.clickable").forEach(tr=>
    tr.addEventListener("click",()=>{ state.type=tr.dataset.type; setTab("annual"); }));
}

function renderWaterfall(){
  // one waterfall per fuel, independent of the ranked table's fuel selector
  [["electricity.total","Electricity","#wf-elec"],
   ["natural_gas.total","Natural gas","#wf-gas"]].forEach(([fuel,fuelLab,host])=>{
    const items=rankedRows("building_type", fuel)
      .map(r=>({label:r.label, delta:r.delta}))
      .sort((a,b)=>b.delta-a.delta);
    waterfall($(host), items, {height:280, yLabel:"TBtu (ComStock − CBECS)",
      totalLabel:`${fuelLab} gap`,
      copy:{title:`National ${fuelLab.toLowerCase()} gap by building type — `
              +`${runShort(PRIMARY)} − CBECS 2018 (TBtu)`,
            legend:[{color:"#D55E00",label:"ComStock over CBECS"},
                    {color:"#0072B2",label:"ComStock under CBECS"},
                    {color:"#4a5157",label:`${fuelLab} gap`}]}});
  });
}

function annualSeries(){
  // Reference first, model second — CBECS leads every comparison group.
  return [{key:"cbecs",label:"CBECS 2018",color:D.cbecsColor,ci:true,hatch:true}]
    .concat(RUNS.map(r=>({key:r.key,label:r.label,color:r.color})));
}

/* rows for one metric of one dimension, in either total or EUI terms */
function crossRows(dim, metric, mode){
  const src=D.byDim[dim]||[];
  const cats=[...new Set(src.filter(r=>r.metric===metric&&r.category!=="All").map(r=>r.category))];
  const order=D.ordered[dim];
  cats.sort((a,b)=> order?order.indexOf(a)-order.indexOf(b):String(a).localeCompare(String(b)));
  const isArea = metric==="sqft";
  const scale = (mode==="total" && isArea) ? 1e-6 : 1;
  const cs = mode==="eui" ? "comstock_eui" : "comstock_value";
  const cb = mode==="eui" ? "cbecs_eui" : "cbecs_value";
  return cats.map(cat=>{
    const values={}; let ciLow=null, ciHigh=null, prov="";
    RUNS.forEach(r=>{
      const m=src.find(x=>x.run===r.key&&x.metric===metric&&x.category===cat);
      values[r.key]=m?(m[cs]===null?null:m[cs]*scale):null;
      if(m){ prov=m.provenance;
        if(values.cbecs===undefined&&m[cb]!==null&&m[cb]!==undefined){
          values.cbecs=m[cb]*scale;
          // Confidence intervals are published for totals; an EUI interval would
          // need the covariance with floor area, so whiskers show on totals only.
          if(mode==="total"){ ciLow=m.cbecs_ci95_low*scale; ciHigh=m.cbecs_ci95_high*scale; }
        } }
    });
    return {label:String(cat), values, ciLow, ciHigh, hatched:(prov||"").startsWith("disagg")};
  });
}

const FUELS=[["electricity.total","elec","Electricity"],
             ["natural_gas.total","gas","Natural gas"]];

/* one panel: "<Fuel> by <bin>" with Total | Intensity | Floor area, three across.
   The area column is the same for both fuels of a bin, repeated deliberately so
   each panel is self-contained for debugging: intensity off, area off, or both.
   Exception: with 15 building types the third column gets too squished, so the
   building-type bin drops it (includeArea=false) and floor area by building
   type stands as its own full-width panel instead. */
function fuelBinPanel(idPrefix, fuelLabel, binLabel, badge, includeArea=true, anchor=""){
  const areaCol = includeArea
    ? `<div><h3>Floor area — Mft²</h3><div id="${idPrefix}-area"></div></div>` : "";
  return `<div class="panel"${anchor}><h2 style="margin-top:0">${fuelLabel} consumption by ${binLabel}
      <span class="badge">TBtu${includeArea?" · kBtu/ft²·yr · Mft²":" · kBtu/ft²·yr"}</span>
      <span class="badge">CBECS 2018 vs ${RUNS.map(r=>runShort(r.key)).join(" vs ")}</span>${badge||""}</h2>
    <div class="${includeArea?"grid3fit":"grid2"}">
      <div><h3>Total consumption — TBtu</h3><div id="${idPrefix}-tot"></div></div>
      <div><h3>Energy use intensity — kBtu/ft²·yr</h3><div id="${idPrefix}-eui"></div></div>
      ${areaCol}
    </div></div>`;
}

/* rows for one metric of one (building_type x dim) pair table */
function pairRows(dim, bt, metric, mode){
  const src=(D.byPair[dim]||[]).filter(r=>r.building_type===bt&&r.metric===metric);
  const cats=[...new Set(src.map(r=>r.category))];
  const order=D.ordered[dim];
  cats.sort((a,b)=> order?order.indexOf(a)-order.indexOf(b):String(a).localeCompare(String(b)));
  const cs = mode==="eui" ? "comstock_eui" : "comstock_value";
  const cb = mode==="eui" ? "cbecs_eui" : "cbecs_value";
  const scale = metric==="sqft" ? 1e-6 : 1;
  return cats.map(cat=>{
    const values={}; let ciLow=null, ciHigh=null;
    RUNS.forEach(r=>{
      const m=src.find(x=>x.run===r.key&&x.category===cat);
      values[r.key]=m&&m[cs]!==null&&m[cs]!==undefined?m[cs]*scale:null;
      if(m&&values.cbecs===undefined&&m[cb]!==null&&m[cb]!==undefined){
        values.cbecs=m[cb]*scale;
        if(mode==="total"){ ciLow=m.cbecs_ci95_low*scale; ciHigh=m.cbecs_ci95_high*scale; }
      }
    });
    return {label:String(cat), values, ciLow, ciHigh, hatched:false};
  }).filter(r=>Object.values(r.values).some(v=>v!==null&&v!==undefined));
}

/* stock-wide "All" rows in the mk style used by the per-type fuel/end-use charts */
function allRows(keys){
  const src=D.byDim.building_type||[];
  return keys.map(k=>{
    const values={}; let ciLow=null,ciHigh=null,prov="";
    RUNS.forEach(r=>{
      const m=src.find(x=>x.run===r.key&&x.category==="All"&&x.metric===k);
      values[r.key]=m?m.comstock_value:null;
      if(m){ prov=m.provenance;
        if(values.cbecs===undefined&&m.cbecs_value!==null&&m.cbecs_value!==undefined){
          values.cbecs=m.cbecs_value; ciLow=m.cbecs_ci95_low; ciHigh=m.cbecs_ci95_high; } }
    });
    const any=Object.values(values).some(v=>v&&Math.abs(v)>0.01);
    return any?{label:shortLabel(k),values,ciLow,ciHigh,hatched:(prov||"").startsWith("disagg")}:null;
  }).filter(Boolean);
}

const CROSS_BIN_DIMS=["building_type","vintage","census_division","size_bin","climate_zone"];

/* waterfall items decomposing one fuel's gap by end use, for one type or "All".
   CBECS end uses do not sum to its fuel total (some pieces are not surveyed or
   not disaggregated), so a grey residual bar closes the walk to the fuel-total
   gap honestly instead of hiding the difference. */
function enduseWaterfallItems(cat, fuelPrefix, fuelTotalKey){
  const src=(D.byDim.building_type||[]).filter(r=>r.run===PRIMARY&&r.category===cat);
  const items=[];
  D.endUses.filter(k=>k.startsWith(fuelPrefix)).forEach(k=>{
    const m=src.find(r=>r.metric===k);
    if(!m||m.cbecs_value===null||m.cbecs_value===undefined) return;
    if(m.comstock_value===null||m.comstock_value===undefined) return;
    items.push({label:(k.split(".")[1]||k).replace(/_/g," "),
                delta:m.comstock_value-m.cbecs_value});
  });
  const tot=src.find(r=>r.metric===fuelTotalKey);
  let total=null;
  if(tot&&tot.cbecs_value!==null&&tot.cbecs_value!==undefined){
    total=tot.comstock_value-tot.cbecs_value;
    const resid=total-items.reduce((s,i)=>s+i.delta,0);
    if(Math.abs(resid)>0.05) items.push({label:"not disaggregated",delta:resid,color:"#8b949b"});
  }
  items.sort((a,b)=>b.delta-a.delta);
  return items;
}

function enduseWaterfallPanel(cat, anchor=""){
  return `<div class="panel"${anchor}><h2 style="margin-top:0">Annual energy gap by end use —
      ${cat==="All"?"all building types":cat} — TBtu
      <span class="badge">${runShort(PRIMARY)} − CBECS 2018</span>
      <span class="badge">CBECS end uses are EIA disaggregations</span></h2>
    <p class="note">CBECS end uses are EIA statistical disaggregations, so read these as
    indicative. The grey bar is the part of the fuel-total gap CBECS does not disaggregate — end
    uses it did not survey, or the disaggregation residual.</p>
    <div class="grid2" data-scale="own">
      <div><h3>Electricity — TBtu</h3><div id="wf-eu-elec"></div></div>
      <div><h3>Natural gas — TBtu</h3><div id="wf-eu-gas"></div></div>
    </div></div>`;
}
function renderEnduseWaterfalls(cat){
  waterfall($("#wf-eu-elec"), enduseWaterfallItems(cat,"electricity.","electricity.total"), 
    {height:260, totalLabel:"Electricity gap", yLabel:"TBtu (ComStock − CBECS)",
     copy:{title:`Electricity gap by end use — ${cat} (TBtu, ComStock − CBECS)`,
           legend:[{color:"#D55E00",label:"ComStock over CBECS"},
                   {color:"#0072B2",label:"ComStock under CBECS"},
                   {color:"#8b949b",label:"Not disaggregated by CBECS"}]}});
  waterfall($("#wf-eu-gas"), enduseWaterfallItems(cat,"natural_gas.","natural_gas.total"),
    {height:260, totalLabel:"Natural gas gap", yLabel:"TBtu (ComStock − CBECS)",
     copy:{title:`Natural gas gap by end use — ${cat} (TBtu, ComStock − CBECS)`,
           legend:[{color:"#D55E00",label:"ComStock over CBECS"},
                   {color:"#0072B2",label:"ComStock under CBECS"},
                   {color:"#8b949b",label:"Not disaggregated by CBECS"}]}});
}

function dimSigToggle(){
  return `<label style="font-size:12.5px;color:var(--ink-2);display:inline-flex;gap:6px;
    align-items:center;margin-left:auto"><input type="checkbox" id="dimSig"
    ${state.dimSig?"checked":""}> dim bars consistent with CBECS (inside 95% CI)</label>`;
}
function wireDimSig(rerender){
  const c=$("#dimSig");
  if(c) c.addEventListener("change",e=>{ state.dimSig=e.target.checked; rerender(); syncHash(); });
}

/* Breakdown selector shared by the annual and distribution panel families.
   Segmented, using the same .tabs/.tab furniture as the view switchers, so it
   reads as "pick one" rather than as a filter that might be hiding data.
   `dims` is [[key,label],...]; ALL_DIMS shows every breakdown at once. */
const ALL_DIMS="all";
/* Resolve the selection against what this view actually offers. Falling back to
   ALL when the stored dimension is unavailable was wrong: choosing a building
   type drops `building_type` from the distribution breakdowns, which silently
   flipped that tab back to every breakdown at once — the long scroll the
   selector exists to avoid. Fall back to the first available one instead. */
const resolveDim=(available, current)=>
  current===ALL_DIMS ? ALL_DIMS
  : available.includes(current) ? current
  : (available[0] || ALL_DIMS);
function dimToggle(ctlId, dims, current){
  const sel = resolveDim(dims.map(d=>d[0]), current);
  return `<div class="tabs" role="group" aria-label="Breakdown" id="${ctlId}">
    ${dims.map(([k,lab])=>`<button class="tab" data-dim="${k}"
      aria-selected="${sel===k}">${lab}</button>`).join("")}
    <button class="tab" data-dim="${ALL_DIMS}" aria-selected="${sel===ALL_DIMS}"
      title="Every breakdown, one after another">All</button></div>`;
}
function wireDimToggle(ctlId, field, rerender){
  const c=$(`#${ctlId}`);
  if(!c) return;
  c.querySelectorAll("[data-dim]").forEach(b=>b.addEventListener("click",()=>{
    state[field]=b.dataset.dim; rerender(); syncHash(); }));
}
// the breakdowns to render, resolved the same way the toggle highlights them
const dimsToShow=(available, current)=>{
  const sel=resolveDim(available, current);
  return sel===ALL_DIMS ? available : [sel];
};

function renderCross(){
  let h=`<div class="panel"><div class="head">
    <h2>Annual energy by every breakdown — TBtu, kBtu/ft²·yr, Mft²
      <span class="badge">CBECS 2018 vs ${RUNS.map(r=>runShort(r.key)).join(" vs ")}</span>
      <span class="badge">whole stock, all building types</span></h2>${dimSigToggle()}</div>
    ${annualLegend(false)}
    <p class="note">Whiskers are the CBECS 95% confidence interval, on totals.</p></div>`;

  /* This tab is ~33 charts in one scroll (every bin, both fuels, three columns
     each) because that full grid was asked for deliberately. An index makes it
     navigable without removing any of it. */
  const availDims=CROSS_BIN_DIMS.filter(d=>D.byDim[d]);
  const shownDims=dimsToShow(availDims, state.xDim);
  // the index lists what is actually on the page, so it can never point at a
  // section the breakdown selector has hidden
  const SECTIONS=[["sec-fuels","By fuel"],["sec-enduse","By end use"]]
    .concat(shownDims.map(d=>
      ["sec-"+d,(D.dimensions[d]||{label:d}).label.replace(/,.*$/,"")]))
    .concat([["sec-gasmix","Gas prevalence"],["sec-gap","End-use gap waterfalls"]]);
  h+=`<div class="panel" style="position:sticky;top:64px;z-index:20;padding:9px 14px">
    <div class="legend" style="gap:6px 10px;margin:0"><span class="legend-title"
      style="margin:0 4px 0 0">Jump to</span>${SECTIONS.map(([id,lab])=>
      `<a class="jump" href="javascript:void 0" data-jump="${id}">${lab}</a>`).join("")}</div></div>`;
  h+=`<div class="panel" id="sec-fuels"><h2 style="margin-top:0">Annual consumption by fuel — TBtu
      <span class="badge">whole stock, national</span></h2>
      <div class="scroll" id="all-fuels"></div></div>`;
  /* This chart hatches its CBECS bars, so it needs the hatch key — and it cannot
     borrow the legend at the top of the tab, which sits above the by-fuel chart
     and correctly omits the hatch. Keying "the hatch belongs only on charts that
     disaggregate CBECS" to a SHARED legend is what dropped the key from the one
     chart that draws it. */
  h+=`<div class="panel" id="sec-enduse"><h2 style="margin-top:0">Annual consumption by fuel and
      end use — TBtu
      <span class="badge">whole stock, national</span>
      <span class="badge">CBECS end uses hatched = EIA disaggregation</span></h2>
      ${annualLegend()}
      <div class="scroll" id="all-enduse"></div>
      <p class="note">Hatched CBECS bars are EIA statistical disaggregations, not metered values —
      a difference against them is weaker evidence than one against a metered fuel total.</p></div>`;

  /* The selector opens the section it governs. It used to sit in the sticky bar
     at the top of the tab, directly above the two whole-stock charts — which it
     does not affect — so it read as a filter that was being ignored. A control
     immediately above content it does not change is worse than no control, and
     placing it here also marks where the breakdown section starts. */
  h+=`<div class="panel"><div class="head" style="margin:0">
      <h2 style="margin:0">Each fuel by breakdown — Total and Intensity side by side</h2></div>
    <div class="head" style="margin:10px 0 0"><span class="legend-title"
        style="margin:0 8px 0 0">Breakdown for the panels below</span>
      ${dimToggle("xDimCtl", availDims.map(d=>
        [d,(D.dimensions[d]||{label:d}).label.replace(/,.*$/,"")]), state.xDim)}</div></div>`;

  shownDims.forEach(dim=>{
    const spec=D.dimensions[dim]||{label:dim};
    const badge = spec.cbecs===false
      ? ` <span class="badge">ComStock only — CBECS has no climate zone</span>` : "";
    const binLab = spec.label.toLowerCase().replace(/,.*$/,"");
    const isBT = dim==="building_type";
    // the section anchor rides on the first panel of each bin
    let anchor=` id="sec-${dim}"`;
    if(isBT){
      h+=`<div class="panel"${anchor}><h2 style="margin-top:0">Floor area by building type
        <span class="badge">Mft²</span></h2>
        <p class="note" style="margin-top:0">The prevalence term for the two panels below,
        full-width because fifteen types need the room.</p>
        <div class="scroll" id="x-bt-area"></div></div>`;
      anchor="";
    }
    FUELS.forEach(([,slug,fuelLab])=>{
      h+=fuelBinPanel(`x-${dim}-${slug}`, fuelLab, binLab, badge, !isBT, anchor);
      anchor="";
    });
  });
  h+=fuelMixPanel();
  h+=enduseWaterfallPanel("All", ' id="sec-gap"');
  $("#view").innerHTML=h;
  renderEnduseWaterfalls("All");

  groupedBar($("#all-fuels"), allRows(D.fuelTotals), annualSeries(),
    {height:245, copy:{title:"All building types — fuel totals (TBtu)",
                       legend:runLegendItems(false)}});
  groupedBar($("#all-enduse"), allRows(D.endUses), annualSeries(),
    {height:265, copy:{title:"All building types — end uses by fuel (TBtu)",
                       legend:runLegendItems(true)}});
  shownDims.forEach(dim=>{
    const binLab=(D.dimensions[dim]||{label:dim}).label.toLowerCase().replace(/,.*$/,"");
    /* Climate zone has no CBECS counterpart, so its exports must not carry a
       CBECS legend key (there is no CBECS bar to key) and the title has to keep
       the ComStock-only warning that the shortened bin label drops. */
    const noCbecs=(D.dimensions[dim]||{}).cbecs===false;
    const legend=()=>noCbecs
      ? RUNS.map(r=>({color:r.color,label:r.label}))
      : runLegendItems(false);
    const suffix=noCbecs?" — ComStock only, no CBECS reference":"";
    FUELS.forEach(([m,slug,fuelLab])=>{
      groupedBar($(`#x-${dim}-${slug}-tot`), crossRows(dim,m,"total"), annualSeries(),
        {height:230, yLabel:"TBtu", compact:true,
         copy:{title:`${fuelLab} by ${binLab} — total (TBtu)${suffix}`, legend:legend()}});
      groupedBar($(`#x-${dim}-${slug}-eui`), crossRows(dim,m,"eui"), annualSeries(),
        {height:230, yLabel:"kBtu/ft²·yr", compact:true,
         copy:{title:`${fuelLab} by ${binLab} — intensity (kBtu/ft²·yr)${suffix}`,
               legend:legend()}});
      const areaHost=$(`#x-${dim}-${slug}-area`);
      if(areaHost) groupedBar(areaHost, crossRows(dim,"sqft","total"), annualSeries(),
        {height:230, yLabel:"Mft²", compact:true,
         copy:{title:`Floor area by ${binLab} (Mft²)${suffix}`, legend:legend()}});
    });
    if(dim==="building_type"){
      groupedBar($("#x-bt-area"), crossRows(dim,"sqft","total"), annualSeries(),
        {height:240, yLabel:"Mft²",
         copy:{title:"Floor area by building type (Mft²)", legend:runLegendItems(false)}});
    }
  });
  wireDimSig(renderCross);
  wireDimToggle("xDimCtl", "xDim", renderCross);
  // scroll manually: a real #anchor href would overwrite the state hash the
  // whole dashboard deep-links through
  document.querySelectorAll("[data-jump]").forEach(a=>a.addEventListener("click",ev=>{
    ev.preventDefault();
    const t=document.getElementById(a.dataset.jump);
    if(t) window.scrollTo({top:t.getBoundingClientRect().top+window.scrollY-110,
                           behavior:"smooth"});
  }));
}

function renderAnnual(){
  if(state.type===CROSS) return renderCross();
  const bt=state.type;
  const src=D.byDim.building_type||[];
  const mk = keys => keys.map(k=>{
    const values={}; let ciLow=null,ciHigh=null,prov="";
    RUNS.forEach(r=>{
      const m=src.find(x=>x.run===r.key&&x.category===bt&&x.metric===k);
      values[r.key]=m?m.comstock_value:null;
      if(m){ prov=m.provenance;
        if(values.cbecs===undefined&&m.cbecs_value!==null&&m.cbecs_value!==undefined){
          values.cbecs=m.cbecs_value; ciLow=m.cbecs_ci95_low; ciHigh=m.cbecs_ci95_high; } }
    });
    const any=Object.values(values).some(v=>v&&Math.abs(v)>0.01);
    return any?{label:shortLabel(k),values,ciLow,ciHigh,hatched:(prov||"").startsWith("disagg")}:null;
  }).filter(Boolean);

  let h=`
    <div class="panel"><div class="head">
      <h2>${bt}: annual consumption by fuel — TBtu
        <span class="badge">CBECS 2018 vs ${RUNS.map(r=>runShort(r.key)).join(" vs ")}</span>
        <span class="badge">national totals</span></h2>${dimSigToggle()}</div>
      ${annualLegend(false)}<div class="scroll" id="c-fuels"></div>
      <p class="note">Whiskers are the CBECS 95% confidence interval from its jackknife replicate
      weights. A bar inside the whiskers is consistent with the survey, not a gap to close.</p></div>
    <div class="panel"><h2>${bt}: annual consumption by fuel and end use — TBtu
        <span class="badge">CBECS 2018 vs ${RUNS.map(r=>runShort(r.key)).join(" vs ")}</span>
        <span class="badge">CBECS end uses hatched = EIA disaggregation</span></h2>
      ${annualLegend()}<div class="scroll" id="c-enduse"></div>
      <p class="note">Hatched CBECS bars are EIA statistical disaggregations, not metered values —
      a difference against them is weaker evidence than one against a metered fuel total.</p></div>`;
  const pairDims=Object.keys(D.byPair);
  const shownPairDims=dimsToShow(pairDims, state.xDim);
  h+=`<div class="panel"><div class="head" style="margin:0">
      <h2 style="margin:0">Each fuel by breakdown — ${bt}</h2></div>
    <div class="head" style="margin:10px 0 0"><span class="legend-title"
        style="margin:0 8px 0 0">Breakdown for the panels below</span>
      ${dimToggle("pDimCtl", pairDims.map(d=>
        [d,(D.dimensions[d]||{label:d}).label.replace(/,.*$/,"")]), state.xDim)}</div></div>`;
  shownPairDims.forEach(dim=>{
    const spec=D.dimensions[dim]||{label:dim};
    FUELS.forEach(([,slug,fuelLab])=>{
      h+=fuelBinPanel(`p-${dim}-${slug}`, fuelLab, `${spec.label.toLowerCase()} — ${bt}`);
    });
  });
  h+=enduseWaterfallPanel(bt);
  h+=`<div class="panel"><h2>${bt} — every metric <span class="badge">${runShort(PRIMARY)}</span></h2>
      <div class="scroll" id="t-all"></div></div>`;
  $("#view").innerHTML=h;
  renderEnduseWaterfalls(bt);
  groupedBar($("#c-fuels"), mk(D.fuelTotals), annualSeries(),
    {height:245, copy:{title:`${bt} — fuel totals (TBtu)`, legend:runLegendItems(false)}});
  groupedBar($("#c-enduse"), mk(D.endUses), annualSeries(),
    {height:265, copy:{title:`${bt} — end uses by fuel (TBtu)`, legend:runLegendItems(true)}});
  shownPairDims.forEach(dim=>{
    const binLab=(D.dimensions[dim]||{label:dim}).label.toLowerCase();
    FUELS.forEach(([m,slug,fuelLab])=>{
      groupedBar($(`#p-${dim}-${slug}-tot`), pairRows(dim,bt,m,"total"), annualSeries(),
        {height:230, yLabel:"TBtu", compact:true,
         copy:{title:`${fuelLab} by ${binLab} — ${bt} — total (TBtu)`, legend:runLegendItems(false)}});
      groupedBar($(`#p-${dim}-${slug}-eui`), pairRows(dim,bt,m,"eui"), annualSeries(),
        {height:230, yLabel:"kBtu/ft²·yr", compact:true,
         copy:{title:`${fuelLab} by ${binLab} — ${bt} — intensity (kBtu/ft²·yr)`, legend:runLegendItems(false)}});
      groupedBar($(`#p-${dim}-${slug}-area`), pairRows(dim,bt,"sqft","total"), annualSeries(),
        {height:230, yLabel:"Mft²", compact:true,
         copy:{title:`Floor area by ${binLab} — ${bt} (Mft²)`, legend:runLegendItems(false)}});
    });
  });
  wireDimSig(renderAnnual);
  wireDimToggle("pDimCtl", "xDim", renderAnnual);

  let t=`<p class="note">Every "% vs CBECS" is <b>${runLabel(PRIMARY)} minus CBECS, as a share of
    CBECS</b>.${MULTI&&SECONDARY?` "Δ gap vs ${runShort(SECONDARY.key)}" is the change in the
    absolute gap against that run; negative means closer to CBECS.`:""}</p>
    <table><thead><tr><th>Metric</th><th>CBECS</th><th>CBECS 95% CI</th>
    <th>${runLabel(PRIMARY)}</th><th>% vs CBECS</th>
    ${MULTI&&SECONDARY?`<th>Δ gap vs ${runShort(SECONDARY.key)} (pp)</th>`:""}
    <th>within CI</th><th>CBECS basis</th></tr></thead><tbody>`;
  const rows=src.filter(r=>r.run===PRIMARY&&r.category===bt);
  rows.sort((a,b)=>a.metric.localeCompare(b.metric)).forEach(r=>{
    const scale=r.metric==="sqft"?1e-6:1, unit=r.metric==="sqft"?" Mft²":"";
    const ci=(r.cbecs_ci95_low!==null&&r.cbecs_ci95_low!==undefined)
      ? `${fmt(r.cbecs_ci95_low*scale)}–${fmt(r.cbecs_ci95_high*scale)}`
      : absentTag("notPublished","CBECS publishes no confidence interval for this metric");
    const w=r.within_cbecs_ci95;
    const badge = w===true?`<span style="color:var(--good)">inside</span>`
      : w===false?`<span style="color:var(--bad)">outside</span>`
      : absentTag("notPublished","no CBECS interval to test against");
    let dcol="";
    if(MULTI&&SECONDARY){
      const o=src.find(x=>x.run===SECONDARY.key&&x.category===bt&&x.metric===r.metric);
      const d=(o&&o.pct_diff!==null&&o.pct_diff!==undefined
               &&r.pct_diff!==null&&r.pct_diff!==undefined)
        ? Math.abs(r.pct_diff)-Math.abs(o.pct_diff) : null;
      dcol=`<td>${d===null?absentTag("noValue"):`<span class="cell" style="background:${
        d<-0.5?"rgba(26,127,90,.22)":d>0.5?"rgba(213,94,0,.22)":"transparent"}">${
        (d>0?"+":"")+fmt(d,1)}</span>`}</td>`;
    }
    t+=`<tr><td>${r.metric}</td><td>${fmt(r.cbecs_value*scale,2)}${unit}</td><td>${ci}</td>
      <td>${fmt(r.comstock_value*scale,2)}${unit}</td>
      <td><span class="cell" style="background:${diffColor(r.pct_diff)}">${pct(r.pct_diff)}</span></td>
      ${dcol}<td>${badge}</td><td>${r.provenance||""}</td></tr>`;
  });
  $("#t-all").innerHTML=t+`</tbody></table>`;
}

/* Scope for the distribution boxes: the selected building type when the table
   carries a crossed row for it, otherwise pooled. Older assessments have no
   `btype` column at all, so treat a missing one as "All" and behave as before
   rather than filtering everything away. */
const distScope = () => {
  if(state.type===CROSS) return "All";
  const q=QUANT||[];
  if(!q.length || q[0].btype===undefined) return "All";
  return q.some(r=>r.btype===state.type) ? state.type : "All";
};

function distBoxCats(dim, metric, basis, datasets){
  const scope=distScope();
  const q=QUANT.filter(r=>r.metric===metric&&r.basis===basis&&r.dimension===dim
    && (r.btype===undefined || r.btype===scope));
  const order=D.ordered[dim]||D.sizeBinOrder;
  const cands=[...new Set(q.map(r=>r.category))];
  cands.sort((a,b)=> order?order.indexOf(a)-order.indexOf(b):String(a).localeCompare(String(b)));
  return cands.map(cat=>{
    const stats={};
    datasets.forEach(d=>{ const r=q.find(x=>x.category===cat&&x.dataset===d.key);
                          if(r) stats[d.key]=r; });
    return {label:String(cat), stats};
  }).filter(c=>Object.keys(c.stats).length);
}

function renderDistributions(){
  const basis=state.euiBasis;
  const datasets=[{key:"CBECS 2018",label:"CBECS 2018",color:D.cbecsColor}]
    .concat(RUNS.map(r=>({key:r.key,label:r.label,color:r.color})));

  // Every bin is shown, stacked: building type full-width (15 categories), the
  // other bins with the three fuels side by side.
  let h=`<div class="panel"><div class="head">
      <h2>Site and fuel EUI distributions by segment — kBtu/ft²·yr
        <span class="badge">CBECS 2018 vs ${RUNS.map(r=>runShort(r.key)).join(" vs ")}</span>
        <span class="badge">${basis==="count"?"building-count weighted":"floor-area weighted"}</span>
      </h2><span class="spacer"></span>
      <div class="tabs" role="group" aria-label="Weighting">
        <button class="tab" data-basis="count" aria-selected="${basis==="count"}">By buildings</button>
        <button class="tab" data-basis="area" aria-selected="${basis==="area"}">By floor area</button>
      </div></div>
    <div class="legend">${datasets.map(d=>swatch(d.color,d.label)).join("")}</div>
    <p class="note">Every part of these is <b>weighted on the basis in the badge above</b>:
    <b>box</b> = interquartile range (p25–p75), <b>solid line</b> = median, <b>dashed line</b> =
    mean, <b>whiskers</b> = 5th and 95th percentiles, <b>dots</b> = points beyond 1.5×IQR, and the
    shaded outline is a kernel density. Hover for the full statistics and sample size.
    ${basis==="count"
      ? "Weighted by building count — the distribution of a typical <i>building</i>."
      : "Weighted by floor area — where the <i>square footage</i>, and so most of the energy, sits."}
    In the non-building-type bins every building type is pooled, so a difference there can reflect
    stock composition as much as building physics. Gas nulls in CBECS count as zero so both sides
    describe all buildings; floor-area bins are derived from continuous floor area with identical
    edges on both sides, and CBECS has no buildings under 1,000 ft², so that bin is
    ComStock-only.</p></div>`;

  // "By building type" is a cross-stock cut: it appears only in the "All types"
  // view, since with one building type selected it would just repeat 15 types.
  const distAvail=Object.keys(D.distDims)
    /* "by building type" only makes sense pooled -- inside one type it would be
       a single box. The other breakdowns now filter to the selected type, so
       selecting one no longer leaves every panel unchanged. */
    .filter(dim=>dim!=="building_type"||distScope()==="All");
  const distDims=dimsToShow(distAvail, state.distDim);
  h+=`<div class="panel"><div class="head" style="margin:0">
      <h2 style="margin:0">EUI distributions by breakdown</h2></div>
    <div class="head" style="margin:10px 0 0"><span class="legend-title"
        style="margin:0 8px 0 0">Breakdown for the panels below</span>
      ${dimToggle("distDimCtl", distAvail.map(d=>
        [d,((D.distDims[d]||{}).label||d).replace(/,.*$/,"")]), state.distDim)}</div></div>`;
  distDims.forEach(dim=>{
    const lab=(D.distDims[dim]||{}).label||dim;
    if(dim==="building_type"){
      h+=`<div class="panel"><h2 style="margin-top:0">EUI distribution by ${lab.toLowerCase()} — kBtu/ft²·yr <span class="badge">${basis==="count"?"building-count weighted":"floor-area weighted"}</span><span class="badge">one box per building type</span></h2>`;
      EUI_METRICS.forEach(([m,ml])=>{
        h+=`<h3>${ml} EUI by ${lab.toLowerCase()} — kBtu/ft²·yr</h3>
            <div class="scroll" id="dist-${dim}-${m.replace(/[^a-z_]/g,"")}"></div>`;
      });
      h+=`</div>`;
    } else {
      h+=`<div class="panel"><h2 style="margin-top:0">EUI distribution by ${lab.toLowerCase()} — kBtu/ft²·yr <span class="badge">${basis==="count"?"building-count weighted":"floor-area weighted"}</span><span class="badge">${distScope()==="All"?"all building types pooled":distScope()}</span></h2><div class="grid-dist">`;
      EUI_METRICS.forEach(([m,ml])=>{
        h+=`<div><h3>${ml} EUI by ${lab.toLowerCase()} — kBtu/ft²·yr</h3>
            <div id="dist-${dim}-${m.replace(/[^a-z_]/g,"")}"></div></div>`;
      });
      h+=`</div></div>`;
    }
  });

  const histType = state.type===CROSS ? D.buildingTypes[0] : state.type;
  h+=`<div class="panel"><div class="head">
      <h2>${histType}: ${(EUI_METRICS.find(m=>m[0]===state.euiMetric)||["","Site energy"])[1]
        .toLowerCase()} EUI distribution — % of
        ${basis==="count"?"buildings":"floor area"} per bin
        <span class="badge">kBtu/ft²·yr</span>
        <span class="badge">clipped at the 99th percentile</span></h2><span class="spacer"></span>
      <select id="histMetric" aria-label="Metric">${EUI_METRICS.map(([k,l])=>
        `<option value="${k}" ${k===state.euiMetric?"selected":""}>${l}</option>`).join("")}</select>
      </div>
      <div class="legend">${datasets.map(d=>swatch(d.color,d.label)).join("")}</div>
      <div id="hist"></div>
      <p class="note" id="histnote"></p></div>`;
  $("#view").innerHTML=h;

  distDims.forEach(dim=>{
    const compact = dim!=="building_type";
    const lab=((D.distDims[dim]||{}).label||dim).toLowerCase();
    EUI_METRICS.forEach(([m,ml])=>{
      boxPlot($(`#dist-${dim}-${m.replace(/[^a-z_]/g,"")}`),
              distBoxCats(dim,m,basis,datasets), datasets,
              {height:compact?260:290, compact,
               copy:{title:`${ml} EUI by ${lab} (kBtu/ft²·yr, ${basis==="count"?"building":"floor-area"}-weighted)`,
                     legend:datasetLegendItems()}});
    });
  });

  const metric = state.euiMetric, mlabel = (EUI_METRICS.find(x=>x[0]===metric)||[])[1] || metric;

  const bt = histType;
  const hrows=D.histograms.filter(r=>r.metric===metric&&r.basis===basis&&r.building_type===bt);
  const byBin={};
  hrows.forEach(r=>{
    const k=r.bin_left.toFixed(4);
    (byBin[k] ||= {left:r.bin_left,right:r.bin_right,shares:{}}).shares[r.dataset]=r.weighted_share;
  });
  const bins=Object.values(byBin).sort((a,b)=>a.left-b.left);
  histChart($("#hist"), bins, datasets,
    {xLabel:`${mlabel} EUI (kBtu/ft²·yr)`,
     yLabel:`% of ${basis==="count"?"buildings":"floor area"}`,
     copy:{title:`${bt} — ${mlabel} EUI distribution (${basis==="count"?"building":"floor-area"}-weighted share)`,
           legend:datasetLegendItems()}});
  const clip=hrows.length?hrows[0].clip_value:null;
  $("#histnote").innerHTML = bins.length
    ? `Share of ${basis==="count"?"weighted buildings":"weighted floor area"} per bin for
       <b>${bt}</b>${state.type===CROSS?" (choose a building type in the header to change this)":""}.
       Axis is clipped at the 99th percentile (${fmt(clip,0)} kBtu/ft²) so a few extreme buildings
       cannot flatten the visible distribution — mass beyond the clip is folded into the last bin.`
    : "No histogram data for this selection.";

  $("#histMetric").addEventListener("change", e=>{ state.euiMetric=e.target.value; renderDistributions(); syncHash(); });
  document.querySelectorAll("[data-basis]").forEach(b=>
    b.addEventListener("click",()=>{ state.euiBasis=b.dataset.basis; renderDistributions(); syncHash(); }));
  wireDimToggle("distDimCtl", "distDim", renderDistributions);
}

/* Region selector: regions with no data for the current building type are
   greyed out (disabled) so coverage is visible without clicking through. */
function amiRegionSelect(sn){
  // sn === null  -> cross-cutting view, no type filter, every region usable.
  // sn undefined -> the type has no AMI key at all (nothing in typeToSnake),
  //                 so no region can have data and every option is disabled.
  //                 Treating that as "no filter" is what previously left every
  //                 region selectable for Grocery.
  const noKey = sn === undefined;
  return `<select id="amiRegion" aria-label="AMI region">${AMI_REGIONS.map(r=>{
    const has=!noKey&&(sn===null||(D.amiProfiles[r]||[]).some(p=>p.building_type===sn));
    return `<option value="${r}" ${r===state.amiRegion?"selected":""} ${has?"":"disabled"}>${
      r}${has?"":" — no data"}</option>`;}).join("")}</select>`;
}

/* load duration curve: full-year hourly load sorted descending, both sides */
function ldcChart(host, pts, opts={}){
  const W=660,H=300,padL=60,padR=14,padT=12,padB=44;
  if(!pts.length){ host.innerHTML='<p class="note">No records for this selection.</p>'; return; }
  const plotW=W-padL-padR, plotH=H-padT-padB;
  const xMax=Math.max(...pts.map(p=>p.hours))||1;
  // Same 0/0 trap as profileChart: an all-zero curve must still draw.
  const yRaw=Math.max(...pts.flatMap(p=>[p.comstock,p.amiHi,p.comstock2])
    .filter(v=>v!==null&&v!==undefined));
  const yMax=yRaw>0 ? yRaw*1.08 : 1;
  const x=h=>padL+(h/xMax)*plotW, y=v=>padT+plotH-(v/yMax)*plotH;
  const dec=Math.min(6,Math.max(0,1-Math.floor(Math.log10(yMax))));
  const svg=el("svg",{viewBox:`0 0 ${W} ${H}`, style:figStyle(W)});
  for(let i=0;i<=4;i++){
    const v=yMax*i/4, yy=y(v);
    svg.appendChild(el("line",{x1:padL,y1:yy,x2:W-padR,y2:yy,class:"gl"}));
    const t=el("text",{x:padL-8,y:yy+4,class:"ax","text-anchor":"end"});
    t.textContent=v.toFixed(dec); svg.appendChild(t);
  }
  [0,.25,.5,.75,1].forEach(f=>{
    const t=el("text",{x:x(xMax*f),y:H-padB+16,class:"ax","text-anchor":"middle"});
    t.textContent=Math.round(xMax*f).toLocaleString(); svg.appendChild(t);
  });
  const xl=el("text",{x:padL+plotW/2,y:H-8,class:"axl","text-anchor":"middle"});
  xl.textContent="Hours equaled or exceeded"; svg.appendChild(xl);
  const yl=el("text",{x:14,y:padT+plotH/2,class:"axl","text-anchor":"middle",
    transform:`rotate(-90 14 ${padT+plotH/2})`});
  yl.textContent="kWh/ft²"; svg.appendChild(yl);
  const line=(key,color,dash,width)=>{
    const d=pts.map((p,i)=>`${i?"L":"M"}${x(p.hours).toFixed(1)},${y(p[key]).toFixed(1)}`).join(" ");
    svg.appendChild(el("path",{d,fill:"none",stroke:color,"stroke-width":width||2,
      "stroke-linejoin":"round",...(dash?{"stroke-dasharray":dash}:{})}));
  };
  line("amiHi","var(--ink)","4 3",1.3);
  line("amiLo","var(--ink)","4 3",1.3);
  line("ami","var(--ink)","");
  if(pts.some(p=>p.comstock2!==null&&p.comstock2!==undefined))
    line("comstock2",opts.comstock2Color||"#56B4E9","7 4",2);
  line("comstock",opts.comstockColor||"#0072B2","");
  svg.appendChild(el("rect",{x:padL,y:padT,width:plotW,height:plotH,
    fill:"none",stroke:"var(--ink-2)","stroke-width":1}));
  const hit=el("rect",{x:padL,y:padT,width:plotW,height:plotH,fill:"transparent"});
  hit.addEventListener("mousemove",ev=>{
    const bb=svg.getBoundingClientRect();
    const hx=(ev.clientX-bb.left)/bb.width*W;
    const target=(hx-padL)/plotW*xMax;
    let best=pts[0];
    pts.forEach(p=>{ if(Math.abs(p.hours-target)<Math.abs(best.hours-target)) best=p; });
    showTip(`<b>top ${best.hours.toLocaleString()} hours</b>`+
      `<div class="row"><span>ComStock</span><span>${fmt(best.comstock,4)}</span></div>`+
      `<div class="row"><span>AMI</span><span>${fmt(best.ami,4)}</span></div>`+
      `<div class="row"><span>AMI 80% CI</span><span>${fmt(best.amiLo,4)}–${fmt(best.amiHi,4)}</span></div>`,ev);
  });
  hit.addEventListener("mouseleave",hideTip);
  svg.appendChild(hit);
  plotFrame(svg, padL, padT, plotW, plotH);
  host.innerHTML=""; attachChart(host, svg, opts.copy);
}
function wireAmiRegion(){
  const s=$("#amiRegion");
  if(s) s.addEventListener("change", e=>{ state.amiRegion=e.target.value; renderAmi(); syncHash(); });
}

/* cross-region agreement: shape RMSE and overnight delta per type x region */
function renderAmiAgreement(){
  const ag=D.amiAgreement||[];
  if(!ag.length){
    $("#view").innerHTML=`<div class="panel"><h2>Cross-region agreement</h2>
      <p class="note">No agreement table in this assessment — it is built when the
      dashboard runs with <code>region="all"</code> (the default).</p></div>`;
    return;
  }
  const regions=[...new Set(ag.map(r=>r.region))].sort();
  const types=[...new Set(ag.map(r=>r.building_type))].sort();
  const cell=(bt,rg)=>ag.find(r=>r.building_type===bt&&r.region===rg);
  let h=`<div class="panel"><h2>${runShort(PRIMARY)} minus AMI metered: overnight share of daily
      energy, by building type and region — pp
      <span class="badge">hours 0–5, day-normalized</span></h2>
    <p class="note">Each cell is one region's verdict on one building type: how many percentage
    points more (orange) or less (blue) of the day's energy ComStock puts into hours 0–5 than the
    meters do, averaged over seasons and day types. Read across a row: the <b>same sign in most
    regions is a model problem; mixed signs point at regional weather or local stock</b>. The
    consistency column applies a two-thirds rule over covered regions.</p>
    ${amiRegionSelect(null)}
    <div class="scroll" style="margin-top:10px"><table><thead><tr><th>Building type</th>
      ${regions.map(r=>`<th>${r}</th>`).join("")}<th>Consistency</th></tr></thead><tbody>`;
  types.forEach(bt=>{
    const flag=(ag.find(r=>r.building_type===bt)||{}).consistency||"";
    h+=`<tr><td>${bt}</td>`+regions.map(rg=>{
      const c=cell(bt,rg);
      if(!c) return `<td style="color:var(--ink-3)">—</td>`;
      const v=c.overnight_delta_pp;
      return `<td><span class="cell" style="background:${diffColor(v*4)}">${
        (v>0?"+":"")+v.toFixed(1)}</span></td>`;
    }).join("")+`<td>${flag==="systematic"?"<b>systematic</b>":flag}</td></tr>`;
  });
  h+=`</tbody></table></div>
  <p class="note">Shape RMSE per cell is in the hover of the profile views and in
  <code>ami_cross_region_agreement.csv</code>. Regions cover different types — a dash means no
  usable truth data there.</p></div>`;
  $("#view").innerHTML=h;
  wireAmiRegion();
}

/* ---------- day-period alignment ----------
   Overnight share alone answers one question about shape. These periods cover
   the whole day, so a reader can see WHERE in the day the model diverges, not
   just that it does. Each figure is a share of that panel's own 24-hour total,
   which makes it independent of the AMI floor-area denominator — the same
   reason the profile view defaults to a normalized scale. */
const DAY_PERIODS=[["Overnight",0,5],["Morning rise",6,9],["Midday",10,15],
  ["Evening peak",16,20],["Late evening",21,23]];
function periodAlignment(pts){
  const key=p=>`${p.season}|${p.day_type}`;
  const panels={};
  pts.forEach(p=>{ (panels[key(p)]=panels[key(p)]||[]).push(p); });
  return Object.entries(panels).map(([k,rows])=>{
    const [season,day]=k.split("|");
    // payload rows carry the raw CSV column names
    const CS=r=>+r.comstock_kwh_per_sf||0, AM=r=>+r.ami_kwh_per_sf||0;
    const cs=h=>rows.filter(r=>r.hour>=h[0]&&r.hour<=h[1]).reduce((t,r)=>t+CS(r),0);
    const am=h=>rows.filter(r=>r.hour>=h[0]&&r.hour<=h[1]).reduce((t,r)=>t+AM(r),0);
    const csTot=cs([0,23]), amTot=am([0,23]);
    if(!csTot||!amTot) return null;
    const periods=DAY_PERIODS.map(([lab,a,b])=>({lab,
      cs:100*cs([a,b])/csTot, am:100*am([a,b])/amTot}));
    const peakOf=f=>rows.reduce((best,r)=>(f(r)>f(best)?r:best),rows[0]).hour;
    const meanOf=f=>rows.reduce((t,r)=>t+f(r),0)/rows.length;
    const maxOf=f=>Math.max(...rows.map(f));
    const csPeakHr=peakOf(CS), amPeakHr=peakOf(AM);
    const csPk=maxOf(CS)/(meanOf(CS)||1);
    const amPk=maxOf(AM)/(meanOf(AM)||1);
    return {season, day, periods, csPeakHr, amPeakHr, csPk, amPk};
  }).filter(Boolean);
}
function periodTable(rows){
  if(!rows.length) return `<p class="note">No overlapping hours to compare.</p>`;
  const order={Summer:0,Shoulder:1,Winter:2};
  rows.sort((a,b)=>(order[a.season]-order[b.season])||a.day.localeCompare(b.day));
  const cell=v=>`<span class="cell" style="background:${diffColor(v*5)}">${
    (v>0?"+":"")+v.toFixed(1)}</span>`;
  return `<div class="scroll"><table><thead><tr><th>Season</th><th>Day type</th>
    ${DAY_PERIODS.map(([l,a,b])=>`<th>${l}<br><span style="font-weight:400;color:var(--ink-3)">${
      String(a).padStart(2,"0")}–${String(b).padStart(2,"0")}h</span></th>`).join("")}
    <th>Peak hour<br><span style="font-weight:400;color:var(--ink-3)">CS / AMI</span></th>
    <th>Peak ÷ mean<br><span style="font-weight:400;color:var(--ink-3)">CS / AMI</span></th>
    </tr></thead><tbody>
    ${rows.map(r=>`<tr><td>${r.season}</td><td>${r.day}</td>
      ${r.periods.map(p=>`<td>${cell(p.cs-p.am)}</td>`).join("")}
      <td>${r.csPeakHr} / ${r.amPeakHr}${
        r.csPeakHr!==r.amPeakHr?` <b>(${r.csPeakHr>r.amPeakHr?"+":""}${
          r.csPeakHr-r.amPeakHr}h)</b>`:""}</td>
      <td>${r.csPk.toFixed(2)} / ${r.amPk.toFixed(2)}</td></tr>`).join("")}
    </tbody></table></div>`;
}

function renderAmi(){
  const bt=state.type, sn=snake(bt);
  if(state.type===CROSS) return renderAmiAgreement();
  const region=state.amiRegion;
  const allRows=(D.amiProfiles[region]||[]).filter(r=>r.building_type===sn);
  // Rows carry a `run` column when the assessment ran the AMI leg for more than
  // one run; older assessments have no run column and are primary-only.
  const pts=allRows.filter(r=>!r.run||r.run===PRIMARY);
  const secRows=SECONDARY?allRows.filter(r=>r.run===SECONDARY.key):[];
  const met=(D.amiShape[region]||[]).filter(r=>r.building_type===sn);
  if(!pts.length){
    // A type with no AMI key at all (no entry in typeToSnake) can never match
    // any region, so say that instead of inviting a hunt through the dropdown.
    const noKey=!sn;
    $("#view").innerHTML=`<div class="panel"><div class="head">
      <h2>${bt} — no AMI comparison${noKey?"":` in <b>${region}</b>`}</h2>
      <span class="spacer"></span>${amiRegionSelect(sn)}</div>
      <p class="note">${noKey
        ? `<b>${bt}</b> has no AMI counterpart in any region — the metered dataset does not carry
           this building type, so there is nothing to compare against anywhere and every region
           is disabled above. This is a data-coverage gap, not a model result.`
        : `No usable AMI truth data for this building type in this region — a data-coverage gap,
           not a model result. Try another region above; the agreement matrix under
           "All types — cross-cutting" shows which regions cover which types.`}</p></div>`;
    wireAmiRegion();
    return;
  }
  const norm = state.amiMode!=="abs";
  const NORM_LABEL = {daytype:"Normalized (day sum = 1)", annual:"Normalized (annual sum = 1)"};
  // Row/column layout matching the repo's plots: rows = seasons, cols = day types.
  const SEASON_ORDER=["Summer","Winter","Shoulder"];
  const DAY_ORDER=["Weekday","Weekend"];

  /* `all` keeps switched-off end uses in the list so the on-screen legend can
     grey them out in place (a key that vanishes gives you nothing to click to
     bring the layer back). Exports and the expanded view take the default,
     visible-only list, so a static figure never keys a layer it does not draw. */
  function amiLegendItems(all){
    const keys=all?(D.enduseOrder||[]):euOrderVisible();
    const items=keys.slice().reverse().map(k=>({color:D.enduseColors[k]||"#888",
      label:k.replace(/_/g," "), euKey:k}));
    /* Hiding an end use makes profileChart draw the run's FULL total as a solid
       line, because the stack top no longer is that total. That line was drawn
       without ever being keyed, so it appeared unannounced and unexplained —
       the one thing a legend exists to prevent. It is listed whenever it is
       drawn, and only when it is drawn. */
    if(euAnyHidden())
      items.push({color:runColor(PRIMARY),
        label:`${runShort(PRIMARY)} total, all end uses`, line:true});
    items.push({color:"#1a1d1f", label:"AMI metered", line:true});
    if(secRows.length)
      items.push({color:SECONDARY.color, label:`${runShort(SECONDARY.key)} total`, line:true, dash:true});
    return items;
  }
  function amiLegendHTML(){
    // End-use keys are clickable here too; the AMI/ComStock line keys are not,
    // since hiding a reference line would just hide the comparison.
    const hid=euHidden();
    return amiLegendItems(true).map(i=>{
      const c=i.color==="#1a1d1f"?"var(--ink)":i.color;
      const attrs=(i.euKey&&!i.line&&!i.band)
        ? ` data-eu="${i.euKey}" role="button" aria-pressed="${!hid.has(i.euKey)}"
            title="click to hide or show this end use"` : "";
      return `<span class="key"${attrs}>${
        i.band?`<span class="sw" style="background:var(--ink);opacity:.18"></span>`
        :i.line?`<span style="width:14px;height:0;border-top:2.5px ${i.dash?"dashed":"solid"} ${c};display:inline-block;flex:none"></span>`
        :`<span class="sw" style="background:${i.color}"></span>`}${i.label}</span>`;}).join("")
      + ((D.enduseOrder||[]).some(k=>hid.has(k))
        ? `<span class="key" data-eu="__all__" role="button" aria-pressed="true"
           style="cursor:pointer;font-weight:600">show all</span>` : "");
  }
  const stackKeys = euOrderVisible().filter(k=>pts.some(p=>p["eu_"+k]!==null&&p["eu_"+k]!==undefined));
  const seasons=[...new Set(pts.map(p=>p.season))], days=[...new Set(pts.map(p=>p.day_type))];

  let h=`<div class="panel"><div class="head">
      <h2>${runShort(PRIMARY)} vs AMI metered: mean hourly electricity by season and day type —
        ${bt}, ${region} — ${norm?NORM_LABEL[state.amiMode].toLowerCase():"kWh/ft² per hour"}
        ${euAnyHidden()?`<span class="badge" style="color:var(--bad)">end uses hidden — the
          stack is a subset; the solid ${runShort(PRIMARY)} line is the full total</span>`:""}</h2>
      <span class="spacer"></span>
      ${amiRegionSelect(sn)}
      <button class="btn-mini" data-gfs="gami" title="Expand all panels">&#9134; all</button>
      <button class="btn-mini" id="ami-copy">Copy all</button>
      <div class="tabs" role="group" aria-label="Profile scale">
        <button class="tab" data-ami="annual" aria-selected="${state.amiMode==="annual"}">Annual sum = 1</button>
        <button class="tab" data-ami="daytype" aria-selected="${state.amiMode==="daytype"}">Day sum = 1</button>
        <button class="tab" data-ami="abs" aria-selected="${state.amiMode==="abs"}">kWh/ft²</button>
      </div></div>
    <p class="note">${norm
      ? `Every series is divided by a single scalar — ${state.amiMode==="daytype"
          ? "this day type's own 24-hour sum, so each profile sums to 1"
          : "its dataset's annual total, so the whole year sums to 1"} — matching the
         <code>${state.amiMode==="daytype"?"Daytype":"Annual"}</code> normalization in the
         postprocessing script. Because the divisor is a scalar, the end-use stack is untouched:
         every end use stays visible and the layers still sum to the normalized ComStock total.
         The level, and with it any error in the AMI floor-area denominator, divides out.`
      : `ComStock end uses are stacked in the OpenStudio palette; the stack top is the ComStock
         total. This view depends on the AMI floor-area estimate — where that is uncertain, use a
         normalized view.`}
      The solid dark line is metered AMI; the dashed dark lines are its 80% confidence interval.
      ${secRows.length?`The dashed <b style="color:${SECONDARY.color}">${runShort(SECONDARY.key)}</b> line is
      the comparison run's total on the same basis, so whether this run moved toward or away from
      the meters reads directly.`:""}
      Shaded column is hours 0–5, where a setback or overnight-load difference shows up most clearly.
      Each subplot's Copy button puts a report-ready PNG on the clipboard — white background, title
      and legend included.</p>
    <div class="ami-wrap">
      <div class="ami-grid" id="prof"></div>
      <div class="ami-legend">${amiLegendHTML()}</div>
    </div></div>`;

  const ldcAll=(D.amiLdc[region]||[]).filter(r=>r.building_type===sn);
  const ldcSec={};
  if(SECONDARY) ldcAll.filter(r=>r.run===SECONDARY.key)
    .forEach(r=>{ ldcSec[r.hours]=r.comstock_kwh_per_sf; });
  const ldcPts=ldcAll.filter(r=>!r.run||r.run===PRIMARY)
    .map(r=>({hours:r.hours, comstock:r.comstock_kwh_per_sf, ami:r.ami_kwh_per_sf,
      comstock2:ldcSec[r.hours]??null,
      /* null, never NaN: a region with no measured sampling uncertainty gets no
         band at all rather than a fabricated one. ldcChart draws the pair only
         when amiHi is non-null (line 1252), and NaN would slip past that test
         and poison the axis maximum. */
      ...(Number.isFinite(+r.ami_unc)
        ? {amiHi:r.ami_kwh_per_sf*(1+r.ami_unc),
           amiLo:Math.max(r.ami_kwh_per_sf*(1-r.ami_unc),0)}
        : {amiHi:null, amiLo:null})}))
    .sort((a,b)=>a.hours-b.hours);
  if(ldcPts.length){
    h+=`<div class="panel"><h2>${runShort(PRIMARY)} vs AMI metered: electricity load duration curve — hourly kWh/ft²
        <span class="badge">${region}</span>
        <span class="badge">8,760 hours sorted descending</span></h2>
      <p class="note">Every hour of the year sorted from highest load to lowest, each dataset
      independently. Dashed lines are the AMI 80% sampling interval at its maximum over the year,
      matching the repo's load-duration plot. Always kWh/ft² regardless of the profile scale
      toggle, so it keeps the level information the normalized profiles drop.</p>
      <div id="ldc" style="max-width:700px"></div></div>`;
  }

  h+=`<div class="panel"><h2>${runShort(PRIMARY)} minus AMI metered: share of daily energy by
      period — ${bt}, ${region} — pp
      <span class="badge">day-normalized</span></h2>
    <p class="note">Orange = ComStock puts more of the day's energy in that period than the meters
    do, blue = less. The five periods sum to zero across a row, so this reads as
    <b>redistribution</b> within the day rather than a level error.</p>
    ${periodTable(periodAlignment(pts))}</div>`;

  h+=`<div class="panel"><h2>${runShort(PRIMARY)} vs AMI metered: hourly profile agreement by
      season and day type — ${bt}, ${region}
      <span class="badge">${norm?NORM_LABEL[state.amiMode]:"kWh/ft² levels"}</span>
      <span class="badge">RMSE in pts, NMBE and CV(RMSE) in %</span></h2>
    <div class="scroll"><table><thead><tr><th>Season</th><th>Day type</th>`;
  h+= norm
    ? `<th>Shape RMSE (pts)</th><th>Correlation</th><th>Overnight share CS</th>
       <th>Overnight share AMI</th><th>Overnight ratio CS</th><th>Overnight ratio AMI</th>
       <th>Peak hour CS</th><th>Peak hour AMI</th>`
    : `<th>Shape RMSE (pts)</th><th>Norm. CV(RMSE) %</th><th>NMBE % (level)</th>
       <th>CV(RMSE) % (level)</th><th>Overnight ratio CS</th><th>Overnight ratio AMI</th>
       <th>Peak hour CS</th><th>Peak hour AMI</th><th>AMI 80% CI</th>`;
  h+=`</tr></thead><tbody>`;
  met.forEach(r=>{
    h+=`<tr><td>${r.season}</td><td>${r.day_type}</td>`;
    h+= norm
      ? `<td>${fmt(r.daytype_shape_rmse_pts,2)}</td><td>${fmt(r.shape_corr,3)}</td>
         <td>${fmt(100*r.overnight_share_comstock,1)}%</td><td>${fmt(100*r.overnight_share_ami,1)}%</td>
         <td>${fmt(r.overnight_ratio_comstock,2)}</td><td>${fmt(r.overnight_ratio_ami,2)}</td>
         <td>${r.peak_hour_comstock}</td><td>${r.peak_hour_ami}</td>`
      : `<td>${fmt(r.daytype_shape_rmse_pts,2)}</td><td>${fmt(r.daytype_cvrmse_pct)}</td>
         <td><span class="cell" style="background:${diffColor(r.nmbe_pct)}">${pct(r.nmbe_pct)}</span></td>
         <td>${fmt(r.cvrmse_pct)}</td><td>${fmt(r.overnight_ratio_comstock,2)}</td>
         <td>${fmt(r.overnight_ratio_ami,2)}</td>
         <td>${r.peak_hour_comstock}</td><td>${r.peak_hour_ami}</td>
         <td>±${fmt(r.ami_mean_sample_uncertainty_80ci*100)}%</td>`;
    h+=`</tr>`;
  });
  h+=`</tbody></table></div><p class="note">${norm
    ? `Shape RMSE is the hour-by-hour distance between the two day-sum-normalized profiles, in
       points of the day's energy (0 = identical shape). "Overnight share" is the percentage of the
       day's energy falling in hours 0–5 — a scalar normalization cannot change it, so it reads the
       same in every view. A higher ComStock share than AMI means the model puts relatively more of
       its day into the overnight hours than the meters do.`
    : `The first two columns are computed on day-sum-normalized profiles and are the ones to trust:
       they do not depend on the AMI floor-area denominator. The level NMBE and CV(RMSE) that follow
       (ASHRAE Guideline 14 definitions, reported descriptively) do depend on it, so read them as
       secondary. The overnight ratio (hours 0–5 mean ÷ daily mean) is level-free either way.`}</p></div>`;
  $("#view").innerHTML=h;

  const g=$("#prof");
  const seasonRows=SEASON_ORDER.filter(s=>seasons.includes(s));
  const dayCols=DAY_ORDER.filter(d=>days.includes(d));
  const figureCharts=[];
  /* Two passes: build every panel's series first, then render them all on one
     shared scale. Rendering inside the loop gave each panel its own autoscale,
     so the six seasonal panels could not be compared by eye. */
  const pending=[];
  seasonRows.forEach(s=>dayCols.forEach(d=>{
    const raw=pts.filter(p=>p.season===s&&p.day_type===d).sort((a,b)=>a.hour-b.hour);
    // Comparison run's total for the same panel, normalized by ITS OWN divisor
    // in each mode so both runs are on the convention's terms.
    const sec=secRows.filter(p=>p.season===s&&p.day_type===d).sort((a,b)=>a.hour-b.hour);
    let secByHour={};
    if(sec.length){
      let div=1;
      if(state.amiMode==="daytype") div=sec.reduce((t,p)=>t+(p.comstock_kwh_per_sf||0),0);
      else if(state.amiMode==="annual") div=sec[0].comstock_annual_kwh_per_sf;
      sec.forEach(p=>{ secByHour[p.hour]=div?p.comstock_kwh_per_sf/div:null; });
    }
    const box=document.createElement("div");
    box.className="chartbox";
    box.innerHTML=`<div class="head"><h3>${s} · ${d}</h3></div><div class="chart"></div>`;
    g.appendChild(box);
    if(!raw.length){
      box.querySelector(".chart").innerHTML='<p class="note">No data for this day type.</p>';
      return;
    }
    let sub, stackBase=0;
    if(state.amiMode!=="abs"){
      // Scalar-divisor normalizations, matching the postprocessing script:
      //   daytype — divide by this day type's own sum (day sum = 1)
      //   annual  — divide by the dataset's annual sum (annual sum = 1)
      // Because the divisor is a single scalar, the end-use stack is untouched:
      // every layer stays visible and the layers still sum to the normalized
      // ComStock total. Nothing is clipped.
      let csDiv, amDiv;
      if(state.amiMode==="daytype"){
        csDiv = raw.reduce((s,p)=>s+(p.comstock_kwh_per_sf||0),0);
        amDiv = raw.reduce((s,p)=>s+(p.ami_kwh_per_sf||0),0);
      } else {
        csDiv = raw[0].comstock_annual_kwh_per_sf;
        amDiv = raw[0].ami_annual_kwh_per_sf;
      }
      sub=raw.map(p=>{
        const eu={}; stackKeys.forEach(k=>eu[k]=csDiv?(p["eu_"+k]||0)/csDiv:0);
        const ami=amDiv?p.ami_kwh_per_sf/amDiv:null;
        const u=p.ami_sample_uncertainty||0;
        return {hour:p.hour,
          comstock:csDiv?p.comstock_kwh_per_sf/csDiv:null, ami,
          comstock2:secByHour[p.hour]??null,
          amiHi:ami===null?null:ami*(1+u), amiLo:ami===null?null:Math.max(ami*(1-u),0),
          rawComstock:p.comstock_kwh_per_sf, rawAmi:p.ami_kwh_per_sf, eu};
      });
    } else {
      sub=raw.map(p=>{
        const u=p.ami_sample_uncertainty||0;
        const eu={}; stackKeys.forEach(k=>eu[k]=p["eu_"+k]);
        return {hour:p.hour, comstock:p.comstock_kwh_per_sf, ami:p.ami_kwh_per_sf,
          comstock2:secByHour[p.hour]??null,
          rawComstock:p.comstock_kwh_per_sf, rawAmi:p.ami_kwh_per_sf,
          amiHi:p.ami_kwh_per_sf*(1+u), amiLo:Math.max(p.ami_kwh_per_sf*(1-u),0), eu};
      });
    }
    pending.push({box, sub, label:`${s} · ${d}`,
      opts:{title:`${s} ${d}`, normalized:norm, stack:true, stackKeys, stackBase,
       comstockColor:runColor(PRIMARY), comstock2Color:SECONDARY?SECONDARY.color:undefined,
       comstock2Label:SECONDARY?runShort(SECONDARY.key):undefined,
       showTotalLine:euAnyHidden(),
       yLabel:norm?NORM_LABEL[state.amiMode]:"kWh/ft² per hour",
       copy:{title:`${bt} — ${region} — ${s} ${d} mean hourly electricity, `
               +`${norm?NORM_LABEL[state.amiMode].toLowerCase():"kWh/ft² per hour"}`,
             legend:amiLegendItems()}}});
  }));
  const amiShared=sharedProfileMax(pending);
  pending.forEach(p=>{
    profileChart(p.box.querySelector(".chart"), p.sub, {...p.opts, yMax:amiShared});
    figureCharts.push({svg:p.box.querySelector(".chart svg"), label:p.label});
  });
  const unit = norm ? NORM_LABEL[state.amiMode].toLowerCase() : "kWh/ft² per hour";
  const amiTitle=`${bt} — ${region} — mean hourly electricity by season and day type, ${unit}`;
  wireCopy($("#ami-copy"), ()=>figureCharts, 2, amiTitle, amiLegendItems());
  registerGroup("gami", [], [], amiLegendItems(), amiTitle, 2);
  GROUPS.gami.charts=figureCharts;
  if(ldcPts.length){
    const ldcLegend=[{color:runColor(PRIMARY),label:runLabel(PRIMARY),line:true}];
    if(Object.keys(ldcSec).length)
      ldcLegend.push({color:SECONDARY.color,label:`${runShort(SECONDARY.key)} (dashed)`,line:true,dash:true});
    ldcLegend.push({color:"#1a1d1f",label:"AMI metered",line:true},
                   {color:"#1a1d1f",label:"AMI 80% CI (dashed)",line:true,dash:true});
    ldcChart($("#ldc"), ldcPts, {comstockColor:runColor(PRIMARY),
      comstock2Color:SECONDARY?SECONDARY.color:undefined,
      copy:{title:`${bt} — ${region} — load duration curve (kWh/ft², full year)`,
            legend:ldcLegend}});
  }
  wireAmiRegion();
  wireEnduseLegend(renderAmi);
  wireGroups();
  document.querySelectorAll("[data-ami]").forEach(b=>
    b.addEventListener("click",()=>{ state.amiMode=b.dataset.ami; renderAmi(); syncHash(); }));
}

/* The season caption is generated from the same month lists that group the
   data, so it cannot drift. It is this tool's own national convention, NOT an
   upstream one: upstream sets season months per AMI region (the AMI tab uses
   those verbatim), and has no national default to copy. */
const MONTH_ABBR=["","Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
function monthRanges(ms){
  const s=[...ms].sort((a,b)=>a-b), out=[];
  let i=0;
  while(i<s.length){
    let j=i;
    while(j+1<s.length&&s[j+1]===s[j]+1) j++;
    out.push(i===j?MONTH_ABBR[s[i]]:`${MONTH_ABBR[s[i]]}–${MONTH_ABBR[s[j]]}`);
    i=j+1;
  }
  return out.join(" & ");
}
function seasonSentence(){
  const ss=D.measureSeasons||{};
  const parts=["Summer","Shoulder","Winter"].filter(k=>ss[k]&&ss[k].length)
    .map(k=>`${k} ${monthRanges(ss[k])}`);
  if(!parts.length) return "";
  return `Seasons use this tool's national month grouping (${parts.join(", ")}) — upstream sets
    season months per AMI region, so there is no single upstream grouping to match here.`;
}

/* ================= measures ================= */
const MEASURE_COLORS=["#E69F00","#CC79A7","#7570B3","#66A61E","#A6761D"];
/* fuel conventions for the measure-pack replicas: color per fuel for the GHG
   and utility-bill stacks; hatch per fuel for the fuel x end-use stack (where
   color is the end use). Electricity is solid. */
/* Fuel order within an end-use group, bottom-up, and the hatch per fuel —
   both verbatim from plot_energy_by_enduse_and_fuel_type's pattern_shape_map
   (electricity solid, natural gas "/", district cooling "x", district heating
   ".", fuel oil "+", propane "-"). */
const FUEL_ORDER=["electricity","natural_gas","district_cooling",
  "district_heating","fuel_oil","propane"];
const FUEL_COLORS={electricity:"#0072B2",natural_gas:"#E69F00",fuel_oil:"#8C510A",
  propane:"#CC79A7",district_heating:"#D55E00",district_cooling:"#56B4E9"};
const FUEL_PATTERNS={natural_gas:"diag",district_cooling:"xdiag",
  district_heating:"dot",fuel_oil:"plus",propane:"horiz"};
/* Upstream draws the hatch over the solid fill in 50% white on dark colors and
   50% #444 on light ones, so each pattern is defined in both inks and the
   segment picks by luminance.
   ONE definition of each hatch, shared by the plot (which needs DOM nodes) and
   by the legend swatch (which needs markup). Keeping two copies is how the
   legend texture drifted from the plot texture before. */
const HATCH_SHAPES={
  diag:  {tag:"path", ink:"stroke",
          a:{d:"M-1,1 l2,-2 M0,7 l7,-7 M6,8 l2,-2","stroke-width":1.2,fill:"none"}},
  xdiag: {tag:"path", ink:"stroke",
          a:{d:"M-1,1 l2,-2 M0,7 l7,-7 M6,8 l2,-2 M-1,6 l2,2 M0,0 l7,7 M6,-1 l2,2",
             "stroke-width":1,fill:"none"}},
  dot:   {tag:"circle", ink:"fill", a:{cx:3.5,cy:3.5,r:1.2}},
  plus:  {tag:"path", ink:"stroke", a:{d:"M0,3.5 h7 M3.5,0 v7","stroke-width":1,fill:"none"}},
  horiz: {tag:"line", ink:"stroke", a:{x1:0,y1:3.5,x2:7,y2:3.5,"stroke-width":1.2}},
};
const HATCH_INK={d:"rgba(255,255,255,.55)", l:"rgba(68,68,68,.55)"};
const HATCH_PITCH=7;
const hatchMarkup=(k,ink)=>{
  const s=HATCH_SHAPES[k]; if(!s) return "";
  const a={...s.a,[s.ink]:ink};
  return `<${s.tag} ${Object.entries(a).map(([n,v])=>`${n}="${v}"`).join(" ")}/>`;
};
function fuelPatternDefs(svg){
  const defs=el("defs");
  Object.keys(HATCH_SHAPES).forEach(k=>{
    const s=HATCH_SHAPES[k];
    Object.entries(HATCH_INK).forEach(([tone,ink])=>{
      const p=el("pattern",{id:`pat-${k}-${tone}`,patternUnits:"userSpaceOnUse",
        width:HATCH_PITCH,height:HATCH_PITCH});
      p.appendChild(el(s.tag,{...s.a,[s.ink]:ink}));
      defs.appendChild(p);
    });
  });
  svg.appendChild(defs);
}
const fuelLegend=keys=>`<div class="legend">${keys.map(f=>
  swatch(FUEL_COLORS[f],f.replace(/_/g," "))).join("")}</div>`;
/* The split "color = end use" + "hatch = fuel" pair of keys is gone: the
   combined key below shows each (end use, fuel) with its real fill AND its real
   hatch, which is how the upstream figure keys itself. */
/* End-use stack order for the fuel x end-use figure, BOTTOM-UP, verbatim from
   that figure's cat_order — it differs from ENDUSE_STACK_ORDER (which the
   timeseries and AMI stacks use), so the two are kept separate rather than
   reversing one into the other. */
const FE_ENDUSE_ORDER=["interior_equipment","fans","cooling","interior_lighting",
  "heating","water_systems","exterior_lighting","refrigeration","pumps",
  "heat_recovery","heat_rejection","exterior_equipment"];
/* Upstream legend label format: "End Use, Fuel Type", both title-cased. */
const titleCase=s=>String(s).replace(/_/g," ").replace(/\b\w/g,c=>c.toUpperCase());
const feLabel=(eu,f)=>`${titleCase(eu)}, ${titleCase(f)}`;

/* ---------- combined end-use x fuel legend ----------
   One entry per (end use, fuel) actually present, drawn with the real fill
   colour AND the real hatch — the upstream legend, where the two encodings are
   shown together instead of split into a colour key and a texture key.
   Order is taken from the drawn segments and reversed, so the legend reads
   top-down in the order the segments stack top-down: it cannot drift out of
   step with the plot, because it IS the plot's order. */
function feComboItems(segs){
  const seen=new Set(), out=[];
  segs.slice().reverse().forEach(s=>{
    if(!s.eu||seen.has(s.name)) return;
    seen.add(s.name);
    out.push({eu:s.eu, fuel:s.fuel, label:s.name, color:s.color, pattern:s.pattern});
  });
  return out;
}
const YIQ=c=>{ if(!c||c[0]!=="#") return 120;
  const n=parseInt(c.slice(1),16); return .299*(n>>16&255)+.587*(n>>8&255)+.114*(n&255); };
/* A legend chip is its own tiny <svg>, which needs two things the chart SVGs do
   not:
   1. An explicit pixel size in an INLINE style. The stylesheet's
      `svg{width:100%;height:auto}` rule is written for charts; applied to a
      15x11 chip with a 15:11 intrinsic ratio it stretched the chip's box to the
      rail width and ~150px tall, stranding the colored rect in the top-left
      corner. That is the "whacky legend" this key kept regressing to.
   2. Its own <defs>. `url(#pat-diag-d)` resolved into whichever chart happened
      to be in the DOM first, so the chip's texture depended on render order and
      vanished from a copied or fullscreen legend.
   The def id is keyed by pattern and ink only, so every copy of a given chip
   is byte-identical: duplicate ids across the rail and the fullscreen overlay
   resolve to the same texture instead of to whichever rendered first. */
const SW_W=15, SW_H=11;
function hatchChip(color, pattern){
  const tone=YIQ(color)<128?"d":"l";
  const pid=`swp-${pattern}-${tone}`, has=pattern&&HATCH_SHAPES[pattern];
  return `<svg viewBox="0 0 ${SW_W} ${SW_H}" width="${SW_W}" height="${SW_H}"
      style="width:${SW_W}px;height:${SW_H}px;flex:none;display:inline-block;
        overflow:hidden;vertical-align:-1px">`
    + (has?`<defs><pattern id="${pid}" patternUnits="userSpaceOnUse"
        width="${HATCH_PITCH}" height="${HATCH_PITCH}">${
        hatchMarkup(pattern,HATCH_INK[tone])}</pattern></defs>`:"")
    + `<rect width="${SW_W}" height="${SW_H}" fill="${color}"/>`
    + (has?`<rect width="${SW_W}" height="${SW_H}" fill="url(#${pid})"/>`:"")
    + `<rect x="0.5" y="0.5" width="${SW_W-1}" height="${SW_H-1}" fill="none"
        stroke="rgba(0,0,0,.28)"/></svg>`;
}
function feComboLegend(items){
  /* Each entry toggles its OWN (end use, fuel) series. Keyed `data-fe` rather
     than `data-eu` so the end-use legends elsewhere, which are wired on
     `data-eu`, cannot pick these up and hide a whole end use instead. */
  const hid=feHidden();
  return `<div class="legend fe-key">${items.map(i=>{
    const k=feKey(i.eu,i.fuel);
    return `<span class="key" data-fe="${k}" role="button"
      aria-pressed="${!hid.has(k)}" title="click to hide or show this series"
      >${hatchChip(i.color,i.pattern)}<span>${i.label}</span></span>`;}).join("")}
    ${hid.size?`<span class="key" data-fe="__all__" role="button"
      aria-pressed="true" style="font-weight:600">show all</span>`:""}
  </div>`;
}
// Export legend: same order, same labels, and the same real hatch — `chip`
// tells the shared renderers to draw the fuel texture rather than a stand-in.
const feComboExport=items=>items
  .filter(i=>feVisible(i.eu,i.fuel))
  .map(i=>({color:i.color,label:i.label,pattern:i.pattern,hatch:!!i.pattern,chip:true}));
/* Population basis for the single-measure emissions and bill families. Two
   rows became one row plus this control. */
const MEAS_POPS=[["app","Applicable buildings only"],
                 ["stock","Whole stock, re-based (stock + measure − applicable baseline)"]];
const popLabel=s=>(MEAS_POPS.find(p=>p[0]===s)||MEAS_POPS[0])[1];
const GHG_PANELS=[["egrid","eGRID 2021"],["lrmer_high","LRMER High RE Cost 15"],
                  ["lrmer_low","LRMER Low RE Cost 15"]];
const BILL_PANELS=[["elec_max","With max electricity rate"],
                   ["elec_mean","With mean electricity rate"],
                   ["elec_min","With min electricity rate"]];
/* Measure frames may now carry rows for MORE THAN ONE release: the same
   assessment can run the measure queries against an older release for the
   upgrades it shares. Every existing view is single-release by construction, so
   they see the primary run's rows only and are unaffected; the release
   comparison reads the unfiltered frames. An assessment produced before the
   cross-release leg has no `run` column and passes straight through. */
const MEAS_ALL = D.measures;
const onlyPrimaryRun = rows => Array.isArray(rows)
  ? (rows.length && rows[0].run!==undefined ? rows.filter(r=>r.run===PRIMARY) : rows)
  : rows;
const MEAS = MEAS_ALL ? Object.assign({}, MEAS_ALL, {
  summary:       onlyPrimaryRun(MEAS_ALL.summary),
  endusePairs:   onlyPrimaryRun(MEAS_ALL.endusePairs),
  enduseSavings: onlyPrimaryRun(MEAS_ALL.enduseSavings),
  dist:          onlyPrimaryRun(MEAS_ALL.dist),
  scenarios:     onlyPrimaryRun(MEAS_ALL.scenarios),
  masks:         onlyPrimaryRun(MEAS_ALL.masks),
  categories:    onlyPrimaryRun(MEAS_ALL.categories),
}) : MEAS_ALL;
/* Which releases actually carry measure rows, in display order. A FUNCTION, not
   a const: as a const it was evaluated once at load from the unfiltered list, so
   the header "compare" checkbox could never reach the cross-release section
   however applyRunToggle() was called. RUNS is already in display order. */
const measRuns = () => (MEAS_ALL && Array.isArray(MEAS_ALL.summary)
    && MEAS_ALL.summary.length && MEAS_ALL.summary[0].run!==undefined)
  ? RUNS.map(r=>r.key).filter(k=>MEAS_ALL.summary.some(x=>x.run===k))
  : [];
const hasMeasRunCmp = () => measRuns().length > 1;
const MEAS_LIST = MEAS ? MEAS.summary.map((r,i)=>({
  up:String(r.upgrade), name:r.upgrade_name, color:MEASURE_COLORS[i%MEASURE_COLORS.length],
  short:`${r.upgrade} · ${String(r.upgrade_name).slice(0,26)}`})) : [];
const measColor = up => (MEAS_LIST.find(x=>x.up===String(up))||{}).color||"#888";
const measShort = up => (MEAS_LIST.find(x=>x.up===String(up))||{}).short||String(up);

/* ---------- population basis for the multi-measure comparison ----------
   Applicability is membership of an upgrade partition, so one bit per measure
   describes which measures touch a building. measures_masks.csv carries every
   scenario aggregated by that bitmask, which makes all four bases exact for
   ANY selected subset with no further queries. A measure never changes a
   building outside its own applicable set, so on any population its bar is
   its own rows where it applies plus baseline rows where it does not.
   Without the mask leg (too many measures, or an older assessment) only the
   two bases derivable from the pair rows are offered. */
const MASKS = (MEAS && MEAS.masks) || [];
const HAS_MASKS = MASKS.length > 0;
const BIT_ORDER = HAS_MASKS ? String(MASKS[0].bit_order).split(",") : [];
const MASK_KEYS = HAS_MASKS ? Object.keys(MASKS[0]).filter(k=>
  k!=="scenario"&&k!=="mask"&&k!=="bit_order") : [];
const MEAS_BASES=[
  ["stock","Entire stock","every bar covers the whole stock; a measure changes only the buildings it applies to and leaves the rest at baseline"],
  ["own","Each measure's own applicability","each measure against the baseline of its OWN applicable buildings — the populations differ between measures, so bars are paired and only each pair is like-for-like"],
  ["union","Union of the selected","buildings applicable to at least one selected measure"],
  ["inter","Intersection of the selected","buildings applicable to EVERY selected measure — the only population on which the measures are strictly comparable"]];
const availableBases = () => HAS_MASKS ? MEAS_BASES : MEAS_BASES.filter(b=>b[0]==="stock"||b[0]==="own");
const measBit = up => { const i=BIT_ORDER.indexOf(String(up)); return i<0?0:(1<<i); };

/* mask predicate for a basis over the selected measures */
function basisPred(basis, sel){
  const S=sel.reduce((t,mm)=>t|measBit(mm.up),0);
  if(basis==="union") return u=>(u&S)!==0;
  if(basis==="inter")  return u=>(u&S)===S;
  return ()=>true;
}
/* aggregates for one scenario ("baseline" or a measure id) over a population */
function maskAgg(scenario, pred){
  const bit = scenario==="baseline" ? 0 : measBit(scenario);
  const out={}; MASK_KEYS.forEach(k=>out[k]=0);
  MASKS.forEach(r=>{
    if(!pred(r.mask)) return;
    const applies = bit && (r.mask & bit);
    const want = applies ? String(r.scenario)===String(scenario)
                         : String(r.scenario)==="baseline";
    if(!want) return;
    MASK_KEYS.forEach(k=>{ const v=r[k]; if(v!==null&&v!==undefined&&!isNaN(v)) out[k]+=+v; });
  });
  return out;
}
/* fallback when there is no mask leg: the pair + whole-stock rows carry the
   two bases exactly (own = applicable-only; stock = whole + measure - own) */
function scenRow(up, scen){
  return (MEAS.scenarios||[]).find(r=>
    scen==="stock_baseline" ? r.scenario==="stock_baseline"
      : String(r.upgrade)===String(up)&&r.scenario===scen) || {};
}
function pairAgg(up, basis){
  const S=scenRow(null,"stock_baseline"), B=scenRow(up,"baseline"), M=scenRow(up,"measure");
  const keys=Object.keys(M).filter(k=>typeof M[k]==="number");
  const out={};
  keys.forEach(k=>{ const b=+B[k]||0, m=+M[k]||0;
    out[k]= basis==="own" ? m : (+S[k]||0)+m-b; });
  return out;
}
function baseAgg(up, basis){
  if(basis==="own") { const B=scenRow(up,"baseline"), o={};
    Object.keys(B).forEach(k=>{ if(typeof B[k]==="number") o[k]=+B[k]; }); return o; }
  const S=scenRow(null,"stock_baseline"), o={};
  Object.keys(S).forEach(k=>{ if(typeof S[k]==="number") o[k]=+S[k]; });
  return o;
}

/* The bars of a multi-measure comparison, in upstream Scenario Comparison
   order: Baseline first, then one bar per measure. On the "own" basis the
   populations differ per measure, so each measure carries its own baseline
   bar immediately to its left and the pair is labeled as such. */
/* The population a basis actually selects. Stated on every figure: a basis is
   only meaningful with its denominator, and an intersection can easily be
   empty. Returns null when there is no mask leg to count from. */
function basisPopulation(sel, basis){
  if(!HAS_MASKS) return null;
  const pred = basis==="own" ? (u=>u!==null) : basisPred(basis, sel);
  let w=0, n=0, sqft=0;
  MASKS.forEach(r=>{
    if(String(r.scenario)!=="baseline") return;
    if(basis!=="own"&&!pred(r.mask)) return;
    w+=+r.w||0; n+=+r.n||0; sqft+=+r.sqft||0;
  });
  let sw=0, ssq=0;
  MASKS.forEach(r=>{ if(String(r.scenario)==="baseline"){ sw+=+r.w||0; ssq+=+r.sqft||0; } });
  return {w, n, sqft, pctW: sw?w/sw*100:0, pctSqft: ssq?sqft/ssq*100:0, stockW: sw};
}
function populationBadge(pop, basis){
  if(!pop) return "";
  if(basis==="own") return `<span class="badge">population differs per measure</span>`;
  if(!pop.w) return `<span class="badge" style="color:var(--bad)">no buildings</span>`;
  const thin = pop.n<100 || pop.pctW<1;
  return `<span class="badge"${thin?' style="color:var(--bad)"':''}>`+
    `${fmt(pop.w/1e3,0)}k weighted buildings (${fmt(pop.pctW,1)}% of stock) · `+
    `${fmt(pop.n,0)} models · ${fmt(pop.sqft/1e9,2)}B ft² (${fmt(pop.pctSqft,1)}%)`+
    `${thin?" — thin population":""}</span>`;
}
/* ---------- by-category Scenario Comparison figures ----------
   Upstream draws 16 of these (4 metrics x {none, census division, building
   type, vintage}) as grouped bars over the whole stock, colored by a two-
   endpoint blue ramp. The ramp is reproduced exactly, int() truncation
   included, so a chart lifted from either place matches. */
const CAT_METRICS=[["m|sqft","Floor area","Mft²",1e-6],
  ["m|site_energy","Annual site energy","TBtu",1],
  ["m|electricity","Annual electricity","TBtu",1],
  ["m|natural_gas","Annual natural gas","TBtu",1]];
const CAT_GROUPS=[["none","Whole stock (no breakdown)"],["building_type","Building type"],
  ["census_division","Census division"],["vintage","Vintage"]];
function scenarioPalette(n){
  const a=[0x00,0x72,0xB2], b=[0x56,0xB4,0xE9];
  if(n<=1) return ["#0072b2"];
  return Array.from({length:n},(_,i)=>{
    const t=i/(n-1);
    return "#"+[0,1,2].map(k=>
      Math.trunc(a[k]+t*(b[k]-a[k])).toString(16).padStart(2,"0")).join("");
  });
}
/* {category: {scenarioKey: value}} for one metric, honoring the basis */
function catAgg(dim, basis, sel, key, scale){
  const rows=(MEAS.categories||[]).filter(r=>r.dimension===(dim==="none"?"building_type":dim));
  if(!rows.length) return null;
  const pred=basis==="own"?null:basisPred(basis, sel);
  const out={};
  const put=(cat,scen,v)=>{ (out[cat]=out[cat]||{}); out[cat][scen]=(out[cat][scen]||0)+v; };
  const cats=[...new Set(rows.map(r=>String(r.category)))];
  cats.forEach(cat=>{
    const crows=rows.filter(r=>String(r.category)===cat);
    const label=dim==="none"?"Whole stock":cat;
    const ok=mk=>pred?pred(mk):true;
    // baseline over the population
    let base=0;
    crows.forEach(r=>{ if(String(r.scenario)==="baseline"&&ok(r.mask))
      base+=(+r[key]||0)*scale; });
    put(label,"baseline",base);
    sel.forEach(mm=>{
      const bit=measBit(mm.up);
      const own=mk=>(mk&bit)!==0;
      let v=0;
      crows.forEach(r=>{
        const inP=basis==="own"?own(r.mask):ok(r.mask);
        if(!inP) return;
        const applies=(r.mask&bit)!==0;
        const want=applies?String(r.scenario)===mm.up:String(r.scenario)==="baseline";
        if(want) v+=(+r[key]||0)*scale;
      });
      put(label,mm.up,v);
    });
    if(basis==="own"){
      // each measure's own population needs its own baseline bar too
      sel.forEach(mm=>{
        const bit=measBit(mm.up);
        let b2=0;
        crows.forEach(r=>{ if(String(r.scenario)==="baseline"&&(r.mask&bit)) b2+=(+r[key]||0)*scale; });
        put(label,`base_${mm.up}`,b2);
      });
    }
  });
  return out;
}
function basisBars(sel, basis){
  const pred=basisPred(basis, sel);
  const bars=[];
  if(basis==="own"){
    sel.forEach(mm=>{
      const p=u=>(u&measBit(mm.up))!==0;
      const base=HAS_MASKS?maskAgg("baseline",p):baseAgg(mm.up,"own");
      const meas=HAS_MASKS?maskAgg(mm.up,p):pairAgg(mm.up,"own");
      bars.push({label:`Baseline · ${mm.up}`, agg:base, color:"#8B949B", isBase:true});
      bars.push({label:mm.short, agg:meas, color:mm.color, ref:base});
    });
    return bars;
  }
  const base=HAS_MASKS?maskAgg("baseline",pred):baseAgg(null,"stock");
  bars.push({label:"Baseline", agg:base, color:"#8B949B", isBase:true});
  sel.forEach(mm=>bars.push({label:mm.short,
    agg:HAS_MASKS?maskAgg(mm.up,pred):pairAgg(mm.up,"stock"),
    color:mm.color, ref:base}));
  return bars;
}

/* signed stacked bar: one bar per entry, segments stack up (+) and down (−).
   Segments may carry `pattern` (a fuel hatch id — see fuelPatternDefs) drawn
   over the end-use color, like the measure-pack fuel x end-use figure. With
   opts.segLabels, segments tall enough get their value printed; b.topLabel is
   drawn above the bar (totals, and (−x%) vs the baseline bar). */
function stackedBarChart(host, bars, opts={}){
  const padR=12;
  const padT=bars.some(b=>b.topLabel)?28:12;
  if(!bars.length){ host.innerHTML='<p class="note">No records for this selection.</p>'; return; }
  /* `targetWidth` lays the bars out to occupy the column the caller knows it
     has, instead of a fixed intrinsic size that max-width then pinned. A 2-bar
     chart was 326 viewBox units wide, so in a 440px column it sat in the left
     third with the rest white; scaling the whole SVG up instead would have
     inflated the text with it. The target is passed explicitly rather than
     measured from the host, so the layout does not depend on the element
     having been laid out yet. */
  const fillW = opts.targetWidth || 0;
  /* Slot layout, matching the categorical spacing of the reference figures:
     the plot area is divided into equal slots and each bar is CENTRED in its
     slot, so the margin before the first bar equals the margin after the last
     and every gap is identical. The previous version started the first bar
     exactly at padL and added a stray +30 on the right, which is what left the
     bars shifted left with lopsided white space and a double-width gap in the
     middle. On the paired ("own applicability") basis the slots are grouped
     two at a time so a reader cannot pair a measure with the wrong baseline. */
  const n=bars.length;
  const perGroup=opts.pairGaps?2:1;
  const nGroups=Math.ceil(n/perGroup);
  /* Bar width is held CONSTANT and the plot grows with the number of bars — the
     opposite of stretching a fixed plot until the bars fatten to fill it. Two
     bars used to come out nearly three times the width of six, so the same
     measure looked completely different depending on how many others happened
     to be selected, and a 2-bar figure read as bulky. Now a bar is the same
     width everywhere and only the figure gets wider. */
  /* Upstream sets the bar to exactly HALF its category slot (plotly
     `width=0.5` on a categorical axis) and grows the figure ~15% per extra
     scenario, which lands a bar at 46-55px whatever the scenario count. These
     numbers are chosen to match that: gutter == bar width, so bar = 50% of slot,
     and 46-58px puts us inside the same range. */
  /* Set BELOW the 46-55px target, because a row of figures is magnified after
     layout to use up its slack (fillRows) and that magnifies the bars with
     everything else. 44 x the 1.35 cap lands at 59px; 38 x 1.35 at 51px. */
  const BAR_W   = opts.wide ? 44 : 38;
  const INNER_W = 5;                       // between the two bars of one pair
  const GUTTER  = BAR_W;                   // => bar is half of its slot
  const wantBarW = perGroup*BAR_W + (perGroup-1)*INNER_W;
  /* The bottom pad, the height and the y scale are all settled BEFORE the
     horizontal maths, because padL now depends on the tick labels and the tick
     labels depend on the scale. tickPlan's pad is a function of the label
     lengths and the (constant) 45 degree angle only, so it does not need the
     slot width and there is no circular dependency. */
  const planEarly = tickPlan(bars.map(b=>b.label), 1);
  const padB0 = planEarly.pad;
  const H0=(opts.height||290) + Math.max(0, padB0-70);
  const plotH0=H0-padT-padB0;
  const rawMax0=Math.max(1e-9,opts.yMax||0,...bars.map(b=>b.segs.filter(s2=>s2.value>0)
    .reduce((t,s2)=>t+s2.value,0)));
  const negMin0=Math.min(0,...bars.map(b=>b.segs.filter(s2=>s2.value<0)
    .reduce((t,s2)=>t+s2.value,0)));
  const room0=Math.ceil(12.5*1.115)+6+7;
  const f0 = bars.some(b=>b.topLabel) ? Math.min(0.4, room0/Math.max(1,plotH0)) : 0;
  const posMax0 = f0 ? (rawMax0-f0*negMin0)/(1-f0) : rawMax0;
  const vdec0 = Math.abs(posMax0-negMin0)<10 ? 1 : 0;
  const padL = axisPadL([0,1,2,3,4].map(i=>fmt(negMin0+(posMax0-negMin0)*i/4, vdec0)), true);
  const availW = fillW ? Math.max(120, fillW-padL-padR)
                       : (opts.wide?760:560);
  // grow to fit the bars, but never past the column the caller gave us
  const plotW = Math.min(availW, Math.max(130, nGroups*(wantBarW+GUTTER)));
  const groupSlot = plotW/nGroups;
  // if the column forced a clamp, the bars give way rather than overflow
  const groupBarW = Math.min(wantBarW, groupSlot*0.78);
  const innerGap = perGroup>1 ? Math.min(INNER_W, groupBarW*0.08) : 0;
  const bw = (groupBarW-innerGap*(perGroup-1))/perGroup;
  const gap = groupSlot-groupBarW;                 // for the tick-label plan
  const xs = bars.map((b,i)=>{
    const g=Math.floor(i/perGroup), j=i%perGroup;
    return padL + g*groupSlot + (groupSlot-groupBarW)/2 + j*(bw+innerGap);
  });
  const plan = planEarly, padB = padB0, H = H0;   // settled above, before padL
  const width=padL+plotW+padR;
  /* Headroom for the above-bar totals: without it a bar that reaches the top of
     the plot puts its total label on the frame and into the top gridline's tick
     value.
     A flat percentage does NOT solve this. The label is a fixed 11px with its
     baseline 6 units above the bar, so it needs a fixed ~19 units of clear
     space; 7% of a short panel is less than the label's own height, which is
     why the shared-scale GHG panels still had their totals grazing the frame.
     So solve for the axis maximum that leaves exactly that much room:
       want  y(rawMax) - padT >= room,  where y(v)=padT+(posMax-v)/(posMax-negMin)*plotH
       =>    posMax = (rawMax - f*negMin)/(1-f),   f = room/plotH
     Upstream reaches the same place by letting the total-label trace take part
     in the autorange. rawMax includes opts.yMax, and f depends only on the
     panel geometry, so panels sharing a scale stay on the same scale. */
  /* Derived from the font rather than hardcoded, so raising the label size
     cannot silently eat the buffer again. Measured: an 11px label reports
     getBBox().height 15.32 with 12.26 of that above its own baseline, i.e. an
     ascent of 1.115em. Room = ascent + the 6-unit gap above the bar + 7 of air. */
  const TOT_FONT=12.5;
  // computed before padL (see above) and reused verbatim here, so the scale the
  // tick labels were measured from is the scale actually drawn
  const plotH=plotH0, rawMax=rawMax0, negMin=negMin0, posMax=posMax0;
  const y=v=>padT+(posMax-v)/(posMax-negMin||1)*plotH;
  /* An explicit px width, not `width:100%`. Now that the figure sizes itself to
     its bar count it is often narrower than the column, and a percentage width
     would stretch it back out — magnifying every font and defeating the point.
     A definite width also lets the flex parent shrink to the figure, which is
     what keeps the legend rail beside the chart instead of stranded at the far
     right of the panel. `max-width:100%` keeps a wide figure inside its column. */
  const svg=el("svg",{viewBox:`0 0 ${width} ${H}`,
    style:`width:${width}px;max-width:100%;display:block`});
  if(bars.some(b=>b.segs.some(s=>s.pattern))) fuelPatternDefs(svg);
  const span=Math.abs(posMax-negMin);
  const vdec=span<10?1:0;
  const sdec=opts.segDec!==undefined?opts.segDec:(span<10?2:(span<300?1:0));
  // YIQ brightness, the same rule the upstream plots use to pick label ink
  const lum=c=>{ if(!c||c[0]!=="#") return 120;
    const n=parseInt(c.slice(1),16); return .299*(n>>16&255)+.587*(n>>8&255)+.114*(n&255); };
  /* An in-segment label is now 11.5px rather than 9.5px, so a segment needs to
     be taller to hold one legibly: readable numbers on fewer segments beats
     unreadable numbers on more. The 1.35x factor is the label's line box. */
  const SEG_FONT=11.5;
  const labelMin=Math.max(SEG_FONT*1.35, plotH*0.045);
  for(let i=0;i<=4;i++){
    const v=negMin+(posMax-negMin)*i/4, yy=y(v);
    svg.appendChild(el("line",{x1:padL-6,y1:yy,x2:width-padR,y2:yy,class:"gl"}));
    const t=el("text",{x:padL-10,y:yy+4,class:"ax","text-anchor":"end"});
    t.textContent=fmt(v,vdec); svg.appendChild(t);
  }
  const yl=el("text",{x:12,y:padT+plotH/2,class:"axl","text-anchor":"middle",
    transform:`rotate(-90 12 ${padT+plotH/2})`});
  yl.textContent=opts.yLabel||"TBtu"; svg.appendChild(yl);
  bars.forEach((b,i)=>{
    const x=xs[i];
    let up=0, dn=0;
    b.segs.forEach(s=>{
      if(!s.value) return;
      const yTop=s.value>0?y(up+s.value):y(dn);
      const hh=Math.abs(y(s.value>0?up:dn)-y(s.value>0?up+s.value:dn+s.value));
      const rect=el("rect",{x,y:yTop,width:bw,height:Math.max(hh,.8),
        fill:s.color,stroke:"var(--panel)","stroke-width":1});
      rect.addEventListener("mousemove",ev=>showTip(
        `<b>${b.label}</b><div class="row"><span>${s.name}</span><span>${(s.value>0?"+":"")+fmt(s.value,2)}</span></div>`+
        `<div class="row"><span>bar total</span><span>${fmt(b.segs.reduce((t,x2)=>t+x2.value,0),2)}</span></div>`,ev));
      rect.addEventListener("mouseleave",hideTip);
      svg.appendChild(rect);
      const dark=lum(s.color)<128;
      if(s.pattern) svg.appendChild(el("rect",{x,y:yTop,width:bw,height:Math.max(hh,.8),
        fill:`url(#pat-${s.pattern}-${dark?"d":"l"})`,"pointer-events":"none"}));
      if(opts.segLabels&&hh>=labelMin){
        const t=el("text",{x:x+bw/2,y:yTop+hh/2+4,"text-anchor":"middle",
          style:`font-size:${SEG_FONT}px;fill:${dark?"#fff":"#1a1a1a"};pointer-events:none`});
        t.textContent=fmt(s.value,sdec); svg.appendChild(t);
      }
      if(s.value>0) up+=s.value; else dn+=s.value;
    });
    if(b.topLabel){
      const t=el("text",{x:x+bw/2,y:y(up)-6,"text-anchor":"middle",
        style:`font-size:${TOT_FONT}px;font-weight:600;fill:var(--ink)`});
      t.textContent=b.topLabel; svg.appendChild(t);
    }
    const lx=x+bw/2+plan.dx, ly=H-padB+16;
    tickLabel(svg, lx, ly, b.label, plan);
  });
  svg.appendChild(el("line",{x1:padL-6,y1:y(0),x2:width-padR,y2:y(0),class:"zero"}));
  plotFrame(svg, padL, padT, width-padR-padL, plotH);
  host.innerHTML=""; attachChart(host, svg, opts.copy);
}

/* horizontal box-and-whisker + violin, mirroring the savings_distributions figures:
   one row per category, box = interquartile range, solid line = median,
   dashed line = mean (NOT a diamond), n appended to the row label, whiskers
   span the full (trimmed) range like spanmode='hard', mean marked with a
   diamond, n shown at the right. entries: [{label, stats, color?}] where stats
   has vmin,p05,p25,p50,p75,p95,vmax,mean,n_models. Grouped variant: each entry
   may carry `series`: [{stats,color,name}] for multi-measure rows. */
function hBoxChart(host, entries, opts={}){
  const padT=8,padB=40+(opts.note?15:0);
  if(!entries.length){ host.innerHTML='<p class="note">No records for this selection.</p>'; return; }
  /* Left pad from the longest ROW LABEL, which now carries its "(n=486)" count,
     and a small right pad since the count no longer sits out there. A fixed 170
     clipped the longer building-type names once the label grew. */
  const rowLabels=entries.map(e=>e.label
    +(e.series?"":` (n=${Number((e.stats||{}).n_models||0).toLocaleString()})`));
  const padL=Math.min(260, Math.max(120, Math.ceil(
    AX_CHAR_W*1.02*Math.max(...rowLabels.map(t=>t.length))+16)));
  const padR=18;
  const rowH=opts.rowH||(entries.some(e=>e.series&&e.series.length>1)?null:26);
  const rows=entries.map(e=>e.series?e.series.length:1);
  const perSub=18, rh=e=>e.series?e.series.length*perSub+8:26;
  const H=padT+padB+entries.reduce((t,e)=>t+rh(e),0);
  const W=opts.width||760;
  const plotW=W-padL-padR;
  /* Domain must hold everything drawn: the violin tail and the outlier dots
     reach past vmin/vmax, and a figure that draws outside its own frame is
     worse than one that is slightly wider than the data. */
  const all=entries.flatMap(e=>(e.series||[e]).flatMap(s=>{
    const kd=parseKde(s.stats.kde);
    return [s.stats.vmin,s.stats.vmax]
      .concat(kd?[kd.x0,kd.x1]:[])
      .concat(parseOutliers(s.stats.outliers));
  })).filter(v=>Number.isFinite(v));
  let lo=Math.min(0,...all), hi=Math.max(0,...all);
  if(hi===lo){ hi=lo+1; }
  const pad=(hi-lo)*0.04; lo-=pad; hi+=pad;
  const x=v=>padL+(v-lo)/(hi-lo)*plotW;
  const svg=el("svg",{viewBox:`0 0 ${W} ${H}`, style:figStyle(W)});
  for(let i=0;i<=6;i++){
    const v=lo+(hi-lo)*i/6, xx=x(v);
    svg.appendChild(el("line",{x1:xx,y1:padT,x2:xx,y2:H-padB,class:"gl"}));
    const t=el("text",{x:xx,y:H-padB+14,class:"ax","text-anchor":"middle"});
    t.textContent=fmt(v,Math.abs(hi-lo)<20?1:0); svg.appendChild(t);
  }
  svg.appendChild(el("line",{x1:x(0),y1:padT,x2:x(0),y2:H-padB,class:"zero"}));
  const xl=el("text",{x:padL+plotW/2,y:H-6-(opts.note?15:0),class:"axl","text-anchor":"middle"});
  xl.textContent=opts.xLabel||""; svg.appendChild(xl);
  if(opts.note){
    const nt=el("text",{x:padL,y:H-4,class:"ax","text-anchor":"start",
      style:"font-size:9.5px;fill:var(--ink-3)"});
    nt.textContent=opts.note; svg.appendChild(nt);
  }
  let yCur=padT;
  entries.forEach(e=>{
    const height=rh(e), yMid=yCur+height/2;
    const lab=el("text",{x:padL-8,y:yMid+4,class:"ax","text-anchor":"end"});
    // "Category (n=486)", the way upstream labels these rows
    const nOwn=e.series?null:(e.stats||{}).n_models;
    lab.textContent=e.label+(nOwn?` (n=${Number(nOwn).toLocaleString()})`:"");
    svg.appendChild(lab);
    const series=e.series||[{stats:e.stats,color:e.color||"#4C78B0"}];
    series.forEach((s,j)=>{
      const st=s.stats, cy=e.series?yCur+6+j*perSub+perSub/2:yMid, bh=e.series?11:14;
      const g=el("g");
      /* Upstream's savings-distribution style: a KDE violin behind a box, the
         median solid and the MEAN DASHED inside it, whiskers across the range,
         and 1.5-IQR outliers as dots above. The violin is drawn only when the
         pipeline stored a density computed from the raw per-model values —
         seven quantiles cannot be turned back into a distribution shape, so
         without it we show the box alone rather than invent an outline. */
      const kde=parseKde(st.kde);
      if(kde){
        const halfH=(e.series?perSub*0.46:rh(e)*0.40);
        const n=kde.d.length;
        const px=i=>x(kde.x0+(kde.x1-kde.x0)*i/(n-1));
        let top="", bot="";
        for(let i=0;i<n;i++){ top+=`${i?"L":"M"}${px(i).toFixed(1)},${(cy-kde.d[i]*halfH).toFixed(1)}`; }
        for(let i=n-1;i>=0;i--){ bot+=`L${px(i).toFixed(1)},${(cy+kde.d[i]*halfH).toFixed(1)}`; }
        g.appendChild(el("path",{d:top+bot+"Z", fill:"var(--grid)",
          stroke:"var(--ink-2)","stroke-width":0.8,"pointer-events":"none"}));
      }
      g.appendChild(el("line",{x1:x(st.vmin),y1:cy,x2:x(st.vmax),y2:cy,
        stroke:"var(--ink-2)","stroke-width":1,opacity:.85}));
      [st.vmin,st.vmax].forEach(v=>g.appendChild(el("line",
        {x1:x(v),y1:cy-bh/2.6,x2:x(v),y2:cy+bh/2.6,stroke:"var(--ink-2)","stroke-width":1,opacity:.85})));
      g.appendChild(el("rect",{x:x(Math.min(st.p25,st.p75)),y:cy-bh/2,
        width:Math.max(Math.abs(x(st.p75)-x(st.p25)),1),height:bh,
        fill:s.color,stroke:"var(--ink-2)","stroke-width":0.9}));
      // median solid, mean dashed — the pair upstream draws inside the box
      g.appendChild(el("line",{x1:x(st.p50),y1:cy-bh/2,x2:x(st.p50),y2:cy+bh/2,
        stroke:"#111","stroke-width":1.6}));
      const mx=x(st.mean);
      g.appendChild(el("line",{x1:mx,y1:cy-bh/2,x2:mx,y2:cy+bh/2,
        stroke:"#111","stroke-width":1.4,"stroke-dasharray":"2.5 2"}));
      parseOutliers(st.outliers).forEach(v=>g.appendChild(el("circle",
        {cx:x(v),cy:cy-(e.series?perSub*0.52:rh(e)*0.44),r:1.15,
         fill:"var(--ink-2)","pointer-events":"none"})));
      g.addEventListener("mousemove",ev=>showTip(
        `<b>${e.label}${s.name?` · ${s.name}`:""}</b>`+
        `<div class="row"><span>min–max</span><span>${fmt(st.vmin)} – ${fmt(st.vmax)}</span></div>`+
        `<div class="row"><span>p25 / median / p75</span><span>${fmt(st.p25)} / ${fmt(st.p50)} / ${fmt(st.p75)}</span></div>`+
        `<div class="row"><span>mean (dashed)</span><span>${fmt(st.mean)}</span></div>`+
        `<div class="row"><span>models (nonzero)</span><span>${fmt(st.n_models,0)}</span></div>`+
        (st.share_negative_pct!==undefined?`<div class="row"><span>share negative</span><span>${fmt(st.share_negative_pct)}%</span></div>`:"")+
        (st.share_trimmed_pct?`<div class="row"><span>share beyond ±150%</span><span>${fmt(st.share_trimmed_pct,2)}%</span></div>`:""),ev));
      g.addEventListener("mouseleave",hideTip);
      svg.appendChild(g);
    });
    yCur+=height;
  });
  plotFrame(svg, padL, padT, plotW, H-padT-padB);
  host.innerHTML=""; attachChart(host, svg, opts.copy);
}

function enduseLegendItemsExport(){
  return D.enduseOrder.slice().reverse().map(k=>({color:D.enduseColors[k],label:k.replace(/_/g," ")}));
}

/* mode controls shared by both measure tabs: single-measure dropdown for the
   deep QAQC review, multi-select for comparing several at once */
function measControls(){
  const single=state.measView==="single";
  return `<div class="tabs" role="group" aria-label="Measure view">
      <button class="tab" data-mview="single" aria-selected="${single}">Single measure</button>
      <button class="tab" data-mview="multi" aria-selected="${!single}">Compare measures</button>
    </div>
    ${single
      ? `<select id="measSel">${MEAS_LIST.map(mm=>
          `<option value="${mm.up}" ${mm.up===state.measSel?"selected":""}>${mm.up} · ${mm.name}</option>`).join("")}</select>`
      : `<div class="mmulti" id="mmulti">
          <button class="tab" id="mmultiBtn" aria-expanded="${!!state.measMenuOpen}"
            aria-haspopup="true">Measures: ${state.measMulti.length} of ${MEAS_LIST.length} ▾</button>
          <div class="mmenu" id="mmenu" style="display:${state.measMenuOpen?"block":"none"}">
            <div class="mmenu-actions">
              <button class="btn-mini" data-mall="all">All</button>
              <button class="btn-mini" data-mall="none">None</button>
              <button class="btn-mini" data-mall="first3">First 3</button>
            </div>
            ${MEAS_LIST.map(mm=>`<label class="mmenu-item">
              <input type="checkbox" data-mcheck="${mm.up}"
                ${state.measMulti.includes(mm.up)?"checked":""}>
              <span class="sw" style="background:${mm.color}"></span>
              ${mm.up} · ${mm.name}</label>`).join("")}
          </div>
        </div>`}`;
}
function wireMeasControls(rerender){
  document.querySelectorAll("[data-mview]").forEach(b=>
    b.addEventListener("click",()=>{
      state.measView=b.dataset.mview; state.measMenuOpen=false; rerender(); syncHash(); }));
  const s=$("#measSel");
  if(s) s.addEventListener("change",e=>{ state.measSel=e.target.value; rerender(); syncHash(); });
  const btn=$("#mmultiBtn");
  if(btn) btn.addEventListener("click",()=>{
    state.measMenuOpen=!state.measMenuOpen;
    $("#mmenu").style.display=state.measMenuOpen?"block":"none";
    btn.setAttribute("aria-expanded",String(state.measMenuOpen));
  });
  // rerender keeps the menu open (state.measMenuOpen survives), so several
  // boxes can be checked in a row without reopening
  document.querySelectorAll("[data-mcheck]").forEach(c=>
    c.addEventListener("change",()=>{
      const on=[...document.querySelectorAll("[data-mcheck]")]
        .filter(x=>x.checked).map(x=>x.dataset.mcheck);
      state.measMulti=MEAS_LIST.map(m=>m.up).filter(u=>on.includes(u));
      rerender(); syncHash();
    }));
  document.querySelectorAll("[data-mall]").forEach(b=>
    b.addEventListener("click",()=>{
      const ups=MEAS_LIST.map(m=>m.up);
      state.measMulti=b.dataset.mall==="all"?ups
        :b.dataset.mall==="first3"?ups.slice(0,3):[];
      rerender(); syncHash();
    }));
  const mbt=$("#measBasisTs");
  if(mbt) mbt.addEventListener("change",e=>{
    state.measBasis=e.target.value; rerender(); syncHash(); });
  /* Clicking a measure in the legend hides its series but KEEPS the key, greyed
     out, so it can be clicked back — removing it from the selection made the
     key vanish along with the series and left no way to restore it. The
     selection itself is changed only from the Measures dropdown. */
  document.querySelectorAll("[data-mkey]").forEach(k=>
    k.addEventListener("click",()=>{
      const up=k.dataset.mkey;
      const hid=new Set(state.measHidden||[]);
      if(hid.has(up)) hid.delete(up);
      else if(state.measMulti.filter(u=>!hid.has(u)).length>1) hid.add(up);
      state.measHidden=[...hid];
      rerender(); syncHash();
    }));
  if(!window.__mmenuGuard){
    window.__mmenuGuard=true;
    document.addEventListener("click",e=>{
      if(state.measMenuOpen&&!e.target.closest("#mmulti")){
        state.measMenuOpen=false;
        const m=$("#mmenu"), b2=$("#mmultiBtn");
        if(m) m.style.display="none";
        if(b2) b2.setAttribute("aria-expanded","false");
      }
    });
  }
}
/* `measSelected` is what the charts draw: the dropdown selection minus the
   measures switched off from the legend. `measChosen` is the selection itself,
   which the legend renders in full so a hidden measure stays clickable. */
const measChosen=()=>state.measView==="single"
  ? MEAS_LIST.filter(mm=>mm.up===state.measSel)
  : MEAS_LIST.filter(mm=>state.measMulti.includes(mm.up));
const measHidden=()=>new Set(state.measHidden||[]);
const measSelected=()=>state.measView==="single"
  ? measChosen()
  : measChosen().filter(mm=>!measHidden().has(mm.up));
/* Legend keys for the measure series: every chosen measure, dimmed when off. */
function measKeyLegend(list, dashed){
  const hid=measHidden();
  return list.map(mm=>`<span class="key" data-mkey="${mm.up}" role="button"
    aria-pressed="${!hid.has(mm.up)}" title="click to hide or show this measure"
    style="cursor:pointer${hid.has(mm.up)?";opacity:.4;text-decoration:line-through":""}">
    <span style="width:14px;height:0;border-top:${dashed?"2.5px dashed":"2.5px solid"} ${
      mm.color};display:inline-block;flex:none"></span>${mm.short}</span>`).join("");
}

function measSummaryTable(list){
  let h=`<div class="scroll"><table><thead><tr><th>Measure</th><th>Applicable stock</th>
    <th>Site savings (TBtu)</th><th>Elec (TBtu)</th><th>Gas (TBtu)</th>
    <th>Avg bill savings ($/bldg·yr)</th><th>National bill savings ($M/yr)</th>
    <th>Emissions savings (MMT CO₂e)</th><th>Emissions savings %</th></tr></thead><tbody>`;
  MEAS.summary.filter(r=>list.some(mm=>mm.up===String(r.upgrade))).forEach(r=>{
    h+=`<tr><td style="text-align:left"><span class="sw" style="background:${measColor(r.upgrade)}"></span>
      ${r.upgrade} · ${r.upgrade_name}</td>
      <td>${fmt(r.pct_of_stock)}% (${fmt(r.weighted_bldgs/1e3,0)}k bldgs)</td>
      <td>${fmt(r.site_savings_tbtu)}</td><td>${fmt(r.elec_savings_tbtu)}</td>
      <td>${fmt(r.gas_savings_tbtu)}</td>
      <td>${fmt(r.bill_avg_savings_usd_per_bldg,0)}</td>
      <td>${fmt(r.bill_total_savings_musd,0)}</td>
      <td>${fmt(r.emissions_savings_co2e_mmt,2)}</td>
      <td>${pct(r.emissions_pct_savings)}</td></tr>`;
  });
  return h+`</tbody></table></div>`;
}

/* the savings_distributions matrix for one measure: four kinds (site %, site
   EUI, bill %, bill $/ft²) x a grouping dropdown (end use, fuel, building
   type, climate zone, HVAC system), matching the measure-pack folder */
const DIST_GROUPS=[["end_use","End use"],["fuel","Fuel"],["building_type","Building type"],
  ["climate_zone","Climate zone"],["hvac_system","HVAC system"]];
const DIST_KINDS=[
  ["pct_site","Site energy savings (%)","% savings","unweighted, zeros dropped, trimmed at ±150%"],
  ["eui_site","Site EUI savings (kBtu/ft²)","kBtu/ft² saved","unweighted, zeros dropped"],
  ["pct_bill","Utility bill savings (%)","% bill savings","mean elec rate, zeros dropped, trimmed at ±150%"],
  ["usd_bill","Utility bill savings ($/ft²)","$/ft² saved","mean elec rate, zeros dropped"]];
/* Categories per figure are capped so a 116-way HVAC split stays readable; the
   cap is stated on the chart rather than silently truncating. Comparing N
   measures multiplies the rows by N, so the fine-grained groupings (end use,
   HVAC system) are single-measure only — at 20 categories x 3 measures the
   boxes are too thin to read and the figure stops carrying information. */
const DIST_CAT_CAP=22;
const DIST_CAT_CAP_MULTI=10;
const DIST_GROUPS_MULTI=["fuel","building_type","climate_zone"];
const distGroupsFor=multi=>multi
  ? DIST_GROUPS.filter(g=>DIST_GROUPS_MULTI.includes(g[0])) : DIST_GROUPS;
function measDistPanels(list){
  const multi=list.length>1;
  const groups=distGroupsFor(multi);
  if(!groups.some(g=>g[0]===state.measDistGroup)) state.measDistGroup=groups[0][0];
  const gLab=(groups.find(g=>g[0]===state.measDistGroup)||groups[0])[1].toLowerCase();
  return `<div class="panel"><div class="head"><h2 style="margin-top:0">Per-building savings
      distributions by ${gLab} — %, kBtu/ft², $/ft²
      <span class="badge">${multi?`${list.length} measures`:`${list[0].up} · ${list[0].name}`}</span>
      <span class="badge">each measure's own applicable buildings</span>
      <span class="badge">zeros dropped; % trimmed at ±150%</span></h2>
      <span class="spacer"></span>
      <label class="note" style="margin:0">group by
      <select id="distGroup">${groups.map(([g,lab])=>
        `<option value="${g}" ${g===state.measDistGroup?"selected":""}>${lab}</option>`).join("")}
      </select></label></div>
    <p class="note">Positive = savings. <b>Box</b> is the interquartile range (p25–p75),
    <b>solid line</b> the median, <b>dashed line</b> the mean, <b>whiskers</b> the full trimmed
    range, <b>dots</b> points beyond 1.5×IQR, and the shaded outline is a kernel density.
    All of these are <b>unweighted — one row per model</b>, not per building represented, unlike
    the weighted boxes on the Distributions tab. n counts models with a nonzero value — the
    conventions of the savings_distributions figures in the measure postprocessing pack. Left tails past zero are buildings the measure hurts — the QAQC
    signal. Energy and utility-bill versions side by side; bill savings by end use are not
    tracked upstream, so that combination is empty.${multi?` Each category carries one box per
    selected measure. These are per-building distributions over each measure's OWN applicable
    buildings, so they do not follow the population basis above. The end-use and HVAC-system
    splits are single-measure only: at twenty-odd categories times ${list.length} measures the
    boxes are too thin to read, so open one measure at a time for those.`:""}</p>
    ${multi?`<div class="legend">${measKeyLegend(measChosen())}</div>`:""}
    <div class="grid2">${DIST_KINDS.map(([kind,kLab,,note])=>
      `<div><h3>${kLab} — by ${gLab} <span class="badge">${note}</span></h3>
       <div id="md-${kind}"></div></div>`).join("")}
    </div></div>`;
}
function renderMeasDist(list){
  const g=state.measDistGroup;
  const multi=list.length>1;
  const order=(D.ordered&&D.ordered.building_type)||[];
  DIST_KINDS.forEach(([kind,kLab,xLab])=>{
    const rows=MEAS.dist.filter(r=>r.kind===kind&&r.group===g
      &&list.some(mm=>mm.up===String(r.upgrade)));
    const cats=[...new Set(rows.map(r=>r.category))];
    // rank by the biggest median effect across the selection, so a capped
    // figure keeps the categories that matter
    const rank={};
    cats.forEach(c=>rank[c]=Math.max(...rows.filter(r=>r.category===c)
      .map(r=>Math.abs(r.p50||0))));
    cats.sort((a,b)=>{
      if(g==="building_type"){
        const ia=order.indexOf(a), ib=order.indexOf(b);
        if(ia!==-1||ib!==-1) return (ia===-1?99:ia)-(ib===-1?99:ib);
      }
      if(g==="end_use"||g==="fuel") return a.localeCompare(b);
      return rank[b]-rank[a];
    });
    const cap=multi?DIST_CAT_CAP_MULTI:DIST_CAT_CAP;
    const shown=cats.slice(0,cap), dropped=cats.length-shown.length;
    const entries=shown.map(cat=>{
      const per=list.map(mm=>{
        const r=rows.find(x=>String(x.upgrade)===mm.up&&x.category===cat);
        return r?{stats:r,color:mm.color,name:mm.short}:null;
      }).filter(Boolean);
      if(!per.length) return null;
      return multi ? {label:cat, series:per}
                   : {label:cat, stats:per[0].stats, color:per[0].color};
    }).filter(Boolean);
    hBoxChart($(`#md-${kind}`), entries,
      {xLabel:xLab, width:640,
       note:dropped>0?`showing the ${shown.length} categories with the largest median effect; ${dropped} more not shown`:"",
       copy:{title:`${multi?`${list.length} measures`:`${list[0].up} ${list[0].name}`} — ${kLab} by ${g.replace(/_/g," ")}`,
             legend:multi?list.map(mm=>({color:mm.color,label:mm.short})):[]}});
  });
  const dg=$("#distGroup");
  if(dg) dg.addEventListener("change",e=>{
    state.measDistGroup=e.target.value; renderMeasuresAnnual(); syncHash(); });
}

/* ---------- cross-release measure comparison ----------
   Same measure, same applicable-buildings definition, run against each release
   that carries it. A release may not have every measure — not written yet,
   renamed, or dropped — so the ones it lacks are named rather than shown as
   zeros, which would read as "this measure saves nothing here". */
function measReleasePanel(){
  const mRuns=measRuns();
  if(mRuns.length<2) return "";
  const ups=[...new Set(MEAS_ALL.summary.map(r=>String(r.upgrade)))];
  const get=(up,run)=>MEAS_ALL.summary.find(r=>String(r.upgrade)===up&&r.run===run);
  const METRICS=[["site_savings_tbtu","Site energy savings","TBtu",1],
                 ["elec_savings_tbtu","Electricity savings","TBtu",1],
                 ["gas_savings_tbtu","Gas savings","TBtu",1],
                 ["pct_of_stock","Applicable share of stock","%",1],
                 ["emissions_savings_co2e_mmt","Emissions savings","MMT CO₂e",2],
                 // included precisely so the gap is visible: 2024 R2 names its
                 // utility-bill columns differently, so this reads "not published"
                 // there rather than being quietly left out of the comparison
                 ["bill_total_savings_musd","Bill savings","$M/yr",0]];
  const absent=[];
  ups.forEach(up=>mRuns.forEach(k=>{ if(!get(up,k)) absent.push(`${up} not in ${runShort(k)}`); }));
  let t=`<div class="panel" id="sec-relcmp"><div class="head">
      <h2>Same measure across releases — ${mRuns.map(runShort).join(" vs ")}</h2></div>
    <p class="note">Each measure re-assessed against every release that carries it, on that
    release's own baseline and its own applicable buildings. A change here is a change in the
    measure's modeled effect, not in the stock it was applied to — the applicable share is
    listed so a shift in coverage can be separated from a shift in savings.
    ${absent.length?`<b>Measures not present in every release:</b> ${absent.join("; ")}.`:""}</p>
    <div class="scroll"><table><thead><tr><th>Measure</th><th>Metric</th>
    ${mRuns.map(k=>`<th>${runShort(k)}</th>`).join("")}
    <th>${runShort(PRIMARY)} − ${runShort(mRuns.find(k=>k!==PRIMARY))}</th>
    </tr></thead><tbody>`;
  ups.forEach(up=>{
    const nm=(MEAS_ALL.summary.find(r=>String(r.upgrade)===up)||{}).upgrade_name||"";
    METRICS.forEach(([key,lab,unit,dp],mi)=>{
      /* null => the measure is absent from that release; NaN => the measure is
         there but the release does not publish this metric. They must not
         collapse: `Number(null)` is 0, which would report a metric the release
         never published as "saves nothing". */
      const num=v=>(v===null||v===undefined||v==="")?NaN:Number(v);
      const vals=mRuns.map(k=>{ const r=get(up,k); return r?num(r[key]):null; });
      const iP=mRuns.indexOf(PRIMARY);
      const iO=mRuns.findIndex(k=>k!==PRIMARY);
      const ok=v=>v!==null&&v===v;                       // not absent, not NaN
      const d=(ok(vals[iP])&&ok(vals[iO]))?vals[iP]-vals[iO]:null;
      t+=`<tr>${mi===0?`<td rowspan="${METRICS.length}" style="vertical-align:top">
            <b>${up}</b> · ${nm}</td>`:""}
        <td>${lab} <span style="color:var(--ink-3)">${unit}</span></td>
        ${vals.map(v=>`<td>${
          v===null ? absentTag("measureAbsent","this release does not contain this measure")
          : (v!==v ? absentTag("notPublished","this release does not publish the columns this metric needs")
                   : fmt(v,dp))}</td>`).join("")}
        <td>${d===null?absentTag("noValue"):`<span class="cell" style="background:${diffColor(d)}">${
          (d>0?"+":"")+fmt(d,dp)}</span>`}</td></tr>`;
    });
  });
  t+=`</tbody></table></div>
    <div class="head" style="margin-top:12px"><h3>Site energy savings by measure — TBtu</h3>
      ${groupControls("grelcmp")}</div>
    <div id="relcmp-bars"></div></div>`;
  return t;
}
function renderMeasReleaseBars(){
  const mRuns=measRuns();
  if(mRuns.length<2) return;
  const hostEl=$("#relcmp-bars"); if(!hostEl) return;
  const ups=[...new Set(MEAS_ALL.summary.map(r=>String(r.upgrade)))];
  const series=mRuns.map(k=>({key:k,label:runShort(k),color:runColor(k)}));
  const rows=ups.map(up=>{
    const values={};
    mRuns.forEach(k=>{
      const r=MEAS_ALL.summary.find(x=>String(x.upgrade)===up&&x.run===k);
      // null => no bar at all; a zero-height bar would read as "no savings"
      const raw=r?r.site_savings_tbtu:null;
      values[k]=(raw===null||raw===undefined||raw===""||Number.isNaN(Number(raw)))
        ? null : Number(raw);
    });
    return {label:measShort(up)||up, values, ciLow:null, ciHigh:null, hatched:false};
  });
  groupedBar(hostEl, rows, series,
    {yLabel:"TBtu", compact:true, height:250,
     copy:{title:`Site energy savings by measure — ${mRuns.map(runShort).join(" vs ")} (TBtu)`,
           legend:series.map(s=>({color:s.color,label:s.label}))}});
  registerGroup("grelcmp",["relcmp-bars"],["Site energy savings by measure"],
    series.map(s=>({color:s.color,label:s.label})),
    `Site energy savings by measure — ${mRuns.map(runShort).join(" vs ")} (TBtu)`, 1);
}
function renderMeasuresAnnual(){
  const sel=measSelected();
  let h=`<div class="panel"><div class="head">
      <h2>Measure savings summary — TBtu, $M/yr, MMT CO₂e
      <span class="badge">${runShort(PRIMARY)}</span>
      <span class="badge">savings = baseline − measure, each measure's applicable buildings</span></h2>
      <span class="spacer"></span>${measControls()}</div>
    <p class="note">Positive = the measure saves. Bills use the mean-rate bill; emissions use
    eGRID 2021 subregion factors for electricity plus fuel factors.</p>
    ${measSummaryTable(sel)}</div>`;
  // State an absent load-shape leg here, on the tab where a reader would look
  // for it. Logged-only skips are invisible to whoever opens the file.
  if(D.coverage && D.coverage.measures_ts_skipped_reason){
    h+=`<div class="panel"><p class="note"><b>Measure load shapes not computed.</b>
      ${D.coverage.measures_ts_skipped_reason}</p></div>`;
  }
  h+=measReleasePanel();

  if(!sel.length){
    h+=`<div class="panel"><p class="note">No measure selected. Pick one from the
      <b>Measures</b> list above — <b>First 3</b> restores the default.</p></div>`;
    $("#view").innerHTML=h;
    renderMeasReleaseBars();
    wireMeasControls(renderMeasuresAnnual);
    wireGroups();
    return;
  }

  if(state.measView==="single"&&sel.length){
    const mm=sel[0];
    // Legend in a rail to the right: a full end-use x fuel key wraps badly
    // across the top of a chart this tall.
    h+=`<div class="panel"><h2 style="margin-top:0">Annual site energy by fuel and end use — TBtu
        <span class="badge">${mm.up} · ${mm.name}</span>
        <span class="badge">baseline vs measure</span>
        <span class="badge">color = end use, hatch = fuel</span>${feFilterBadge()}</h2>
      <p class="note">Applicable only compares the measure against the baseline rows of its own
      applicable buildings; whole stock re-bases the same change onto the whole-stock baseline
      (stock + measure − applicable baseline), so the two bracket the measure's stock-level
      significance.</p>
      <div class="head" style="margin-bottom:2px"><span class="spacer"></span>
        <span class="note" style="margin:0">both panels + legend:</span>
        ${groupControls("gfe")}</div>
      <div class="chart-row">
        <div class="chart-main"><div class="chart-pair" data-scale="own">
          <div><div class="head"><h3>Applicable buildings only — TBtu</h3></div>
            <div id="mfe-app"></div></div>
          <div><div class="head"><h3>Whole stock, re-based — TBtu</h3></div>
            <div id="mfe-stock"></div></div>
        </div></div>
        <div class="chart-side">
          <p class="legend-title">End use &amp; fuel</p><div id="fe-legend"></div></div>
      </div></div>`;
    /* GHG and bills: ONE row of three panels with a population dropdown, not
       two stacked rows. Six panels of two bars each cost most of a screen to
       say something the reader compares one population at a time, and the
       dropdown matches the control the multi-measure view already uses.
       The row shares one y scale across the three factors — that comparison is
       the point of the figure — but the two populations do NOT share a scale
       with each other. They differ by roughly the applicable share, so pinning
       both to the larger left the applicable panels using about half their
       height for empty plot. */
    // same control the multi-measure view uses, so the two views read alike
    const popSel=(id)=>`<label class="note" style="margin:0">population
      <select id="${id}">${MEAS_POPS.map(([slug,lab])=>
        `<option value="${slug}"${state.measPop===slug?" selected":""}>${lab}</option>`)
        .join("")}</select></label>`;
    h+=`<div class="panel"><div class="head"><h2 style="margin-top:0">Annual GHG emissions by fuel
        — MMT CO₂e <span class="badge">${mm.up} · ${mm.name}</span>
        <span class="badge">baseline vs measure</span></h2>
        <span class="spacer"></span>${popSel("mghgPop")}</div>
      <p class="note">Stacked by fuel; the three panels differ only in the electricity
      emissions factor (eGRID 2021 subregion, and NREL Cambium LRMER high / low renewable
      cost, 15-year levelization, 2023 start). Fuel factors are identical across all three,
      and the three share one y scale so the factor comparison is readable.</p>
      ${fuelLegend(FUEL_ORDER)}
      <div class="head"><h3>${popLabel(state.measPop)}</h3>${groupControls("gghg")}</div>
      <div class="grid3fit">${GHG_PANELS.map(([f,lab])=>
        `<div><h3>${lab}</h3><div id="mghg-${f}"></div></div>`).join("")}</div></div>`;
    h+=`<div class="panel"><div class="head"><h2 style="margin-top:0">Annual utility bills by fuel
        — billion $/yr <span class="badge">${mm.up} · ${mm.name}</span>
        <span class="badge">baseline vs measure</span></h2>
        <span class="spacer"></span>${popSel("mbillPop")}</div>
      <p class="note">Stacked by fuel; the three panels use the maximum, mean, and minimum
      electricity rate for each building, so they bracket rate uncertainty. Gas, fuel oil,
      and propane bills use state-average rates in all three, and the three share one y
      scale.</p>
      ${fuelLegend(["electricity","natural_gas","fuel_oil","propane"])}
      <div class="head"><h3>${popLabel(state.measPop)}</h3>${groupControls("gbill")}</div>
      <div class="grid3fit">${BILL_PANELS.map(([f,lab])=>
        `<div><h3>${lab}</h3><div id="mbill-${f}"></div></div>`).join("")}</div></div>`;
    h+=measDistPanels([mm]);
  } else {
    // union and intersection only mean something against 2+ measures
    const bases=availableBases().filter(b=>
      sel.length>1||(b[0]!=="union"&&b[0]!=="inter"));
    const bas=bases.find(b=>b[0]===state.measBasis)||bases[0];
    const pop=basisPopulation(sel, bas[0]);
    const empty=pop&&bas[0]!=="own"&&!pop.w;
    h+=`<div class="panel"><div class="head"><h2 style="margin-top:0">Annual site energy by fuel and
        end use — baseline vs each measure — TBtu
        <span class="badge">${bas[1]}</span> ${populationBadge(pop,bas[0])}
        ${feFilterBadge()}</h2>
        <span class="spacer"></span>
        <label class="note" style="margin:0">population
        <select id="measBasis">${bases.map(([k,lab])=>
          `<option value="${k}" ${k===bas[0]?"selected":""}>${lab}</option>`).join("")}
        </select></label></div>
      <p class="note">Baseline first, then one bar per selected measure — the Scenario Comparison
      figure from the measure postprocessing pack. Color is the end use, hatch is the fuel; the
      label above each bar is its total, with the change from
      ${bas[0]==="own"?"that measure's own baseline bar (the bar to its left)"
        :"the Baseline bar"} in parentheses.
      <b>Population: ${bas[2]}.</b> A building is "applicable" to a measure when it appears in
      that measure's upgrade partition, so a failed simulation counts as not applicable and is
      held at baseline.${bas[0]==="stock"?` Because non-applicable buildings are held at
      baseline, a measure with a small applicable share reads as a small percentage here even
      when it saves a lot on the buildings it touches — switch to its own applicability to see
      that.`:""}${HAS_MASKS?"":` Only these two bases are available in this assessment — union
      and intersection need the applicability-mask leg.`}</p>
      ${empty?`<p class="note" style="color:var(--bad)"><b>No building in the stock is applicable
        to every selected measure</b>, so the intersection is empty. Drop a measure, or use the
        union basis.</p>`:`<div class="chart-row">
        <div class="chart-main"><div id="msc-fe"></div></div>
        <div class="chart-side">
          <p class="legend-title">End use &amp; fuel</p><div id="fe-legend"></div></div>
      </div>`}</div>`;
    if(empty){
      $("#view").innerHTML=h;
      renderMeasReleaseBars();
      const mb0=$("#measBasis");
      if(mb0) mb0.addEventListener("change",e=>{
        state.measBasis=e.target.value; renderMeasuresAnnual(); syncHash(); });
      wireMeasControls(renderMeasuresAnnual);
      wireGroups();
      return;
    }
    h+=`<div class="panel"><div class="head"><h2 style="margin-top:0">Annual GHG emissions by fuel
        — baseline vs each measure — MMT CO₂e <span class="badge">${bas[1]}</span>
        ${populationBadge(pop,bas[0])}</h2>${groupControls("mgghg")}</div>
      ${fuelLegend(FUEL_ORDER)}
      <div class="grid3fit">${[["egrid","eGRID 2021"],["lrmer_high","LRMER High RE Cost 15"],
        ["lrmer_low","LRMER Low RE Cost 15"]].map(([f,lab])=>
        `<div><h3>${lab}</h3><div id="msc-ghg-${f}"></div></div>`).join("")}</div></div>`;
    h+=`<div class="panel"><div class="head"><h2 style="margin-top:0">Annual utility bills by fuel
        — baseline vs each measure — billion $/yr <span class="badge">${bas[1]}</span>
        ${populationBadge(pop,bas[0])}</h2>${groupControls("mgbill")}</div>
      ${fuelLegend(["electricity","natural_gas","fuel_oil","propane"])}
      <div class="grid3fit">${[["elec_max","With max electricity rate"],
        ["elec_mean","With mean electricity rate"],["elec_min","With min electricity rate"]]
        .map(([f,lab])=>`<div><h3>${lab}</h3><div id="msc-bill-${f}"></div></div>`).join("")}
      </div></div>`;
    if((MEAS.categories||[]).length){
      const cgLab=(CAT_GROUPS.find(g=>g[0]===state.measCatGroup)||CAT_GROUPS[0])[1];
      h+=`<div class="panel"><div class="head"><h2 style="margin-top:0">Stock totals by
          ${cgLab.toLowerCase()} — baseline vs each measure
          <span class="badge">TBtu and Mft²</span>
          <span class="badge">${bas[1]}</span></h2><span class="spacer"></span>
          <label class="note" style="margin:0">break down by
          <select id="measCatGroup">${CAT_GROUPS.map(([g,lab])=>
            `<option value="${g}" ${g===state.measCatGroup?"selected":""}>${lab}</option>`).join("")}
          </select></label></div>
        <p class="note">Floor area is the prevalence term — it does not change with a measure, so
        those bars should be identical across scenarios, which is a useful check that the
        population basis is doing what it says.</p>
        <div class="legend">${bas[0]==="own"
          ? sel.map((mm,i)=>swatch("#8B949B",`Baseline · ${mm.up}`)
              +swatch(scenarioPalette(sel.length+1)[i+1],mm.short)).join("")
          : ["Baseline",...sel.map(mm=>mm.short)].map((lab,i)=>
              swatch(scenarioPalette(sel.length+1)[i],lab)).join("")}</div>
        ${CAT_METRICS.map(([k,lab,unit])=>
          `<div style="margin-top:10px"><h3>${lab} — ${unit}</h3>
           <div class="scroll" id="mcat-${k.replace(/[^a-z_]/g,"")}"></div></div>`).join("")}
        </div>`;
    }
    h+=measDistPanels(sel);
    h+=`<div class="panel"><h2 style="margin-top:0">Per-building site savings tails by measure and
        fuel — %
        <span class="badge">each measure's own applicable buildings</span></h2>
      <p class="note">The share of buildings a measure makes worse, and the share whose percent
      savings falls outside ±150% (excluded from the boxes above). Both are computed over each
      measure's own applicable buildings.</p>
      <div class="scroll"><table><thead><tr><th>Measure</th>
        <th>Category</th><th>median %</th><th>% of models negative</th>
        <th>% of models beyond ±150%</th>
        </tr></thead><tbody id="ms-flags"></tbody></table></div></div>`;
  }
  $("#view").innerHTML=h;

  if(state.measView==="single"&&sel.length){
    const mm=sel[0];
    const KWH_TBTU=3412.141633/1e12;
    const S=(MEAS.scenarios||[]).find(r=>r.scenario==="stock_baseline");
    const B=(MEAS.scenarios||[]).find(r=>String(r.upgrade)===mm.up&&r.scenario==="baseline");
    const M=(MEAS.scenarios||[]).find(r=>String(r.upgrade)===mm.up&&r.scenario==="measure");
    const val=(row,key)=>{ const v=row?row[key]:null;
      return (v===null||v===undefined||isNaN(v))?0:+v; };
    // total-stock view of the measure: whole stock + (measure − applicable baseline)
    const stockVal=key=>val(S,key)+val(M,key)-val(B,key);
    const fmtTot=v=>fmt(v,Math.abs(v)<20?1:0);
    /* Totals come from `full` (every end use), never from the drawn segments:
       otherwise hiding an end use in the legend silently rewrites the printed
       total and the savings percentage, and that corrupted label goes into the
       PNG export. `euFilterBadge` states the discrepancy on the chart. */
    const withTops=(bars, full)=>{
      const sum=segs=>segs.reduce((t,s)=>t+s.value,0);
      const tb=sum(full?full[0]:bars[0].segs), tm=sum(full?full[1]:bars[1].segs);
      bars[0].topLabel=fmtTot(tb);
      bars[1].topLabel=`${fmtTot(tm)} (${tm<=tb?"−":"+"}${fmt(Math.abs(tm-tb)/(tb||1)*100,1)}%)`;
      return bars;
    };
    const feSegs=(get, all)=>{
      const segs=[];
      FE_ENDUSE_ORDER.forEach(eu=>FUEL_ORDER.forEach(f=>{
        if(!all && !feVisible(eu,f)) return;      // hidden per (end use, fuel)
        const v=get(`e|${f}|${eu}`)*KWH_TBTU;
        if(v) segs.push({name:feLabel(eu,f),value:v,eu,fuel:f,
          color:D.enduseColors[eu]||"#8B8B8B",pattern:FUEL_PATTERNS[f]});
      }));
      return segs;
    };
    // Legend built from the unfiltered segment order, so hidden end uses stay
    // listed (greyed) and the order always matches the plot.
    const feCombo=feComboItems(feSegs(k=>val(S,k),true));
    const feLegendItems=feComboExport(feCombo);
    if($("#fe-legend")) $("#fe-legend").innerHTML=feComboLegend(feCombo);
    [["#mfe-app","applicable buildings",k=>val(B,k),k=>val(M,k)],
     ["#mfe-stock","total stock",k=>val(S,k),k=>stockVal(k)]].forEach(([id,pop,gB,gM])=>{
      // Name the scenario on the bar, not "Measure": a figure pasted into a
      // report has to say which measure it is without its caption.
      stackedBarChart($(id), withTops(
          [{label:"Baseline",segs:feSegs(gB)},{label:mm.short,segs:feSegs(gM)}],
          [feSegs(gB,true), feSegs(gM,true)]),
        {height:430, targetWidth:432, wide:true, segLabels:true, segDec:1, yLabel:"TBtu",
         copy:{title:`${mm.up} ${mm.name} — annual energy by fuel and end use, ${pop} (TBtu)`,
               legend:feLegendItems}});
    });
    /* One group over BOTH populations, so the pair expands and copies together
       with the shared legend — which is how the figure is actually read, and
       what the two solo controls could not do. */
    registerGroup("gfe",["mfe-app","mfe-stock"],
      ["Applicable buildings only","Whole stock, re-based"], feLegendItems,
      `${mm.up} ${mm.name} — annual energy by fuel and end use (TBtu)`, 2);
    const fuelSegs=(get,elecKey,keys)=>{
      const segs=[], v=get(elecKey);
      if(v) segs.push({name:"electricity",value:v,color:FUEL_COLORS.electricity});
      keys.forEach(k=>{ const vv=get(k), fuel=k.split("|")[1];
        if(vv) segs.push({name:fuel.replace(/_/g," "),value:vv,color:FUEL_COLORS[fuel]}); });
      return segs;
    };
    // Bars are labeled only Baseline / Measure — the factor or rate is the
    // panel title, so repeating it on every tick just crowded the axis. One
    // shared y scale per family, as upstream intends.
    const POPS={app:["applicable buildings",k=>val(B,k),k=>val(M,k)],
                stock:["total stock",k=>val(S,k),k=>stockVal(k)]};
    const POP=POPS[state.measPop]||POPS.app;
    const [popName,gB,gM]=POP;
    /* Max across the three factors of the SELECTED population only: the row
       shares a scale so the factors are comparable, but taking the max over
       both populations made the applicable panels waste half their height. */
    const famMax=(keys,fuels)=>Math.max(1e-9,...keys.flatMap(k=>
      [gB,gM].map(g=>fuelSegs(g,k,fuels).reduce((t,s)=>t+Math.max(s.value,0),0))));
    const GHG_LABELS={egrid:"eGRID 2021",lrmer_high:"LRMER High RE Cost 15",
      lrmer_low:"LRMER Low RE Cost 15"};
    const GHG_FUELS=["em|natural_gas","em|fuel_oil","em|propane",
      "em|district_heating","em|district_cooling"];
    const ghgLegend=FUEL_ORDER.map(k=>({color:FUEL_COLORS[k],label:k.replace(/_/g," ")}));
    const ghgMax1=famMax(GHG_PANELS.map(([f])=>`em|${f}`),GHG_FUELS);
    GHG_PANELS.forEach(([f,lab])=>{
      stackedBarChart($(`#mghg-${f}`), withTops([
          {label:"Baseline",segs:fuelSegs(gB,`em|${f}`,GHG_FUELS)},
          {label:mm.short,segs:fuelSegs(gM,`em|${f}`,GHG_FUELS)}]),
        {height:300, targetWidth:348, segLabels:true, yLabel:"MMT CO₂e", yMax:ghgMax1,
         copy:{title:`${mm.up} ${mm.name} — GHG emissions, ${lab}, ${popName} (MMT CO₂e)`,
               legend:ghgLegend}});
    });
    const GHG_LABS=GHG_PANELS.map(([,lab])=>lab);
    registerGroup("gghg", GHG_PANELS.map(([f])=>`mghg-${f}`), GHG_LABS, ghgLegend,
      `${mm.up} ${mm.name} — annual GHG emissions by fuel, ${popName} (MMT CO₂e)`, 3);
    const RATE_LABELS={elec_max:"With max electricity rate",
      elec_mean:"With mean electricity rate", elec_min:"With min electricity rate"};
    const BILL_FUELS=["bill|natural_gas","bill|fuel_oil","bill|propane"];
    const billLegend=["electricity","natural_gas","fuel_oil","propane"]
      .map(k=>({color:FUEL_COLORS[k],label:k.replace(/_/g," ")}));
    const billMax1=famMax(BILL_PANELS.map(([f])=>`bill|${f}`),BILL_FUELS);
    BILL_PANELS.forEach(([f,lab])=>{
      stackedBarChart($(`#mbill-${f}`), withTops([
          {label:"Baseline",segs:fuelSegs(gB,`bill|${f}`,BILL_FUELS)},
          {label:mm.short,segs:fuelSegs(gM,`bill|${f}`,BILL_FUELS)}]),
        {height:300, targetWidth:348, segLabels:true, yLabel:"billion $/yr", yMax:billMax1,
         copy:{title:`${mm.up} ${mm.name} — utility bills, ${lab}, ${popName} (billion $/yr)`,
               legend:billLegend}});
    });
    const RATE_LABS=BILL_PANELS.map(([,lab])=>lab);
    registerGroup("gbill", BILL_PANELS.map(([f])=>`mbill-${f}`), RATE_LABS, billLegend,
      `${mm.up} ${mm.name} — annual utility bills by fuel, ${popName} (billion $/yr)`, 3);
    ["mghgPop","mbillPop"].forEach(id=>{ const s=$(`#${id}`);
      if(s) s.addEventListener("change",e=>{
        state.measPop=e.target.value; renderMeasuresAnnual(); syncHash(); }); });
    renderMeasDist([mm]);
    wireEnduseLegend(renderMeasuresAnnual);
    wireFeLegend(renderMeasuresAnnual);
  } else {
    const KWH_TBTU=3412.141633/1e12;
    const bases2=availableBases().filter(b=>
      sel.length>1||(b[0]!=="union"&&b[0]!=="inter"));
    const basArr=bases2.find(b=>b[0]===state.measBasis)||bases2[0];
    const bas=basArr[0];
    const pop2=basisPopulation(sel, bas);
    // Every exported figure must be readable on its own: the basis is defined
    // by the selection, so the selection and the population travel with it.
    const basisTag=`${basArr[1]}; measures ${sel.map(mm=>mm.up).join(", ")}`
      +(pop2&&bas!=="own"?`; ${fmt(pop2.w/1e3,0)}k weighted buildings, `
        +`${fmt(pop2.pctW,1)}% of stock`:"");
    const bars=basisBars(sel, bas);
    // Same population, different scenarios: every bar must cover the same
    // weighted stock. A mismatch would mean the mask algebra is wrong.
    if(bas!=="own"&&bars.length>1){
      const w0=+bars[0].agg.w||0;
      const bad=bars.slice(1).filter(b=>Math.abs((+b.agg.w||0)-w0)/(w0||1)>1e-4);
      if(bad.length) $("#msc-fe").insertAdjacentHTML("beforebegin",
        `<p class="note" style="color:var(--bad)">Population check failed: ${bad.length} bar(s)
         cover a different weighted stock than the Baseline bar. Treat these figures as
         suspect.</p>`);
    }
    const EUS=[...D.enduseOrder,"exterior_equipment"];
    // totals carry the change from each bar's own reference: the paired
    // baseline on the "own" basis, the single Baseline bar otherwise
    /* `totalOf` defaults to `segsOf`, but the fuel x end-use figure passes an
       unfiltered variant so hiding an end use cannot move the printed total or
       the savings percentage (see euFilterBadge). */
    const tops=(segsOf,totalOf)=>bars.map(b=>{
      const segs=segsOf(b.agg);
      const full=(totalOf||segsOf)(b.agg);
      const tot=full.reduce((t,s)=>t+s.value,0);
      let topLabel=fmt(tot,Math.abs(tot)<20?1:0);
      if(b.ref){
        const rt=(totalOf||segsOf)(b.ref).reduce((t,s)=>t+s.value,0);
        if(rt) topLabel+=` (${tot<=rt?"−":"+"}${fmt(Math.abs(tot-rt)/rt*100,1)}%)`;
      }
      return {label:b.label, segs, topLabel};
    });
    // bottom-up: end use outer, fuel inner, both in the upstream figure's order
    const feSegsAll=(agg, all)=>{
      const segs=[];
      FE_ENDUSE_ORDER.forEach(eu=>FUEL_ORDER.forEach(f=>{
        if(!all && !feVisible(eu,f)) return;      // hidden per (end use, fuel)
        const v=(+agg[`e|${f}|${eu}`]||0)*KWH_TBTU;
        if(v) segs.push({name:feLabel(eu,f),value:v,eu,fuel:f,
          color:D.enduseColors[eu]||"#8B8B8B",pattern:FUEL_PATTERNS[f]});
      }));
      return segs;               // stackedBarChart draws in order, first at the bottom
    };
    const feSegs=agg=>feSegsAll(agg,false);
    const feSegsFull=agg=>feSegsAll(agg,true);
    // as in the single view: legend order comes from the unfiltered segments
    const feCombo2=feComboItems(feSegsAll(bars[0].agg,true));
    const feLegendItems2=feComboExport(feCombo2);
    if($("#fe-legend")) $("#fe-legend").innerHTML=feComboLegend(feCombo2);
    // Proportions follow the upstream figure, whose plot area is markedly
    // taller than the width it gives each bar — that is what leaves room for
    // the in-segment labels.
    stackedBarChart($("#msc-fe"), tops(feSegs, feSegsFull),
      {height:560, targetWidth:864, wide:true, segLabels:true, segDec:1, yLabel:"TBtu",
       pairGaps:bas==="own",
       copy:{title:`Annual energy by fuel and end use — ${basisTag} (TBtu)`,
             legend:feLegendItems2}});
    const fuelSegs=(elecKey,keys)=>agg=>{
      const segs=[], v=+agg[elecKey]||0;
      if(v) segs.push({name:"electricity",value:v,color:FUEL_COLORS.electricity});
      keys.forEach(k=>{ const vv=+agg[k]||0, fuel=k.split("|")[1];
        if(vv) segs.push({name:fuel.replace(/_/g," "),value:vv,color:FUEL_COLORS[fuel]}); });
      return segs;
    };
    // The three panels of a family share one y scale, as upstream's sharey=True
    // intends — otherwise the electricity-factor (or rate) comparison the
    // figure exists to make is defeated by three different axes.
    const familyMax=(keys,fuels)=>Math.max(1e-9,...keys.flatMap(k=>
      tops(fuelSegs(k,fuels)).map(b=>b.segs.reduce((t,s)=>t+Math.max(s.value,0),0))));
    const GHG_FUELS=["em|natural_gas","em|fuel_oil","em|propane",
      "em|district_heating","em|district_cooling"];
    const ghgMax=familyMax(["em|egrid","em|lrmer_high","em|lrmer_low"],GHG_FUELS);
    [["egrid","eGRID 2021"],["lrmer_high","LRMER High RE Cost 15"],
     ["lrmer_low","LRMER Low RE Cost 15"]].forEach(([f,lab])=>{
      stackedBarChart($(`#msc-ghg-${f}`), tops(fuelSegs(`em|${f}`,GHG_FUELS)),
        {height:400, targetWidth:348, segLabels:true, yLabel:"MMT CO₂e", yMax:ghgMax,
         pairGaps:bas==="own",
         copy:{title:`GHG emissions, ${lab} — ${basisTag} (MMT CO₂e)`,
               legend:FUEL_ORDER.map(k=>({color:FUEL_COLORS[k],label:k.replace(/_/g," ")}))}});
    });
    registerGroup("mgghg",["msc-ghg-egrid","msc-ghg-lrmer_high","msc-ghg-lrmer_low"],
      ["eGRID 2021","LRMER High RE Cost 15","LRMER Low RE Cost 15"],
      FUEL_ORDER.map(k=>({color:FUEL_COLORS[k],label:k.replace(/_/g," ")})),
      `Annual GHG emissions by fuel — ${basisTag} (MMT CO₂e)`, 3);
    const BILL_FUELS=["bill|natural_gas","bill|fuel_oil","bill|propane"];
    const billMax=familyMax(["bill|elec_max","bill|elec_mean","bill|elec_min"],BILL_FUELS);
    [["elec_max","max"],["elec_mean","mean"],["elec_min","min"]].forEach(([f,lab])=>{
      stackedBarChart($(`#msc-bill-${f}`), tops(fuelSegs(`bill|${f}`,BILL_FUELS)),
        {height:400, targetWidth:348, segLabels:true, yLabel:"billion $/yr", yMax:billMax,
         pairGaps:bas==="own",
         copy:{title:`Annual utility bills, ${lab} electricity rate — ${basisTag} (billion $/yr)`,
               legend:["electricity","natural_gas","fuel_oil","propane"]
                 .map(k=>({color:FUEL_COLORS[k],label:k.replace(/_/g," ")}))}});
    });
    registerGroup("mgbill",["msc-bill-elec_max","msc-bill-elec_mean","msc-bill-elec_min"],
      ["With max electricity rate","With mean electricity rate","With min electricity rate"],
      ["electricity","natural_gas","fuel_oil","propane"]
        .map(k=>({color:FUEL_COLORS[k],label:k.replace(/_/g," ")})),
      `Annual utility bills by fuel — ${basisTag} (billion $/yr)`, 3);
    if((MEAS.categories||[]).length){
      const dim=state.measCatGroup;
      const pal=scenarioPalette(sel.length+1);
      // On the own basis each measure has its own population, so it gets its
      // own baseline bar beside it; a single shared Baseline bar would be the
      // whole stock and not comparable to any of them.
      const series = bas==="own"
        ? sel.flatMap((mm,i)=>[{key:`base_${mm.up}`,label:`Baseline · ${mm.up}`,color:"#8B949B"},
                               {key:mm.up,label:mm.short,color:pal[i+1]}])
        : [{key:"baseline",label:"Baseline",color:pal[0]}]
            .concat(sel.map((mm,i)=>({key:mm.up,label:mm.short,color:pal[i+1]})));
      const order=(D.ordered||{})[dim]||null;
      CAT_METRICS.forEach(([k,lab,unit,scale])=>{
        const agg=catAgg(dim, bas, sel, k, scale);
        if(!agg) return;
        let cats=Object.keys(agg);
        if(order) cats.sort((a,b)=>{
          const ia=order.indexOf(a), ib=order.indexOf(b);
          return (ia===-1?99:ia)-(ib===-1?99:ib);
        }); else cats.sort();
        const rows=cats.map(c=>({label:c, values:agg[c]}));
        groupedBar($(`#mcat-${k.replace(/[^a-z_]/g,"")}`), rows, series,
          {height:dim==="none"?210:250, yLabel:unit,
           copy:{title:`${lab} by ${dim==="none"?"scenario":dim.replace(/_/g," ")} — `
                   +`${basisTag} (${unit})`,
                 legend:series.map(s=>({color:s.color,label:s.label}))}});
      });
      const cg=$("#measCatGroup");
      if(cg) cg.addEventListener("change",e=>{
        state.measCatGroup=e.target.value; renderMeasuresAnnual(); syncHash(); });
    }
    renderMeasDist(sel);
    const mb=$("#measBasis");
    if(mb) mb.addEventListener("change",e=>{
      state.measBasis=e.target.value; renderMeasuresAnnual(); syncHash(); });
    let fl="";
    MEAS.dist.filter(r=>r.kind==="pct_site"&&r.group==="fuel"
        &&sel.some(mm=>mm.up===String(r.upgrade))).forEach(r=>{
      const warnNeg=r.share_negative_pct>10, warnTail=r.share_trimmed_pct>1;
      fl+=`<tr><td style="text-align:left">${measShort(r.upgrade)}</td>
        <td style="text-align:left">${r.category}</td><td>${fmt(r.p50)}</td>
        <td${warnNeg?' style="color:var(--bad);font-weight:600"':''}>${fmt(r.share_negative_pct)}%</td>
        <td${warnTail?' style="color:var(--bad);font-weight:600"':''}>${fmt(r.share_trimmed_pct,2)}%</td></tr>`;
    });
    $("#ms-flags").innerHTML=fl;
    wireEnduseLegend(renderMeasuresAnnual);
    wireFeLegend(renderMeasuresAnnual);
  }
  renderMeasReleaseBars();
  wireMeasControls(renderMeasuresAnnual);
  wireGroups();
}

function renderMeasuresTs(){
  const states=Object.keys(MEAS.ts||{});
  // One location at a time. `states` stays the full list for the dropdown;
  // `shown` is what gets rendered. A stale hash value falls back to the first.
  if(!states.includes(state.measLoc)) state.measLoc=states[0]||"";
  const shown=states.filter(st=>st===state.measLoc);
  const locSelect=states.length>1?`<label class="note" style="margin:0 8px 0 0">location
      <select id="measLoc" aria-label="measure timeseries location">${states.map(st=>
        `<option value="${st}" ${st===state.measLoc?"selected":""}>${st.replace(/_/g," ")}</option>`
      ).join("")}</select></label>`:"";
  if(!states.length){
    // The assessment records WHY this leg did not run. Show that, rather than a
    // generic placeholder: the reason is almost never "you forgot to ask for
    // it", and the old text named two CLI flags that no longer exist -- this
    // runs as a step inside a postprocessing driver, so there is nothing to
    // re-run with.
    const why=(D.coverage||{}).measures_ts_skipped_reason;
    $("#view").innerHTML=`<div class="panel"><h2>Measure load shapes — not computed</h2>
      <p class="note">${why||`No measure timeseries in this assessment. This leg needs the run's
      by-state-and-county metadata aggregate plus a queryable timeseries table, and at least one
      state to profile (taken from the run's <code>timeseries_locations_to_plot</code>).`}</p>
      <p class="note">The measure <b>annual</b> savings on the previous tab do not depend on any of
      that and are unaffected.</p></div>`;
    return;
  }
  const sel=measSelected();
  if(!sel.length){
    $("#view").innerHTML=`<div class="panel"><div class="head">
        <h2>Measures — timeseries</h2><span class="spacer"></span>${measControls()}</div>
      <p class="note">No measure selected. Pick one from the <b>Measures</b> list above.</p></div>`;
    wireMeasControls(renderMeasuresTs);
    return;
  }
  const SEASONS=["Summer","Shoulder","Winter"];   // upstream row order
  const ENDUSE_ROWS=["heat_recovery","heat_rejection","pumps","refrigeration","water_systems",
    "heating","cooling","exterior_lighting","interior_lighting","fans","interior_equipment"];
  // The masked hourly leg carries every scenario by applicability bitmask, so
  // the timeseries offers the same four bases as the annual tab; without it
  // only the two a per-measure baseline can express are available.
  const TSM=(MEAS.tsMask||{});
  const hasTsMask=Object.keys(TSM).length>0;
  const TS_BASES=(hasTsMask?MEAS_BASES:MEAS_BASES.filter(b=>b[0]==="stock"||b[0]==="own"))
    .filter(b=>sel.length>1||(b[0]!=="union"&&b[0]!=="inter"));
  const tsBasis=(TS_BASES.find(b=>b[0]===state.measBasis)||TS_BASES[0])[0];
  const tsBas=TS_BASES.find(b=>b[0]===tsBasis);
  /* Hourly series for one (season, day_type) under a population basis.
     day_type null means "all days", mixed 5/7 weekday + 2/7 weekend like the
     upstream annual_average figure. Returns hour -> weighted kWh. */
  function tsSeries(st, sn, dayType, col, scenarioFor, maskOk){
    const rows=TSM[st]||[];
    const wd={}, we={};
    rows.forEach(r=>{
      if(r.season!==sn) return;
      if(!maskOk(r.mask)) return;
      if(String(r.upgrade)!==String(scenarioFor(r.mask))) return;
      const v=r[col];
      if(v===null||v===undefined) return;
      const t=r.day_type==="Weekend"?we:wd;
      t[r.hour]=(t[r.hour]||0)+ +v;
    });
    if(dayType==="Weekday") return wd;
    if(dayType==="Weekend") return we;
    const out={};
    for(let hh=0;hh<24;hh++){
      const a=wd[hh], b=we[hh];
      if(a===undefined&&b===undefined) continue;
      out[hh]=((a===undefined?b:a)*5+(b===undefined?a:b)*2)/7;
    }
    return out;
  }
  // scenario to read for a mask: the measure where it applies, baseline where
  // it does not — a measure cannot change a building it is not applicable to
  const tsScenFor=up=>mk=>((mk & measBit(up))?String(up):"0");
  const tsBaseScen=()=>"0";

  /* ---- comparison series WITHOUT the masked leg -------------------------
     The masked hourly leg is capped at 8 measures (the mask space is 2^M), so
     a run with more of them has no masks at all -- and the comparison view
     read ONLY masked rows, so every panel bailed at `if(!hours.length) return`
     and the tab rendered its headings with no charts under them. That is the
     "nothing shows up" case.

     Two of the four bases never needed masks. measures_ts_<location>.csv
     already carries, per (season, day type, hour):
        upgrade "<n>"       the measure over its applicable buildings
        upgrade "base_<n>"  those SAME buildings at baseline
        upgrade "0"         the whole stock at baseline
     so "each measure's own applicability" is a direct read, and "entire stock"
     is stock baseline minus that measure's applicable baseline plus the
     measure. Only union and intersection genuinely require the masks, because
     only they need to know which buildings several measures share. */
  function tsRaw(st, sn, dayType, col, upgradeKey){
    const wd={}, we={};
    (MEAS.ts[st]||[]).forEach(r=>{
      if(r.season!==sn) return;
      if(String(r.upgrade)!==String(upgradeKey)) return;
      const v=r[col];
      if(v===null||v===undefined) return;
      const t=r.day_type==="Weekend"?we:wd;
      t[r.hour]=(t[r.hour]||0)+ +v;
    });
    if(dayType==="Weekday") return wd;
    if(dayType==="Weekend") return we;
    const out={};
    for(let hh=0;hh<24;hh++){
      const a=wd[hh], b=we[hh];
      if(a===undefined&&b===undefined) continue;
      // same 5/7 weekday + 2/7 weekend mix as the masked path
      out[hh]=((a===undefined?b:a)*5+(b===undefined?a:b)*2)/7;
    }
    return out;
  }
  /* stock basis for one measure: the whole stock, with only its applicable
     buildings changed. Hours present in any term are kept; a term missing an
     hour contributes nothing rather than voiding the hour. */
  const tsCombine=(base0, baseUp, meas)=>{
    const out={};
    new Set([...Object.keys(base0), ...Object.keys(baseUp), ...Object.keys(meas)])
      .forEach(k=>{ out[k]=(+base0[k]||0)-(+baseUp[k]||0)+(+meas[k]||0); });
    return out;
  };
  /* The population badge here must be state-scoped: the mask weights in
     measures_masks.csv are national, while these profiles cover one state, so
     the share is computed from these rows as a share of the state's baseline
     electricity rather than borrowing the national building counts. */
  function tsPopBadge(st, basis){
    if(!hasTsMask||basis==="own")
      return basis==="own"?`<span class="badge">population differs per measure</span>`:"";
    const pred=basisPred(basis, sel);
    let inP=0, all=0;
    (TSM[st]||[]).forEach(r=>{
      if(String(r.upgrade)!=="0") return;
      const v=+r.elec_kwh||0;
      all+=v;
      if(pred(r.mask)) inP+=v;
    });
    if(!inP) return `<span class="badge" style="color:var(--bad)">no buildings in ${st}</span>`;
    const pct=all?inP/all*100:0;
    return `<span class="badge"${pct<1?' style="color:var(--bad)"':''}>`+
      `${fmt(pct,1)}% of ${st} baseline electricity</span>`;
  }
  let h=`<div class="panel"><div class="head">
      <h2>Hourly load shape by season and day type — stock MW
        <span class="badge" title="The measure timeseries leg was queried against this release only, so this tab has no release comparison and the header compare control is disabled here.">${
          ALL_RUNS.length>1?`${runShort(PRIMARY)} only — no release comparison`:runShort(PRIMARY)}</span>
        ${state.measView==="multi"?`<span class="badge">${tsBas[1]}</span>`:""}</h2>
      <span class="spacer"></span>${locSelect}${measControls()}</div>
    <p class="note">Seasonal average electricity demand, replicating the measure postprocessing
    timeseries figures. ${seasonSentence()} Values are hourly-mean stock megawatts.
    ${state.measView==="multi"?`<b>Population: ${tsBas[2]}.</b>`
      +(hasTsMask?"":` Union and intersection need the masked hourly leg, which this assessment
        does not carry.`):""}</p>
    ${state.measView==="multi"?`<div class="head" style="margin-top:8px">
      <label class="note" style="margin:0">population
      <select id="measBasisTs">${TS_BASES.map(([k,lab])=>
        `<option value="${k}" ${k===tsBasis?"selected":""}>${lab}</option>`).join("")}
      </select></label>${shown.map(st=>tsPopBadge(st,tsBasis)).join(" ")}</div>`:""}</div>`;

  shown.forEach(st=>{
    if(state.measView==="single"&&sel.length){
      const mm=sel[0];
      h+=`<div class="panel"><h2>Average hourly electricity demand by end use — ${st} — MW
          <span class="badge">${mm.up} · ${mm.name}</span>
          <span class="badge">applicable buildings</span>
          <span class="badge">measure vs its own baseline</span>
          ${euAnyHidden()?`<span class="badge" style="color:var(--bad)">end uses hidden — the
            stack is a subset; the total lines are unfiltered</span>`:""}
          ${groupControls(`gts-elec-${st}`)}</h2>
        <p class="note">The stack is the measure's end uses over its applicable buildings; the
        solid line is the measure total and the dashed line the same buildings' baseline total —
        the gap between them is the savings shape.</p>
        <div class="ami-wrap">
          <div class="ami-grid" id="mts-elec-${st}"></div>
          <div class="ami-legend">${amiStackLegendHTML()}
            <span class="key"><span style="width:14px;height:0;border-top:3px solid var(--ink);display:inline-block;flex:none"></span>Measure total</span>
            <span class="key"><span style="width:14px;height:0;border-top:3px dashed var(--ink);display:inline-block;flex:none"></span>Baseline total (applicable)</span>
          </div>
        </div></div>
        <div class="panel"><h2>Average hourly natural gas demand — ${st} — MW thermal
          <span class="badge">${mm.up} · ${mm.name}</span>
          <span class="badge">applicable buildings</span>
          ${groupControls(`gts-gas-${st}`)}</h2>
        <p class="note">Gas is shown as thermal megawatts, the same energy-rate unit as the
        electricity panel above but not interchangeable with it. Solid is the measure, dashed the
        same buildings' baseline; the gap is the savings shape.</p>
        <div class="ami-wrap">
          <div class="ami-grid" id="mts-gas-${st}"></div>
          <div class="ami-legend">
            <span class="key"><span style="width:14px;height:0;border-top:3px solid var(--ink);display:inline-block;flex:none"></span>Measure total</span>
            <span class="key"><span style="width:14px;height:0;border-top:3px dashed var(--ink);display:inline-block;flex:none"></span>Baseline total (applicable)</span>
          </div>
        </div></div>`;
    } else {
      const tsLegend=`${tsBasis==="stock"
        ? `<span class="key"><span style="width:14px;height:0;border-top:3px dashed var(--ink);display:inline-block;flex:none"></span>Baseline (whole stock)</span>`
        : `<span class="key"><span style="width:14px;height:0;border-top:3px dashed var(--ink-3);display:inline-block;flex:none"></span>each measure's own baseline (dashed, same color)</span>`}
        ${measKeyLegend(measChosen())}`;
      h+=`<div class="panel"><h2>Average hourly electricity demand — baseline vs each measure —
          ${st} — MW <span class="badge">${tsBas[1]}</span>
          ${tsBasis==="own"?`<span class="badge" style="color:var(--bad)">line heights not
            comparable between measures</span>`:""}
          ${groupControls(`gts-elec-${st}`)}</h2>
        <p class="note">${tsBasis==="stock"
          ? `Every line covers the whole stock: a measure's line is the stock baseline plus its own
             change, so the lines are directly comparable and the dashed line is their common
             baseline.`
          : `Each measure over its OWN applicable buildings, with that measure's own baseline as a
             dashed line in the same color — the gap between a color's solid and dashed lines is
             that measure's savings. Line heights are NOT comparable between measures, because the
             populations differ.`} Click a measure in the legend to drop it.</p>
        <div class="ami-wrap">
          <div class="ami-grid" id="mts-elec-${st}"></div>
          <div class="ami-legend">${tsLegend}</div>
        </div></div>
        <div class="panel"><h2>Average hourly demand by end use and season — ${st} — MW
          <span class="badge">${tsBas[1]}</span>
          <span class="badge">all days: 5/7 weekday, 2/7 weekend</span>
          ${groupControls(`gts-eu-${st}`)}</h2>
        <p class="note">Rows are end uses (upstream order), columns are seasons; each panel is a
        24-hour average over all days in that season. This is the end-use comparison from
        annual_average_by_state_and_enduse — despite that function's name the average is per
        season, not annual. Where a measure's line leaves the baseline says which end use moved,
        and when.</p>
        <div class="legend">${tsLegend}</div>
        <div style="display:grid;grid-template-columns:repeat(3,minmax(0,310px));gap:8px 12px;justify-content:start" id="mts-eu-${st}"></div>
        </div>`;
    }
  });
  $("#view").innerHTML=h;

  const locSel=$("#measLoc");
  if(locSel) locSel.addEventListener("change",e=>{
    state.measLoc=e.target.value; renderMeasuresTs(); syncHash(); });
  const MW=v=>(v===null||v===undefined)?null:v/1000;
  const tsLegendItems=(stack,lines)=>(stack?enduseLegendItemsVisible():[]).concat(lines);
  shown.forEach(st=>{
    const rows=MEAS.ts[st];
    const get=(up,sn,d)=>rows.filter(r=>String(r.upgrade)===String(up)&&r.season===sn
      &&(d?r.day_type===d:true));
    if(state.measView==="single"&&sel.length){
      const mm=sel[0];
      [["elec","elec_kwh",true],["gas","gas_kwh",false]].forEach(([slug,col,doStack])=>{
        const g=$(`#mts-${slug}-${st}`);
        // two-pass so every panel in this grid shares one y scale
        const pend=[];
        SEASONS.forEach(sn=>["Weekday","Weekend"].forEach(d=>{
          const meas=get(mm.up,sn,d).sort((a,b)=>a.hour-b.hour);
          if(!meas.length) return;
          const baseBy={};
          get("base_"+mm.up,sn,d).forEach(r=>baseBy[r.hour]=r[col]);
          const stackKeys=doStack?euOrderVisible().filter(k=>meas.some(p=>p["raw_"+k]!=null)):[];
          const sub=meas.map(p=>{
            const eu={}; stackKeys.forEach(k=>eu[k]=MW(p["raw_"+k]));
            return {hour:p.hour, comstock:MW(p[col]), rawComstock:MW(p[col]),
              ami:null, rawAmi:null, eu,
              mtot:MW(p[col]), btot:MW(baseBy[p.hour]??null)};
          });
          const box=document.createElement("div");
          box.className="chartbox";
          box.innerHTML=`<div class="head"><h3>${sn} · ${d}</h3></div><div class="chart"></div>`;
          g.appendChild(box);
          pend.push({box, sub,
            opts:{title:`${sn} ${d}`, stack:doStack, stackKeys, baseLabel:"Measure total",
             yLabel:slug==="gas"?"MW thermal":"MW",
             extraLines:[{key:"mtot",color:"var(--ink)",dash:"",width:doStack?2.4:2,label:"Measure total"},
                         {key:"btot",color:"var(--ink)",dash:"7 4",width:2.4,label:"Baseline (applicable)"}],
             copy:{title:`${mm.up} ${mm.name} — ${st} ${sn} ${d} seasonal average (MW)`,
                   legend:(doStack?enduseLegendItemsExport():[]).concat(
                     [{color:"#1a1d1f",label:"Measure total",line:true},
                      {color:"#1a1d1f",label:"Baseline, applicable (dashed)",line:true,dash:true}])}}});
        }));
        const shared=sharedProfileMax(pend);
        pend.forEach(q=>profileChart(q.box.querySelector(".chart"), q.sub,
          {...q.opts, yMax:shared}));
        registerGroupContainer(`gts-${slug}-${st}`, `#mts-${slug}-${st}`,
          tsLegendItems(doStack,
            [{color:"#1a1d1f",label:"Measure total",line:true},
             {color:"#1a1d1f",label:"Baseline, applicable (dashed)",line:true,dash:true}]),
          `${mm.up} ${mm.name} — ${st} — average hourly `
            +`${slug==="gas"?"natural gas":"electricity"} demand `
            +`(${slug==="gas"?"MW thermal":"MW"})`, 2);
      });
    } else {
      // On the stock basis a measure's hourly line is re-based the same way the
      // annual bars are: whole stock + (measure - its own applicable baseline).
      // On the own basis each measure keeps its own population and carries its
      // own dashed baseline in the same color.
      const tsLines=key=>sel.map(mm=>({key:`m_${mm.up}`,color:mm.color,dash:"",
          width:1.8,label:mm.short}))
        .concat(tsBasis==="own"
          ? sel.map(mm=>({key:`b_${mm.up}`,color:mm.color,dash:"5 3",width:1.4,
              label:`${mm.short} baseline`}))
          : [{key:"btot",color:"var(--ink)",dash:"7 4",width:2.4,label:"Baseline (whole stock)"}]);
      const tsCopyLegend=()=>(tsBasis==="own"
          ? sel.flatMap(mm=>[{color:mm.color,label:mm.short,line:true},
              {color:mm.color,label:`${mm.short} baseline (dashed)`,line:true,dash:true}])
          : [{color:"#1a1d1f",label:"Baseline, whole stock (dashed)",line:true,dash:true}]
              .concat(sel.map(mm=>({color:mm.color,label:mm.short,line:true}))));
      const g=$(`#mts-elec-${st}`);
      const pred=tsBasis==="own"?null:basisPred(tsBasis, sel);
      const pend2=[];
      SEASONS.forEach(sn=>["Weekday","Weekend"].forEach(d=>{
        const build=col=>{
          const series={};
          if(!hasTsMask){
            // No masks: read the per-measure and baseline scenarios directly.
            // TS_BASES is already restricted to stock/own in this case, so
            // union and intersection cannot be selected here.
            if(tsBasis==="own"){
              sel.forEach(mm=>{
                series[`m_${mm.up}`]=tsRaw(st,sn,d,col,mm.up);
                series[`b_${mm.up}`]=tsRaw(st,sn,d,col,`base_${mm.up}`);
              });
            } else {
              series.btot=tsRaw(st,sn,d,col,"0");
              sel.forEach(mm=>{
                series[`m_${mm.up}`]=tsCombine(
                  tsRaw(st,sn,d,col,"0"), tsRaw(st,sn,d,col,`base_${mm.up}`),
                  tsRaw(st,sn,d,col,mm.up));
              });
            }
          } else if(tsBasis==="own"){
            sel.forEach(mm=>{
              const ok=mk=>(mk & measBit(mm.up))!==0;
              series[`m_${mm.up}`]=tsSeries(st,sn,d,col,tsScenFor(mm.up),ok);
              series[`b_${mm.up}`]=tsSeries(st,sn,d,col,tsBaseScen,ok);
            });
          } else {
            series.btot=tsSeries(st,sn,d,col,tsBaseScen,pred);
            sel.forEach(mm=>
              series[`m_${mm.up}`]=tsSeries(st,sn,d,col,tsScenFor(mm.up),pred));
          }
          return series;
        };
        const series=build("elec_kwh");
        const hours=[...new Set(Object.values(series)
          .flatMap(s=>Object.keys(s).map(Number)))].sort((a,b)=>a-b);
        if(!hours.length) return;
        const sub=hours.map(hh=>{
          const o={hour:hh, comstock:null, rawComstock:null, ami:null, rawAmi:null, eu:{}};
          Object.entries(series).forEach(([k,s])=>o[k]=MW(s[hh]===undefined?null:s[hh]));
          return o;
        });
        const box=document.createElement("div");
        box.className="chartbox";
        box.innerHTML=`<div class="head"><h3>${sn} · ${d}</h3></div><div class="chart"></div>`;
        g.appendChild(box);
        pend2.push({box, sub,
          opts:{title:`${sn} ${d}`, yLabel:"MW",
           extraLines:tsLines("elec"),
           copy:{title:`${st} — ${sn} ${d} electricity, measure comparison, ${tsBas[1].toLowerCase()} (MW)`,
                 legend:tsCopyLegend()}}});
      }));
      const shared2=sharedProfileMax(pend2);
      pend2.forEach(q=>profileChart(q.box.querySelector(".chart"), q.sub,
        {...q.opts, yMax:shared2}));
      registerGroupContainer(`gts-elec-${st}`, `#mts-elec-${st}`,
        tsCopyLegend(), `${st} — average hourly electricity demand, ${tsBas[1].toLowerCase()} (MW)`, 2);
      const ge=$(`#mts-eu-${st}`);
      // tsSeries with day_type null does the upstream all-days mix (5/7
      // weekday + 2/7 weekend) internally.
      /* Scale shared across the SEASONS of one end use — a row of this grid —
         but NOT across end uses, which differ by orders of magnitude and would
         flatten the small ones into the baseline. */
      ENDUSE_ROWS.filter(e=>rows.some(r=>r["raw_"+e]!=null)).forEach(e=>{
        const pendE=[];
        SEASONS.forEach(sn=>{
          const col="raw_"+e;
          const series={};
          if(tsBasis==="own"){
            sel.forEach(mm=>{
              const ok=mk=>(mk & measBit(mm.up))!==0;
              series[`m_${mm.up}`]=tsSeries(st,sn,null,col,tsScenFor(mm.up),ok);
              series[`b_${mm.up}`]=tsSeries(st,sn,null,col,tsBaseScen,ok);
            });
          } else {
            series.btot=tsSeries(st,sn,null,col,tsBaseScen,pred);
            sel.forEach(mm=>
              series[`m_${mm.up}`]=tsSeries(st,sn,null,col,tsScenFor(mm.up),pred));
          }
          const sub=[...Array(24).keys()].map(h2=>{
            const o={hour:h2, comstock:null, rawComstock:null, ami:null, rawAmi:null, eu:{}};
            Object.entries(series).forEach(([k,s])=>o[k]=MW(s[h2]===undefined?null:s[h2]));
            return o;
          });
          if(!sub.some(p=>Object.keys(series).some(k=>p[k]!=null))) return;
          const box=document.createElement("div");
          box.className="chartbox";
          box.innerHTML=`<div class="head"><h3>${sn}: ${e.replace(/_/g," ")}</h3></div><div class="chart"></div>`;
          ge.appendChild(box);
          pendE.push({box, sub,
            opts:{title:`${sn} ${e}`, yLabel:"MW",
             extraLines:tsLines(e),
             copy:{title:`${st} — ${e.replace(/_/g," ")} ${sn} (all days, ${tsBas[1].toLowerCase()}, MW)`,
                   legend:tsCopyLegend()}}});
        });
        const sharedE=sharedProfileMax(pendE);
        pendE.forEach(q=>profileChart(q.box.querySelector(".chart"), q.sub,
          {...q.opts, yMax:sharedE}));
      });
      registerGroupContainer(`gts-eu-${st}`, `#mts-eu-${st}`, tsCopyLegend(),
        `${st} — average hourly demand by end use and season, ${tsBas[1].toLowerCase()} (MW)`, 3);
    }
  });
  wireMeasControls(renderMeasuresTs);
  wireEnduseLegend(renderMeasuresTs);
  wireGroups();
}

function amiStackLegendHTML(){
  // Clickable, like the measure legends: hiding a dominant end use is how you
  // see the shape of the rest of the stack.
  const hid=euHidden();
  return D.enduseOrder.slice().reverse().map(k=>
    `<span class="key" data-eu="${k}" role="button" aria-pressed="${!hid.has(k)}"
      title="click to hide or show this end use"><span class="sw"
      style="background:${D.enduseColors[k]}"></span>${k.replace(/_/g," ")}</span>`).join("")
    + (D.enduseOrder.some(k=>hid.has(k))
      ? `<span class="key" data-eu="__all__" role="button" aria-pressed="true"
         style="cursor:pointer;font-weight:600">show all</span>` : "");
}

/* Reference files by NAME, not by absolute path. Which reference was used is
   provenance worth showing; the absolute path under someone's home directory is
   not, and this HTML is a single file meant to be sent to people — it was
   carrying a username and a folder layout with it. Stripped in build_payload so
   the path never enters the file; this is the display-side counterpart. */
const refName=v=>String(v).replace(/^.*[\/]/,"");

/* ================= Design parameters =================
   What the model was TOLD to do, before arguing about what it produced.
   Every metric arrives with its own COVERAGE, because these parameters do not
   all apply to every building: most of the stock's floor area has no central
   air system, so a fan figure quoted stock-wide would be a different number
   about a different population. Coverage is on each metric's own weighting
   basis - floor area for an intensity, buildings for a per-building value. */
/* Rehydrate the columnar, dictionary-encoded design-parameter frame into the
   array of objects the renderer expects. Packed, it is about a third the size:
   as an array of objects the repeated key names alone were larger than the
   numbers they labelled. */
function dpUnpack(P){
  if(!P || !P.n) return [];
  const out=new Array(P.n);
  for(let i=0;i<P.n;i++){
    const o={};
    P.sCols.forEach((c,j)=>{ const k=P.s[j][i]; o[c]=k<0?null:P.dict[c][k]; });
    P.nCols.forEach((c,j)=>{ o[c]=P.v[j][i]; });
    out[i]=o;
  }
  return out;
}
const DP = dpUnpack(D.designParams);
/* Rehydrated once at load, same as the design-parameter frame. Crossing every
   breakdown with building type makes this table ~8,000 rows, which is why it
   arrives packed. */
const QUANT = dpUnpack(D.quantiles);
/* Metric descriptions are stored once and joined here: repeated on every value
   row they were 42% of this tab's payload, which is what made crossing by
   building type unaffordable. */
const DP_META = {};
(D.designParamsMeta||[]).forEach(m=>{ DP_META[m.metric]=m; });
const dpMeta = k => DP_META[k] || {metric:k, name:k, group:"", unit:"", note:""};
const DP_GROUPS = ["Loads","Ventilation & setpoints","Fans & pumps","Envelope",
                   "Water heating","Comfort"]
  .filter(g=>(D.designParamsMeta||[]).some(m=>m.group===g));
/* Building types that actually have a cross-tab. State is not crossed with
   building type -- 51 x 15 would dominate the file -- so the state map is
   offered only in the all-types view. */
const DP_BTYPES = [...new Set(DP.filter(r=>r.btype&&r.btype!=="All").map(r=>r.btype))].sort();
const dpBtype = () => (state.type!==CROSS && DP_BTYPES.includes(state.type))
  ? state.type : "All";
const DP_DIM_LABELS = [["building_type","Building type"],["vintage","Vintage"],
                       ["census_division","Census division"],["state","State"],
                       ["hvac_system","HVAC system"],["climate_zone","Climate zone"]];
/* Offered breakdowns depend on the building-type filter, and are read from the
   data rather than assumed. Within one type, "Building type" is meaningless and
   "State" was deliberately not crossed, so neither is offered — listing a
   breakdown that would render nothing is worse than not listing it. */
function dpDims(){
  const bt=dpBtype();
  return DP_DIM_LABELS.filter(d=>DP.some(r=>r.dimension===d[0]&&(r.btype||"All")===bt));
}
/* RUNS, not ALL_RUNS: this is what makes the header "compare" checkbox reach
   this tab. Reading the unfiltered list here meant the tab rendered the two-run
   form no matter what the checkbox said. Everything downstream — the per-run
   columns, the difference column, the chart series and the legend — is derived
   from this, so narrowing it here narrows all of them. */
const dpRuns = () => {
  const sel = RUNS.map(r=>r.key).filter(k=>DP.some(r=>r.run===k));
  if (sel.length) return sel;
  /* The selected run has no design-parameter rows at all. assess.py logs a
     warning and `continue`s past a run whose design-params query throws, so DP
     can carry the OTHER release and not this one. Returning [] here would blank
     a tab that has data in it, so fall back to whatever DP actually holds --
     better a labelled run the reader did not ask for than an empty table that
     implies the parameters were never computed. */
  return displayOrder(ALL_RUNS).map(r=>r.key).filter(k=>DP.some(r=>r.run===k));
};
const dpNum = v => (v===null||v===undefined||v===""||Number.isNaN(Number(v)))
  ? null : Number(v);
const dpDec = v => Math.abs(v)>=100 ? 0 : Math.abs(v)>=10 ? 1 : Math.abs(v)>=1 ? 2 : 3;

/* A state TILE GRID rather than real geography: it reads as well as a
   choropleth for 51 cells, needs no embedded boundary data in a file that is
   already 27 MB, and cannot imply that a state's area means anything. */
const STATE_GRID={AK:[0,0],ME:[0,10],VT:[1,9],NH:[1,10],WA:[1,1],ID:[1,2],MT:[1,3],
  ND:[1,4],MN:[1,5],IL:[1,6],WI:[1,7],MI:[1,8],NY:[2,9],MA:[2,10],OR:[2,1],NV:[2,2],
  WY:[2,3],SD:[2,4],IA:[2,5],IN:[2,6],OH:[2,7],PA:[2,8],NJ:[3,9],CT:[3,10],CA:[3,1],
  UT:[3,2],CO:[3,3],NE:[3,4],MO:[3,5],KY:[3,6],WV:[3,7],VA:[3,8],MD:[4,9],RI:[4,10],
  AZ:[4,2],NM:[4,3],KS:[4,4],AR:[4,5],TN:[4,6],NC:[4,7],SC:[4,8],DE:[5,9],
  OK:[5,4],LA:[5,5],MS:[5,6],AL:[5,7],GA:[5,8],HI:[6,0],TX:[6,4],FL:[6,9],DC:[6,10]};

const dpRows = (group, dim) => {
  const bt=dpBtype();
  return DP.filter(r=>r.dimension===dim && (r.btype||"All")===bt
                      && dpMeta(r.metric).group===group);
};
// metrics in a group, in definition order, from the dictionary
const dpMetricsIn = group => (D.designParamsMeta||[]).filter(m=>m.group===group);
// the one national row for a metric under the current building-type filter
const dpNational = (metric, run) => DP.find(r=>r.dimension==="none"
  && (r.btype||"All")===dpBtype() && r.metric===metric && r.run===run);

function dpTable(group){
  const runs=dpRuns(), mets=dpMetricsIn(group);
  if(!mets.length) return '<p class="note">No parameters in this group.</p>';
  const other=runs.find(k=>k!==PRIMARY);
  const bt=dpBtype();
  const nMean=runs.length+(other?1:0);
  let t=`<div class="scroll"><table><thead>
    <tr><th rowspan="2">Parameter</th><th rowspan="2">Unit</th>
      <th colspan="${nMean}" style="text-align:center">weighted mean</th>
      <th colspan="2" style="text-align:center">${runShort(PRIMARY)} across models
        <span style="font-weight:400;color:var(--ink-3)">(unweighted)</span></th>
      <th rowspan="2">applies to</th></tr>
    <tr>
    ${runs.map(k=>`<th>${runShort(k)}</th>`).join("")}
    ${other?`<th>${runShort(PRIMARY)} − ${runShort(other)}</th>`:""}
    <th>median (p50)</th><th>p10–p90</th></tr></thead><tbody>`;
  mets.forEach(m=>{
    const byRun={};
    runs.forEach(k=>{ byRun[k]=dpNational(m.metric,k); });
    const p=byRun[PRIMARY]||{};
    const vP=dpNum(p.wmean);
    const vO=(other&&byRun[other])?dpNum(byRun[other].wmean):null;
    const d=(vP!==null&&vO!==null)?vP-vO:null;
    const cov=dpNum(p.coverage_pct);
    const low=cov!==null&&cov<90;
    t+=`<tr><td>${m.name}${m.note?` <span class="badge" title="${
        String(m.note).replace(/"/g,"&quot;")}">i</span>`:""}</td>
      <td style="color:var(--ink-3)">${m.unit}</td>
      ${runs.map(k=>{ const r=byRun[k]; const v=r?dpNum(r.wmean):null;
        return `<td>${v===null
          ? absentTag("notPublished", `${runShort(k)} does not carry the columns this parameter needs`)
          : fmt(v,dpDec(v))}</td>`;}).join("")}
      ${other?`<td>${d===null?absentTag("noValue","one of the two runs has no value for this parameter"):(()=>{
        const dec=dpDec(d), txt=fmt(d,dec);
        // rounds to zero at this precision: a signed "-0.000" reads as a
        // direction of change that the number does not actually support
        const zero=Number(String(txt).replace(/[^0-9.-]/g,""))===0;
        return `<span class="cell" style="background:${zero?"transparent":diffColor(d)}">${
          zero?"0":(d>0?"+":"")+txt}</span>`;})()}</td>`:""}
      <td>${dpNum(p.p50)===null?absentTag("noValue"):fmt(dpNum(p.p50),dpDec(dpNum(p.p50)))}</td>
      <td style="color:var(--ink-3)">${dpNum(p.p10)===null
        ? (bt==="All" ? absentTag("noValue")
            : absentTag("stockWideOnly","The decile spread is computed across the whole stock, not within one building type"))
        :`${fmt(dpNum(p.p10),dpDec(dpNum(p.p10)))} – ${fmt(dpNum(p.p90),dpDec(dpNum(p.p90)))}`}</td>
      <td${low?' style="color:var(--bad)"':""}>${cov===null?absentTag("noValue")
        :`${fmt(cov,0)}% of ${m.coverage_basis||"buildings"}`}</td></tr>`;
  });
  return t+"</tbody></table></div>";
}

/* ---------- main heating fuel vs CBECS, by census division ----------
   The one design input with a CBECS counterpart, so it gets a comparison the
   other parameters cannot have. Read heating_fuel.py for the crosswalk: CBECS
   records seven independent per-fuel flags (single-choice in practice, checked
   at build time), splits district heat into steam and hot water where ComStock
   has one category, and carries a Wood category ComStock cannot represent.
   Shares are over HEATED floor area because ComStock assigns a heating fuel to
   every model and so has no unheated stock to report. */
const HF = dpUnpack(D.heatingFuel);
const HF_PROV = D.heatingFuelProv || {};
const HF_GROUP = "Heating fuel vs CBECS";
const HF_FUELS = ["Natural gas","Electricity","District heating",
                  "Fuel oil","Propane","Wood"];
/* Keyed to the palette the rest of the dashboard uses for the same fuels, so a
   reader who has learnt orange = gas here does not have to relearn it there.
   Wood has no counterpart upstream and takes a neutral tone of its own. */
const HF_COLORS = {"Natural gas":FUEL_COLORS.natural_gas,
  "Electricity":FUEL_COLORS.electricity, "District heating":FUEL_COLORS.district_heating,
  "Fuel oil":FUEL_COLORS.fuel_oil, "Propane":FUEL_COLORS.propane, "Wood":"#6E7B3F"};
const HF_CBECS = "cbecs_2018";
const HF_THIN_N = 30;        // CBECS records behind a whole cell
/* CBECS records behind ONE fuel. A cell total is too coarse on its own:
   Warehouse x New England holds 20 surveyed buildings split 7/6/4/3 across four
   fuels, so a +/-36 pp difference there rests on three-building shares. */
const HF_THIN_FUEL_N = 5;

// Datasets in reading order: the reference first, then the releases oldest-last,
// matching the left-to-right convention used everywhere else on the page.
const hfSeries = () => [{run:HF_CBECS, label:"CBECS 2018", color:"var(--ink-2)"}]
  .concat(RUNS.map(r=>({run:r.key, label:runShort(r.key), color:runColor(r.key)})))
  .filter(s=>HF.some(r=>r.run===s.run));

const hfRows = (btype, dim) =>
  HF.filter(r=>r.btype===btype && r.dimension===dim);

/* Divisions present for the current scope, in a fixed geographic-ish order so
   the small multiples do not reshuffle when the building type changes. */
const HF_DIV_ORDER = ["New England","Middle Atlantic","East North Central",
  "West North Central","South Atlantic","East South Central","West South Central",
  "Mountain","Pacific"];
const hfDivisions = btype => {
  const have = new Set(hfRows(btype,"census_division").map(r=>r.category));
  return HF_DIV_ORDER.filter(d=>have.has(d))
    .concat([...have].filter(d=>!HF_DIV_ORDER.includes(d)).sort());
};

const hfShare = (rows, cat, run, fuel) => {
  const r = rows.find(x=>x.category===cat && x.run===run && x.fuel===fuel);
  return r ? dpNum(r.area_share_pct) : null;
};
// Records behind the whole CBECS cell. A division x building-type cell can rest
// on a single surveyed building, and a share read off one building is noise.
const hfCellN = (rows, cat) => {
  const r = rows.find(x=>x.category===cat && x.run===HF_CBECS);
  return r ? dpNum(r.cell_n) : null;
};
const hfFuelN = (rows, cat, fuel) => {
  const r = rows.find(x=>x.category===cat && x.run===HF_CBECS && x.fuel===fuel);
  return r ? dpNum(r.n) : null;
};

function hfBars(rows, cat, series){
  return series.map(s=>{
    const segs = HF_FUELS.map(f=>{
      const v = hfShare(rows, cat, s.run, f);
      /* null, not 0: a fuel a dataset cannot represent (Wood in ComStock) must
         draw no segment at all. A zero-height segment would key a colour the
         reader then hunts for in a bar that never had it. */
      return v===null ? null
        : {key:f, value:v, color:HF_COLORS[f], label:f};
    }).filter(Boolean);
    return {label:s.label, segs};
  }).filter(b=>b.segs.length);
}

/* One number per cell, coloured by size, so a nine-by-six matrix reads as a
   heat map without being a second chart. `diffColor` is the same ramp the gap
   tables use, so orange/blue already mean over/under to a returning reader. */
function hfDiffCell(src, cat, run, fuel){
  const cb = hfShare(src, cat, HF_CBECS, fuel);
  const v  = hfShare(src, cat, run, fuel);
  if(cb===null && v===null) return `<td>${absentTag("notApplicable",
    `Neither CBECS nor ${runShort(run)} reports ${fuel.toLowerCase()} in this region`)}</td>`;
  if(cb===null) return `<td>${absentTag("noneSurveyed",
    `${runShort(run)} models ${fuel.toLowerCase()} here; CBECS surveyed none`)}</td>`;
  if(v===null) return `<td>${absentTag("notApplicable",
    `CBECS reports ${fuel.toLowerCase()}; ${runShort(run)} cannot represent it`)}</td>`;
  const d = v-cb, fn = hfFuelN(src, cat, fuel);
  /* A difference measured against a handful of surveyed buildings is sampling
     noise however large it looks, so it is greyed rather than coloured -- a
     bright +36 that rests on three buildings is worse than no number. */
  const noisy = fn!==null && fn<HF_THIN_FUEL_N;
  const tip = `${fuel}: CBECS ${fmt(cb,1)}% vs ${runShort(run)} ${fmt(v,1)}%`
    + (fn!==null?` — ${fmt(fn,0)} CBECS record${fn===1?"":"s"}`:"");
  return `<td title="${tip}${noisy?" — too few to judge":""}">${noisy
    ? `<span style="color:var(--ink-3)">${(d>0?"+":"")+fmt(d,1)}*</span>`
    : `<span class="cell" style="background:${diffColor(d)}">${
        (d>0?"+":"")+fmt(d,1)}</span>`}</td>`;
}

/* THE regional view: every division against CBECS, all fuels, one screen. This
   replaced nine stacked-bar small multiples -- the bars showed each mix but made
   the comparison a memory exercise, and a 3 pp difference is invisible inside a
   100%-tall bar while being a large amount of building. */
function hfMatrix(btype){
  const divRows = hfRows(btype,"census_division");
  const natRows = hfRows(btype,"none");
  const runs = hfSeries().filter(s=>s.run!==HF_CBECS);
  if(!runs.length) return `<p class="note">Only CBECS is present, so there is
    nothing to difference against.</p>`;
  const divs = hfDivisions(btype);
  const fuels = HF_FUELS.filter(f=>HF.some(r=>r.fuel===f));

  const head = fuels.map(f=>`<th colspan="${runs.length}" style="text-align:center">
      <span class="sw" style="background:${HF_COLORS[f]}"></span>${f}</th>`).join("");
  const sub = fuels.map(()=>runs.map(s=>`<th>${s.label}</th>`).join("")).join("");
  const line = (cat, src, bold) => {
    const n = hfCellN(src, cat);
    const thin = n!==null && n<HF_THIN_N;
    return `<tr>${bold?`<td><b>${cat}</b></td>`:`<td>${cat}${thin
      ? ` <span class="badge" title="Only ${fmt(n,0)} CBECS records behind this whole row">n=${fmt(n,0)}</span>`
      : ""}</td>`}${fuels.map(f=>runs.map(s=>hfDiffCell(src,cat,s.run,f)).join("")).join("")}</tr>`;
  };
  return `<div class="scroll"><table><thead>
      <tr><th rowspan="2">Region</th>${head}</tr><tr>${sub}</tr></thead><tbody>
      ${line("National", natRows, true)}
      ${divs.map(d=>line(d, divRows, false)).join("")}
    </tbody></table></div>`;
}

/* The shares themselves, for when the difference is not the question. Region
   blocks of one row per dataset: reading down a fuel column inside a block is
   the comparison, which is why this beats a fuel-by-dataset grid that would be
   eighteen columns wide. */
function hfSharesTable(btype){
  const divRows = hfRows(btype,"census_division");
  const natRows = hfRows(btype,"none");
  const series = hfSeries();
  const divs = hfDivisions(btype);
  const fuels = HF_FUELS.filter(f=>HF.some(r=>r.fuel===f));
  const block = (cat, src) => series.map((s,i)=>
    `<tr>${i===0?`<td rowspan="${series.length}" style="vertical-align:middle">${
      cat}</td>`:""}
      <td><span class="sw" style="background:${s.color}"></span>${s.label}</td>
      ${fuels.map(f=>{
        const v = hfShare(src, cat, s.run, f);
        return `<td>${v===null
          ? absentTag("notApplicable", `${s.label} has no ${f.toLowerCase()} category`)
          : fmt(v,1)}</td>`;}).join("")}</tr>`).join("");
  return `<div class="scroll"><table><thead><tr>
      <th>Region</th><th>Dataset</th>
      ${fuels.map(f=>`<th><span class="sw" style="background:${
        HF_COLORS[f]}"></span>${f}</th>`).join("")}</tr></thead><tbody>
      ${block("National", natRows)}
      ${divs.map(d=>block(d, divRows)).join("")}
    </tbody></table></div>`;
}

function renderHeatingFuel(host){
  const btype = dpBtype();
  const scope = btype==="All" ? "all building types" : btype;
  const series = hfSeries();
  const nat = hfRows(btype,"none");
  if(!HF.length){
    host.innerHTML = `<div class="panel"><p class="note">No heating-fuel comparison in this
      assessment — it needs CBECS (<code>cbecs=</code>) and
      <code>skip_heating_fuel=False</code>.</p></div>`;
    return;
  }
  if(!nat.length){
    host.innerHTML = `<div class="panel"><p class="note">No heating-fuel rows for
      <b>${scope}</b>. This is a coverage gap in the reference or the release, not a model
      result.</p></div>`;
    return;
  }
  const fuels = HF_FUELS.filter(f=>HF.some(r=>r.fuel===f));
  const legend = fuels.map(f=>({color:HF_COLORS[f], label:f}));
  const unheated = dpNum(HF_PROV.unheated_area_share_pct);
  const multi = dpNum(HF_PROV.multiple_fuels);
  const runs = series.filter(s=>s.run!==HF_CBECS);
  const view = state.hfView==="shares" ? "shares" : "diff";

  /* ONE graphic, and it is the national mix: the question this tab exists to
     answer first is "does the stock burn what CBECS says it burns", which is a
     single three-bar comparison. Everything regional is tabular below, because
     nine more copies of this chart made the tab a scrolling exercise. */
  let h = `<div class="panel"><div class="head" style="margin:0">
      <h2 style="margin:0">Main heating fuel — ComStock vs CBECS 2018
      <span class="badge">${scope}</span>
      <span class="badge">share of heated floor area</span></h2></div>
    <p class="note">Floor-area weighted: each share is the percentage of <b>heated</b> square
    footage whose main heating fuel is that fuel, so a column sums to 100%.
    CBECS reports ${unheated===null?"some":fmt(unheated,1)+"% of"} floor area as having no main
    heating and it leaves both sides, because ComStock assigns a fuel to every model.
    CBECS's district steam and hot water are summed to match ComStock's single district category,
    and ComStock cannot represent <b>wood</b>.${multi?` <b>${fmt(multi,0)} CBECS records report
    more than one main heating fuel</b>, so its shares are not a strict partition.`:""}</p></div>`;

  h += `<div class="panel"><div class="head"><h2 style="margin-top:0">National mix
        <span class="badge">${scope}</span></h2></div>
    <div class="grid2">
      <div><h3>Fuel mix — % of heated floor area</h3><div id="hf-national"></div></div>
      <div><h3>Shares and difference from CBECS</h3><table><thead><tr><th>Fuel</th>
        ${series.map(s=>`<th>${s.label}</th>`).join("")}
        ${runs.map(s=>`<th>${s.label} − CBECS</th>`).join("")}</tr></thead><tbody>
        ${fuels.map(f=>{
          const cb = hfShare(nat,"National",HF_CBECS,f);
          return `<tr><td><span class="sw" style="background:${HF_COLORS[f]}"></span>${f}</td>
            ${series.map(s=>{const v=hfShare(nat,"National",s.run,f);
              return `<td>${v===null
                ? absentTag("notApplicable", `${s.label} has no ${f.toLowerCase()} category`)
                : fmt(v,1)+"%"}</td>`;}).join("")}
            ${runs.map(s=>{const v=hfShare(nat,"National",s.run,f);
              if(cb===null||v===null) return `<td>${v===null
                ? absentTag("notApplicable", `${s.label} cannot represent ${f.toLowerCase()}`)
                : absentTag("noneSurveyed", `CBECS surveyed no ${f.toLowerCase()}`)}</td>`;
              const d=v-cb;
              return `<td><span class="cell" style="background:${diffColor(d)}">${
                (d>0?"+":"")+fmt(d,1)}</span></td>`;}).join("")}</tr>`;}).join("")}
      </tbody></table></div></div></div>`;

  h += `<div class="panel"><div class="head" style="margin:0">
      <h2 style="margin:0">By census division <span class="badge">${scope}</span>
      <span class="badge">${view==="diff"?"percentage points vs CBECS":"shares, %"}</span></h2>
      <span class="spacer"></span>
      <div class="tabs" role="group" aria-label="Regional view" id="hfViewCtl">
        <button class="tab" data-hfv="diff" aria-selected="${view==="diff"}">Difference from CBECS</button>
        <button class="tab" data-hfv="shares" aria-selected="${view==="shares"}">Shares by dataset</button>
      </div></div>
    <p class="note">${view==="diff"
      ? `Each cell is <b>release − CBECS 2018</b> in percentage points of heated floor area;
         orange = the release heats more area with that fuel than CBECS does, blue = less. Hover
         any cell for both shares and the CBECS record count. A greyed <b>asterisk</b> value, or an
         <b>n=</b> badge on the region, means the reference is too thin there to judge — not that
         ComStock is wrong.`
      : `The shares themselves, one row per dataset within each region, so reading down a fuel
         column inside a region block is the comparison. <b>–</b> means that dataset has no such
         category.`}</p>
    ${view==="diff" ? hfMatrix(btype) : hfSharesTable(btype)}</div>`;

  host.innerHTML = h;

  stackedBarChart($("#hf-national"), hfBars(nat, "National", series),
    /* Bare "%" on the axis: the cell heading already says what the percentage is
       of, and the full phrase eats width in a half-panel column. The copy title
       still carries the whole statement, because an exported figure travels
       without the heading. */
    {height:300, targetWidth:400, segLabels:true, yLabel:"%",
     yMax:100, copy:{title:`National main heating fuel, share of heated floor area (%), ${scope}`,
                     legend}});
  document.querySelectorAll("[data-hfv]").forEach(b=>b.addEventListener("click",()=>{
    state.hfView=b.dataset.hfv; renderDesignParams(); syncHash(); }));
  wireGroups();
}

function renderDesignParams(){
  /* Groups offered on this tab, plus the heating-fuel comparison when that leg
     ran. It is a group rather than an extra section so the tab does not grow a
     fourth screen of scroll for a view most visits will not want. */
  const GROUPS = HF.length ? DP_GROUPS.concat([HF_GROUP]) : DP_GROUPS;
  if(!GROUPS.includes(state.dpGroup)) state.dpGroup=GROUPS[0];
  const group=state.dpGroup;
  const DIMS=dpDims();
  const dim=DIMS.some(d=>d[0]===state.dpDim)
    ? state.dpDim : (DIMS[0]||["vintage"])[0];
  const dimLab=(DIMS.find(d=>d[0]===dim)||[dim,dim])[1].toLowerCase();
  const mets=dpMetricsIn(group);
  const runs=dpRuns();
  const other=runs.find(k=>k!==PRIMARY);   // null in single-run mode
  const bt=dpBtype();
  const scope=bt==="All"?"all building types":bt;

  let h=`<div class="panel"><div class="head" style="margin:0">
      <h2 style="margin:0">Design parameters — the modelling inputs behind the results</h2></div>
    <p class="note">Model inputs across ${scope}, baseline scenario only. Each run column is a
    <b>weighted mean</b> on that parameter's own basis, named in <b>applies to</b> along with the
    share of stock it covers — a fan figure describes only buildings that have a central air
    system, not the whole stock. <b>median (p50)</b> and <b>p10–p90</b> are ${runShort(PRIMARY)}
    only and are <b>unweighted</b> — one vote per simulated model, not per building represented —
    so they will not agree with the weighted mean and are not the median building in the
    stock.${other?` The difference column is ${runShort(PRIMARY)} − ${runShort(other)} of the two
    weighted means.`:""}${bt==="All"?"":
    ` p10–p90 is computed stock-wide, so it is not shown for a single building type.`}</p>
    <div class="head" style="margin:10px 0 0"><span class="legend-title"
        style="margin:0 8px 0 0">Group</span>
      <div class="tabs" role="group" aria-label="Parameter group" id="dpGroupCtl">
        ${GROUPS.map(g=>`<button class="tab" data-dpg="${g}"
          aria-selected="${g===group}">${g}</button>`).join("")}</div></div></div>`;

  /* The heating-fuel group is a different KIND of view -- a share partition
     compared against CBECS, not a weighted mean compared against another
     release -- so it renders its own panels rather than being forced through
     dpTable and the metric grid. The intro panel and the group strip above stay,
     so the strip is still the way back to the other groups. */
  if(group===HF_GROUP){
    const shell=document.createElement("div");
    $("#view").innerHTML=h;
    $("#view").appendChild(shell);
    renderHeatingFuel(shell);
    document.querySelectorAll("[data-dpg]").forEach(b=>b.addEventListener("click",()=>{
      state.dpGroup=b.dataset.dpg; renderDesignParams(); syncHash(); }));
    return;
  }

  h+=`<div class="panel"><h2 style="margin-top:0">${group} — national
      <span class="badge">${scope}</span>
      <span class="badge">${runs.map(runShort).join(" vs ")}</span></h2>
    ${dpTable(group)}</div>`;

  h+=`<div class="panel"><div class="head" style="margin:0">
      <h2 style="margin:0">${group} by breakdown</h2></div>
    <div class="head" style="margin:10px 0 0"><span class="legend-title"
        style="margin:0 8px 0 0">Breakdown for the panels below</span>
      <div class="tabs" role="group" aria-label="Breakdown" id="dpDimCtl">
        ${DIMS.map(d=>`<button class="tab" data-dpd="${d[0]}"
          aria-selected="${d[0]===dim}">${d[1]}</button>`).join("")}</div></div></div>`;

  h+=`<div class="panel"><div class="head"><h2 style="margin-top:0">${group} by ${dimLab}
      <span class="badge">${scope}</span><span class="badge">weighted mean</span></h2>
      ${groupControls("gdp")}</div>
    <div class="legend">${runs.map(k=>swatch(runColor(k),runShort(k))).join("")}</div>
    <div class="grid3fit">${mets.map(m=>
      `<div><h3>${m.name} — ${m.unit}</h3><div id="dp-${m.metric}"></div></div>`)
      .join("")}</div></div>`;

  // state is not crossed with building type, so the map is all-types only
  if(dim==="state"&&mets.length&&bt==="All")
    h+=`<div class="panel"><h2 style="margin-top:0">${mets[0].name} by state — ${mets[0].unit}
        <span class="badge">${runShort(PRIMARY)} weighted mean</span>
        <span class="badge">tile grid, not to scale</span></h2>
      <div id="dp-map"></div></div>`;

  $("#view").innerHTML=h;

  const series=runs.map(k=>({key:k,label:runShort(k),color:runColor(k)}));
  mets.forEach(m=>{
    const rows=dpRows(group,dim).filter(r=>r.metric===m.metric);
    const cats=[...new Set(rows.map(r=>r.category))].sort();
    const data=cats.map(c=>{
      const values={};
      runs.forEach(k=>{
        const r=rows.find(x=>x.category===c&&x.run===k);
        values[k]=r?dpNum(r.wmean):null;    // null draws no bar; never a zero
      });
      return {label:c, values, ciLow:null, ciHigh:null, hatched:false};
    }).filter(r=>runs.some(k=>r.values[k]!==null));
    groupedBar($(`#dp-${m.metric}`), data, series,
      {height:250, compact:true, yLabel:m.unit,
       copy:{title:`${m.name} by ${dimLab} — weighted mean (${m.unit})`,
             legend:series.map(x=>({color:x.color,label:x.label}))}});
  });
  registerGroup("gdp", mets.map(m=>`dp-${m.metric}`), mets.map(m=>m.name),
    series.map(x=>({color:x.color,label:x.label})),
    `${group} by ${dimLab} — weighted means`, 3);

  if(dim==="state"&&mets.length&&bt==="All") renderStateTiles(mets[0]);

  document.querySelectorAll("[data-dpg]").forEach(b=>b.addEventListener("click",()=>{
    state.dpGroup=b.dataset.dpg; renderDesignParams(); syncHash(); }));
  document.querySelectorAll("[data-dpd]").forEach(b=>b.addEventListener("click",()=>{
    state.dpDim=b.dataset.dpd; renderDesignParams(); syncHash(); }));
  wireGroups();
}

function renderStateTiles(met){
  const host=$("#dp-map"); if(!host) return;
  const byState={};
  DP.filter(r=>r.dimension==="state"&&r.metric===met.metric&&r.run===PRIMARY)
    .forEach(r=>{ const v=dpNum(r.wmean);
      if(v!==null) byState[String(r.category).toUpperCase()]=v; });
  const vals=Object.values(byState);
  if(!vals.length){ host.innerHTML='<p class="note">No state values.</p>'; return; }
  const lo=Math.min(...vals), hi=Math.max(...vals);
  const CELL=40, GAP=3, COLS=11, ROWS=7;
  const W=COLS*(CELL+GAP)+40, H=ROWS*(CELL+GAP)+58;
  const svg=el("svg",{viewBox:`0 0 ${W} ${H}`, style:figStyle(W)});
  // sequential ramp on the run's own colour, so the map keys to the rest of the tab
  const base=runColor(PRIMARY);
  const n=parseInt(String(base).slice(1),16);
  const br=n>>16&255, bg=n>>8&255, bb=n&255;
  const mix=t=>{ const f=0.12+0.88*t;
    return `rgb(${Math.round(255-(255-br)*f)},${Math.round(255-(255-bg)*f)},${
      Math.round(255-(255-bb)*f)})`; };
  Object.keys(STATE_GRID).forEach(st=>{
    const rc=STATE_GRID[st], v=byState[st], has=v!==undefined;
    const x=20+rc[1]*(CELL+GAP), y=8+rc[0]*(CELL+GAP);
    const t=(has&&hi>lo)?(v-lo)/(hi-lo):0;
    const rect=el("rect",{x,y,width:CELL,height:CELL,rx:3,
      fill:has?mix(t):"var(--grid)", stroke:"var(--line)","stroke-width":1});
    if(has){
      rect.addEventListener("mousemove",ev=>showTip(
        `<b>${st}</b><div class="row"><span>${met.name}</span><span>${
          fmt(v,dpDec(v))} ${met.unit}</span></div>`,ev));
      rect.addEventListener("mouseleave",hideTip);
    }
    svg.appendChild(rect);
    const lab=el("text",{x:x+CELL/2,y:y+CELL/2-1,"text-anchor":"middle",
      style:`font-size:11px;font-weight:600;fill:${
        (has&&t>0.55)?"#fff":"var(--ink)"};pointer-events:none`});
    lab.textContent=st; svg.appendChild(lab);
    if(has){
      const val=el("text",{x:x+CELL/2,y:y+CELL/2+11,"text-anchor":"middle",
        style:`font-size:9px;fill:${
          t>0.55?"rgba(255,255,255,.85)":"var(--ink-3)"};pointer-events:none`});
      val.textContent=fmt(v,dpDec(v)); svg.appendChild(val);
    }
  });
  const sy=H-34;
  for(let i=0;i<=10;i++)
    svg.appendChild(el("rect",{x:20+i*22,y:sy,width:22,height:10,fill:mix(i/10)}));
  const t0=el("text",{x:20,y:sy+23,"text-anchor":"start",class:"ax"});
  t0.textContent=fmt(lo,dpDec(lo)); svg.appendChild(t0);
  const t1=el("text",{x:20+11*22,y:sy+23,"text-anchor":"end",class:"ax"});
  t1.textContent=fmt(hi,dpDec(hi)); svg.appendChild(t1);
  host.innerHTML="";
  attachChart(host, svg,
    {title:`${met.name} by state — ${met.unit} (${runShort(PRIMARY)})`, legend:[]});
}

function renderCoverage(){
  const c=D.coverage, man=D.manifest;
  let h=`<div class="panel"><h2>Runs compared — source tables and colors</h2><table class="wrap-cells"><tbody>
    ${(man.runs||[]).map(r=>`<tr><td><span class="sw" style="background:${r.color}"></span>
      ${r.label}${r.key===D.primaryRun?" <b>(primary)</b>":""}</td>
      <td style="font-size:12px">${r.md_table}${r.ts_table?"<br>"+r.ts_table:""}</td></tr>`).join("")}
    </tbody></table>
    ${Object.keys(man.dropped_runs||{}).length?`<p class="note"><b>Requested but not
      included:</b> ${Object.entries(man.dropped_runs).map(([k,why])=>
      `<b>${k}</b> — ${why}`).join("; ")}. This panel lists what the assessment COVERED;
      without this line a run that was asked for and could not be reached is
      indistinguishable from one that was never requested.</p>`:""}
    ${c.ami_skipped_reason?`<p class="note"><b>AMI skipped:</b> ${c.ami_skipped_reason}.</p>`:""}</div>`;

  /* AMI coverage is PER REGION. Flattening one region's slice into a single
     table made this tab understate the assessment: a building type with meters
     in four regions was listed as having no AMI data at all, so a reader would
     skip work that was possible. coverage.json already carries every region. */
  const regs=c.regions||{};
  const regKeys=Object.keys(regs).sort();
  const amiAll=(c.ami_regions_compared||regKeys);
  const rowFor=(o,k)=>((o||{})[k]||[]).join(", ")||"—";
  // Thin ComStock cells, each with its own model count. The count is the point:
  // "retail" tells a reader nothing, "retail (2)" tells them not to trust that
  // shape. These are DRAWN in the charts, not dropped, so naming them here is
  // the only thing separating a real profile from two buildings' worth of noise.
  const thinCs=(o)=>{
    const t=(o||{}).comstock_thin_sample_types||[], n=(o||{}).comstock_model_counts||{};
    return t.length ? t.map(bt=>`${bt}${n[bt]!==undefined?` (${n[bt]})`:""}`).join(", ") : "—";
  };
  h+=`<div class="panel"><h2>AMI coverage by region — which building types each region can test
      <span class="badge">${amiAll.length} region${amiAll.length===1?"":"s"} in this
      assessment</span></h2>
    ${regKeys.length
      ? `<p class="note">Every region is listed, not just the one the AMI tab happens to be
         showing. A type absent in one region may be well covered in another, so read across the
         row before concluding there is no metered evidence for it.</p>
         <div class="scroll"><table><thead><tr><th>Region</th><th>Types compared</th>
           <th>No AMI truth data</th><th>Skipped — thin AMI sample (&lt;3 buildings)</th>
           <th>Thin ComStock sample (&lt;${c.comstock_min_models_threshold||10} models)</th>
           <th>In AMI, absent from ComStock</th></tr></thead><tbody>
         ${regKeys.map(rk=>{
            const o=regs[rk]||{};
            return `<tr><td style="text-align:left"><b>${rk}</b>${
              rk===c.region?' <span class="badge">AMI tab default</span>':""}</td>
              <td style="text-align:left;font-size:12px">${rowFor(o,"compared_types")}</td>
              <td style="text-align:left;font-size:12px">${rowFor(o,"ami_missing_types")}</td>
              <td style="text-align:left;font-size:12px">${rowFor(o,"ami_thin_sample_types_skipped")}</td>
              <td style="text-align:left;font-size:12px">${thinCs(o)}</td>
              <td style="text-align:left;font-size:12px">${rowFor(o,"comstock_missing_types")}</td>
              </tr>`;}).join("")}
         </tbody></table></div>`
      : `<table class="wrap-cells"><tbody>
          <tr><td>AMI region</td><td>${c.region||absentTag("noValue")}</td></tr>
          <tr><td>Types compared against AMI</td><td>${(c.compared_types||[]).join(", ")||"none"}</td></tr>
          <tr><td>No AMI truth data</td><td>${(c.ami_missing_types||[]).join(", ")||"none"}</td></tr>
          <tr><td>Skipped — thin AMI sample (&lt;3 buildings)</td>
              <td>${(c.ami_thin_sample_types_skipped||[]).join(", ")||"none"}</td></tr>
          <tr><td>Thin ComStock sample (&lt;${c.comstock_min_models_threshold||10} models)</td>
              <td>${thinCs(c)}</td></tr>
          <tr><td>In AMI but absent from ComStock</td>
              <td>${(c.comstock_missing_types||[]).join(", ")||"none"}</td></tr>
        </tbody></table>`}
    ${c.ami_headline_region_note?`<p class="note"><b>Headline AMI numbers are one region, not a
      national result.</b> ${c.ami_headline_region_note}</p>`:""}
    ${c.ami_runs_skipped?`<p class="note">Runs without an AMI leg: ${
      JSON.stringify(c.ami_runs_skipped)}.</p>`:""}
    ${Object.values(c.ami_timeseries_clock||{}).includes("est")?`<p class="note"><b>Clock:</b> ${
      Object.entries(c.ami_timeseries_clock).filter(([,v])=>v==="est").map(([k])=>k).join(", ")
      } read a published-release table, which stores every building's timestamps in Eastern
      Standard Time; they were converted back to local standard time by state before comparison
      (split-zone states use their majority zone). AMI meters and crawled runs are already local.</p>`:""}</div>`;

  // Every measure scenario in the assessment, named: the measure tabs show a
  // truncated label, and a reader needs the full upgrade name and its share of
  // stock to know what was actually run.
  if(MEAS&&(MEAS.summary||[]).length){
    h+=`<div class="panel"><h2>Measure scenarios in this assessment
        <span class="badge">${MEAS.summary.length} upgrade${
          MEAS.summary.length===1?"":"s"}</span></h2>
      <p class="note">Applicability is membership of the upgrade's partition: a building absent
      from it — including one whose simulation failed — is treated as not applicable and held at
      baseline.</p>
      <div class="scroll"><table><thead><tr><th>Upgrade</th><th>Name (in.upgrade_name)</th>
        <th>Applicable stock</th><th>Models</th><th>Site savings (TBtu)</th>
        </tr></thead><tbody>
      ${MEAS.summary.map(r=>`<tr><td>${r.upgrade}</td>
        <td style="text-align:left"><span class="sw" style="background:${
          measColor(r.upgrade)}"></span>${r.upgrade_name}</td>
        <td>${fmt(r.pct_of_stock)}% (${fmt(r.weighted_bldgs/1e3,0)}k bldgs)</td>
        <td>${fmt(r.n_models,0)}</td><td>${fmt(r.site_savings_tbtu)}</td></tr>`).join("")}
      </tbody></table></div></div>`;
  }

  const a=c.category_audit||{}, keys=Object.keys(a), dims=c.dimensions||{};
  h+=`<div class="panel"><h2>Breakdown dimensions and their CBECS reference</h2><table class="wrap-cells"><tbody>
    ${Object.entries(dims).map(([k,v])=>`<tr><td>${v.label}</td><td>${v.cbecs_reference
      ?"compared against CBECS":"<b>ComStock only</b> — CBECS has no such column"}</td></tr>`).join("")}
    </tbody></table>`;
  h+= keys.length
    ? `<p class="note">Values outside the canonical category lists are reported here rather than
       dropped. The upstream plotting code passes those lists to seaborn's <code>order=</code>,
       which silently discards anything unlisted — so a spelling drift reads as "this group has no
       buildings" instead of as an error.</p>
       <table class="wrap-cells"><tbody>${keys.map(k=>`<tr><td>${k}</td><td>${
         (a[k].unexpected_values||[]).length?"unexpected: "+a[k].unexpected_values.join(", ")+". ":""}${
         (a[k].absent_values||[]).length?"absent from this run: "+a[k].absent_values.join(", "):""
       }</td></tr>`).join("")}</tbody></table>`
    : `<p class="note">Every category in every dataset matched the canonical lists.</p>`;
  h+=`</div>`;

  /* The absence vocabulary, in one place. Each token appears in tables above and
     names its own cause, so a reader can tell a reference gap from a release gap
     from a deliberate omission without guessing. */
  h+=`<div class="panel"><h2>What an empty cell means</h2>
    <p class="note">Every blank in every table says why it is blank, rather than a single
    catch-all. Hovering a cell adds the specifics for that row.</p>
    <div class="scroll"><table><thead><tr><th>Reads</th><th>Means</th></tr></thead><tbody>
      <tr><td>${absentTag("noValue")}</td><td>The number itself is absent for this cell — nothing
        was computed from the underlying rows.</td></tr>
      <tr><td>${absentTag("notPublished")}</td><td>That release's published tables do not carry the
        columns this figure needs. A gap in the source, not in the model.</td></tr>
      <tr><td>${absentTag("notApplicable")}</td><td>The category cannot exist for that dataset by
        construction — ComStock has no wood heating fuel, for instance.</td></tr>
      <tr><td>${absentTag("noneSurveyed")}</td><td>The reference holds zero records here, so there
        is nothing to compare against even though ComStock reports a value.</td></tr>
      <tr><td>${absentTag("stockWideOnly")}</td><td>The statistic was computed, but only across the
        whole stock — it is not meaningful at the narrower scope on screen.</td></tr>
      <tr><td>${absentTag("measureAbsent")}</td><td>That release does not contain this measure, so
        the row is missing rather than zero.</td></tr>
      <tr><td>${absentTag("noRecords")}</td><td>The current selection matches no rows at all.</td></tr>
    </tbody></table></div></div>`;

  h+=`<div class="panel"><h2>How to read this dashboard</h2><ul class="caveats">
    <li><b>Two questions organize every comparison.</b> (1) How does ${runLabel(D.primaryRun)}
    compare to the references — every "% vs CBECS" is that run minus CBECS, as a share of CBECS.
    (2) Where did it improve or worsen that comparison relative to the previous run — the
    scorecard arrows and "Δ gap" columns measure the change in the <i>absolute</i> gap, and the
    dashed comparison-run line on the AMI charts shows the same thing for shapes. Tables that show
    only question one say so.</li>
    <li><b>CBECS end uses are modeled.</b> EIA disaggregates end uses statistically; only fuel
    totals and floor area are surveyed. End-use bars are hatched to keep that visible.</li>
    <li><b>A CBECS null means "not surveyed", not zero</b> — except natural-gas EUI, where null
    means the building has no gas and is counted as zero so both sides describe all buildings.</li>
    <li><b>Inside the CI is not a gap.</b> Confidence intervals come from the CBECS jackknife
    replicate weights; AMI carries its own 80% interval, drawn as dashed lines on the profile
    charts.</li>
    <li><b>Weight basis.</b> The published run weight is the StockE apportionment weight, not
    scaled to CBECS, so floor area runs a few percent high across every type. Energy comparisons
    inherit that basis.</li>
    <li><b>Distributions have two weighting bases.</b> By buildings answers "what is a typical
    building?"; by floor area answers "where does the square footage sit?". They can disagree, and
    the upstream package mixes them (count-weighted boxplots, area-weighted histograms).</li>
    <li><b>AMI is electricity only</b>, from ${c.region||"one region"} in a specific year, compared
    against ComStock AMY2018. Hour alignment is first-pass: peak-hour and ramp metrics can be off by
    an hour. Its floor-area denominators are uncertain — prefer a normalized view when levels and
    shapes disagree. The normalized views use the same scalar divisors as the postprocessing script
    (day sum = 1, annual sum = 1), so end-use stacks stay intact in every view.</li>
    <li><b>Calibration is evidence, not a target.</b> Use it to locate and rank problems; justify a
    model change with the upstream data, and pre-register the expected impact before a trial.</li>
  </ul></div>`;

  h+=`<div class="panel"><h2>Sources and tool version</h2><table class="wrap-cells"><tbody>
    ${Object.entries(D.sources).map(([k,v])=>`<tr><td>${k}</td><td style="font-size:12px">${v}</td></tr>`).join("")}
    ${Object.entries(man.references||{}).map(([k,v])=>`<tr><td>${k}</td><td style="font-size:12px">${
      refName(v)}</td></tr>`).join("")}
    <tr><td>tool version</td><td>${D.toolVersion}</td></tr></tbody></table>
    <p class="note">Every number here comes from the CSVs in <code>metrics/</code>; the exact SQL is
    in <code>queries/</code>.</p></div>`;
  $("#view").innerHTML=h;
}

/* ---------- shell ---------- */
/* deep-linkable view state: #tab=annual&type=LargeOffice&ami=pepco... so a
   specific view can be shared by sending the URL */
const HASH_KEYS=["tab","type","amiMode","amiRegion","euiBasis","euiMetric","xDim","distDim",
                 "dpGroup","dpDim","hfView",
                 "rankDim","rankFuel","dimSig","rankSig","measView","measSel","measLoc",
                 "measDistGroup","measMulti","showCompare","measBasis","measPop",
                 "measCatGroup","euHidden","feHidden","measHidden"];
function syncHash(){
  const p=new URLSearchParams();
  // Unset state (e.g. amiRegion with no AMI regions) is left out rather than
  // written as the string "undefined".
  HASH_KEYS.forEach(k=>{ if(state[k]!==undefined&&state[k]!==null) p.set(k,String(state[k])); });
  history.replaceState(null,"","#"+p.toString());
}
function parseHash(){
  if(!location.hash) return;
  const p=new URLSearchParams(location.hash.slice(1));
  HASH_KEYS.forEach(k=>{
    if(!p.has(k)) return;
    const v=p.get(k);
    state[k]=(k==="dimSig"||k==="rankSig"||k==="showCompare") ? v==="true"
      : k==="measMulti" ? v.split(",").filter(u=>MEAS_LIST.some(m=>m.up===u))
      : k==="euHidden" ? v.split(",").filter(x=>(D.enduseOrder||[]).includes(x))
      // "enduse|fuel"; validated against both halves so a stale link cannot
      // hide a series that does not exist
      : k==="feHidden" ? v.split(",").filter(x=>{
          const [eu,f]=String(x).split("|");
          return (D.enduseOrder||[]).includes(eu) && FUEL_ORDER.includes(f); })
      : k==="measHidden" ? v.split(",").filter(u=>MEAS_LIST.some(m=>m.up===u))
      : v;
  });
  if(state.type!==CROSS&&!D.buildingTypes.includes(state.type)) state.type=CROSS;
  if(!AMI_REGIONS.includes(state.amiRegion))
    state.amiRegion=AMI_REGIONS.includes("pepco")?"pepco":AMI_REGIONS[0];
  // a stale link must not leave a selector pointing at nothing
  if(state.measView!=="single"&&state.measView!=="multi") state.measView="single";
  if(!DIST_GROUPS.some(g=>g[0]===state.measDistGroup)) state.measDistGroup="end_use";
  if(!CAT_GROUPS.some(g=>g[0]===state.measCatGroup)) state.measCatGroup="building_type";
  if(!availableBases().some(b=>b[0]===state.measBasis)) state.measBasis="stock";
  if(MEAS_LIST.length&&!MEAS_LIST.some(m=>m.up===state.measSel))
    state.measSel=MEAS_LIST[0].up;
  if(!state.measMulti.length) state.measMulti=MEAS_LIST.slice(0,3).map(m=>m.up);
  // never leave every chosen measure hidden
  if(state.measMulti.length&&state.measMulti.every(u=>(state.measHidden||[]).includes(u)))
    state.measHidden=[];
}

/* Not every view HAS a second run to show. The measure timeseries leg was only
   ever queried against the primary release (its frames carry no `run` column at
   all), the cross-region AMI agreement matrix likewise, and Coverage documents
   the whole assessment rather than a view of it. On those, the compare checkbox
   is inert — so say why instead of leaving a live-looking control that does
   nothing when clicked, which reads as a bug. */
function runToggleReason(){
  if(ALL_RUNS.length<2) return "";
  if(state.tab==="measT")
    return "The measure timeseries leg was run against "+runShort(PRIMARY)+" only, "
      +"so there is no second release to compare here.";
  if(state.tab==="coverage")
    return "Coverage documents the whole assessment, including every release in it.";
  if(state.tab==="ami"&&state.type===CROSS)
    return "The cross-region agreement matrix is computed for "+runShort(PRIMARY)+" only. "
      +"Pick a building type to compare releases.";
  return "";
}
function syncRunToggle(){
  const box=$("#cmpChk"); if(!box) return;
  const why=runToggleReason();
  box.disabled=!!why;
  const lab=box.closest("label");
  if(lab){
    lab.style.opacity=why?"0.45":"";
    lab.style.cursor=why?"default":"pointer";
    lab.title=why||"Show or hide the comparison run on every view";
  }
}

function setTab(t){
  state.tab=t;
  syncHash();
  // keep the header dropdown in sync when state.type was set programmatically
  // (e.g. clicking a scorecard row)
  if($("#type").value!==state.type) $("#type").value=state.type;
  document.querySelectorAll(".tab[data-tab]").forEach(b=>
    b.setAttribute("aria-selected", b.dataset.tab===t));
  $("#typeWrap").classList.toggle("hidden",
    t==="overview"||t==="coverage"||t==="measA"||t==="measT");
  ({overview:renderOverview, annual:renderAnnual, dist:renderDistributions,
    ami:renderAmi, coverage:renderCoverage, params:renderDesignParams,
    measA:renderMeasuresAnnual, measT:renderMeasuresTs})[t]();
  syncRunToggle();
  window.scrollTo({top:0, behavior:"instant"});
}
function init(){
  // Measure tabs first, then Coverage last: coverage is what you check before
  // or after reading a result, not a stop on the way through the analysis.
  const bar=document.querySelector('.tabs[role="tablist"]');
  const addTab=(k,l)=>{
    const b=document.createElement("button");
    b.className="tab"; b.setAttribute("role","tab"); b.dataset.tab=k; b.textContent=l;
    bar.appendChild(b);
  };
  if(MEAS){ addTab("measA","Measures · annual"); addTab("measT","Measures · timeseries"); }
  addTab("coverage","Coverage & caveats");
  const sel=$("#type");
  const cross=document.createElement("option");
  cross.value=CROSS; cross.textContent="All types — cross-cutting"; sel.appendChild(cross);
  D.buildingTypes.forEach(t=>{
    const o=document.createElement("option"); o.value=t; o.textContent=t; sel.appendChild(o);
  });
  sel.value=state.type;
  sel.addEventListener("change", e=>{ state.type=e.target.value; setTab(state.tab); });
  document.querySelectorAll(".tab[data-tab]").forEach(b=>
    b.addEventListener("click",()=>setTab(b.dataset.tab)));
  $("#theme").addEventListener("click",()=>{
    const cur=document.documentElement.getAttribute("data-theme");
    const next=cur==="dark"?"light":cur==="light"?"dark"
      :(matchMedia("(prefers-color-scheme: dark)").matches?"light":"dark");
    document.documentElement.setAttribute("data-theme", next);
    try{ localStorage.setItem("calib-theme", next); }catch(e){}
  });
  try{ const s=localStorage.getItem("calib-theme");
       if(s) document.documentElement.setAttribute("data-theme", s); }catch(e){}
  parseHash();
  sel.value=state.type;
  // comparison-run toggle: view every tab either with the run comparison or
  // as the standard single-run version
  if(ALL_RUNS.length>1){
    const cmp=ALL_RUNS.find(r=>r.key!==PRIMARY);
    const w=document.createElement("label");
    w.style.cssText="display:inline-flex;align-items:center;gap:6px;font-size:12.5px;"+
      "color:var(--ink-2);cursor:pointer;margin-right:10px";
    w.title="Show or hide the comparison run on every view";
    w.innerHTML=`<input type="checkbox" id="cmpChk"${state.showCompare?" checked":""}>`+
      `<span class="sw" style="background:${cmp.color}"></span>compare: ${cmp.key}`;
    document.querySelector(".controls").insertBefore(w, $("#theme"));
    $("#cmpChk").addEventListener("change",e=>{
      state.showCompare=e.target.checked;
      applyRunToggle(); setTab(state.tab);
    });
  }
  applyRunToggle();
  const tabs=["overview","annual","dist","ami"];
  if(DP.length) tabs.push("params"); else { const b=$("#paramsTab"); if(b) b.remove(); }
  tabs.push("coverage");
  if(MEAS) tabs.push("measA","measT");
  setTab(tabs.includes(state.tab)?state.tab:"overview");
}
init();
