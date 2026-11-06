# ComStock™, Copyright (c) 2025 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.
"""The stock allocation as a portable, self-describing file.

A stock allocation is the apportionment draw: for every (bootstrapped) building
in the stock estimate, the ComStock model that stands in for it, with the
building's geography and the weight that makes the model's floor area count as
the building's. `ComStock.create_allocated_weights` makes it with
`np.random.choice`, so every draw is different, and anything averaged over
models -- a weighted mean, a stock total by state -- moves with the draw even
when no model changed. Measured on two runs of one sample: only 0.2% of models
kept the same weight, and the median model's weight differed by 18%.

Two runs on the same sample should therefore share one draw, and a published
run's draw should be usable by anyone who plots it locally. This module holds
the pieces that make that safe, none of which need S3 or Athena:

  * the SAMPLE FINGERPRINT: a canonical hash of buildstock.csv, so "same sample"
    is a fact about the file, not a guess from the run name;
  * the PROVENANCE a draw carries in its parquet schema metadata, so a file
    that is passed around says what it was drawn for;
  * the CHECKS before a draw is reused: estimate, bootstrap coefficient and
    sample must match, and the model ids are reconciled and reported;
  * the SHARING PLAN a driver follows for a list of runs;
  * the MARKER that ties a derived cache (the bills) or an export to the draw
    it was built from, so a changed draw is noticed instead of inherited.

Polars ignores the metadata, so a draw file reads exactly as before.
"""

from __future__ import annotations

import dataclasses
import datetime
import hashlib
import json
import logging
import uuid

logger = logging.getLogger(__name__)

METADATA_KEY = b"comstock.allocation"
FILE_NAME = "cached_ComStock_alloc_wts.parquet"
# Inside a derived cache folder (the bills). Underscore-prefixed: Hive-style
# readers skip such names, so it never counts as data.
MARKER_NAME = "_allocation.json"
# Beside a run's S3 exports, NEVER inside the crawled prefix: the crawler would
# read it as data.
EXPORT_MARKER_NAME = "postprocessing_allocation.json"


class AllocationError(RuntimeError):
    """A draw cannot be used for this run; the message says why."""


# ---------------------------------------------------------------- provenance

@dataclasses.dataclass
class Provenance:
    """What a draw was made for. Written into the file; a copy keeps the id."""
    allocation_id: str            # identity of the DRAW; copies keep it
    created: str                  # ISO time of the draw
    drawn_for: str                # comstock_run_name the draw was made for
    drawn_for_version: str        # that run's cache folder version
    estimate_version: str         # stock estimate the buildings come from
    bootstrap_coefficient: int
    sample_hash: str              # sample_fingerprint() of the run's buildstock.csv
    sample_rows: int              # rows in that buildstock.csv
    n_models_drawn: int           # models given weight
    n_models_available: int       # successful baseline models offered to the draw
    n_rows: int                   # draw rows (bootstrapped buildings matched)
    comstockpostproc_version: str
    copied_from: str = ""         # the file this one was copied from, if any

    def to_json(self) -> str:
        return json.dumps(dataclasses.asdict(self), sort_keys=True)

    @classmethod
    def from_json(cls, text: str) -> "Provenance":
        data = json.loads(text)
        known = {f.name for f in dataclasses.fields(cls)}
        # a newer writer may add fields; an older reader keeps what it knows
        return cls(**{k: v for k, v in data.items() if k in known})

    def describe(self) -> str:
        s = (f"allocation {self.allocation_id[:8]} drawn for {self.drawn_for} on "
             f"{self.created[:16]} (estimate {self.estimate_version}, sample "
             f"{self.sample_hash[:8]}, {self.n_models_drawn:,} of "
             f"{self.n_models_available:,} models weighted, {self.n_rows:,} rows)")
        if self.copied_from:
            s += f", copied from {self.copied_from}"
        return s


def new_provenance(**fields) -> Provenance:
    """Provenance for a draw made now: a fresh id, the time, this package's version."""
    from .__version__ import __version__
    return Provenance(allocation_id=uuid.uuid4().hex,
                      created=datetime.datetime.now().isoformat(timespec="seconds"),
                      comstockpostproc_version=__version__, **fields)


# ----------------------------------------------------------------- the sample

def sample_fingerprint(buildstock_csv: str) -> tuple[str, int]:
    """sha256 of a buildstock.csv's content, and its row count.

    Every column is read as text and the frame is put in canonical order
    (columns by name, rows by the building id), so two files that hold the same
    sample hash the same whatever their row order, column order or line
    endings, and a single changed value changes the hash.
    """
    import polars as pl

    df = pl.read_csv(buildstock_csv, infer_schema_length=0)
    if not df.height or not df.width:
        raise AllocationError(f"{buildstock_csv} has no rows")
    key = next((c for c in ("Building", "sample_building_id") if c in df.columns), df.columns[0])
    df = df.select(sorted(df.columns)).sort(key)
    lines = df.select(pl.concat_str([pl.col(c).fill_null("") for c in df.columns],
                                    separator="\x1f")).to_series()
    h = hashlib.sha256()
    h.update(("\x1f".join(df.columns) + "\n").encode("utf-8"))
    for line in lines:
        h.update(line.encode("utf-8"))
        h.update(b"\n")
    return h.hexdigest(), df.height


# ------------------------------------------------------------------ the file

def _open(path: str, mode: str, fs=None):
    """A file handle for a local or s3:// path; `fs` is an fsspec filesystem if given."""
    if fs is not None:
        return fs.open(path, mode)
    import fsspec
    return fsspec.open(path, mode).open()


def exists(path: str, fs=None) -> bool:
    if fs is not None:
        return bool(fs.exists(path))
    import fsspec
    f, p = fsspec.core.url_to_fs(path)
    return bool(f.exists(p))


def write_allocation(df, path: str, prov: Provenance, fs=None) -> None:
    """Write a draw (a polars DataFrame) with its provenance in the schema metadata."""
    import pyarrow.parquet as pq
    table = df.to_arrow()
    meta = dict(table.schema.metadata or {})
    meta[METADATA_KEY] = prov.to_json().encode("utf-8")
    with _open(path, "wb", fs) as f:
        pq.write_table(table.replace_schema_metadata(meta), f)


def read_provenance(path: str, fs=None) -> Provenance | None:
    """The provenance a draw file carries, or None for a file written before
    provenance existed (a LEGACY draw). Raises if the file is absent."""
    import pyarrow.parquet as pq
    with _open(path, "rb", fs) as f:
        meta = pq.read_schema(f).metadata or {}
    raw = meta.get(METADATA_KEY)
    return Provenance.from_json(raw.decode("utf-8")) if raw else None


def copy_allocation(src: str, dst: str, prov: Provenance, fs_src=None, fs_dst=None) -> Provenance:
    """Copy a draw to another run's folder, keeping its id and recording where it came from."""
    import pyarrow.parquet as pq
    new = dataclasses.replace(prov, copied_from=str(src))
    with _open(src, "rb", fs_src) as f:
        table = pq.read_table(f)
    meta = dict(table.schema.metadata or {})
    meta[METADATA_KEY] = new.to_json().encode("utf-8")
    with _open(dst, "wb", fs_dst) as f:
        pq.write_table(table.replace_schema_metadata(meta), f)
    return new


def publish_draw(src: str, fs_src, dst_dir: str, fs_dst, name: str = FILE_NAME) -> str:
    """Copy a draw file byte for byte (provenance included) to another place --
    beside a run's S3 export, so anyone can adopt exactly these weights."""
    dst = f"{dst_dir.rstrip('/')}/{name}"
    with _open(src, "rb", fs_src) as fi, _open(dst, "wb", fs_dst) as fo:
        while True:
            chunk = fi.read(16 * 1024 * 1024)
            if not chunk:
                break
            fo.write(chunk)
    return dst


def published_draw_url(s3_base_dir: str, run: str, name: str = FILE_NAME) -> str:
    """Where a run's export publishes its draw: s3://<s3_base_dir>/<run>/<run>/<name>."""
    return f"s3://{s3_base_dir.strip('/')}/{run}/{run}/{name}"


def draw_model_ids(path: str, fs=None, id_col: str = "bldg_id") -> set[int]:
    """The models a draw gives weight to."""
    import polars as pl
    with _open(path, "rb", fs) as f:
        ids = pl.read_parquet(f, columns=[id_col]).get_column(id_col).unique()
    return {int(i) for i in ids.to_list()}


# ---------------------------------------------------------------- the checks

def mismatches(prov: Provenance, *, estimate_version: str, bootstrap_coefficient: int,
               sample_hash: str | None) -> list[str]:
    """Why a draw does NOT fit a run; empty when it does.

    The three facts a draw depends on: which buildings (the estimate and how
    many times each was bootstrapped) and which models (the sample)."""
    out = []
    if str(prov.estimate_version) != str(estimate_version):
        out.append(f"estimate {prov.estimate_version} in the draw, {estimate_version} here")
    if int(prov.bootstrap_coefficient) != int(bootstrap_coefficient):
        out.append(f"bootstrap coefficient {prov.bootstrap_coefficient} in the draw, "
                   f"{bootstrap_coefficient} here")
    if not prov.sample_hash:
        out.append("the draw was made without a sample fingerprint (its run's buildstock.csv was "
                   "not on disk), so it cannot be matched to any run")
    elif sample_hash is None:
        out.append("this run's buildstock.csv is not on disk, so its sample cannot be compared")
    elif prov.sample_hash != sample_hash:
        out.append(f"sample {prov.sample_hash[:8]} in the draw, {sample_hash[:8]} here "
                   "(a different buildstock.csv)")
    return out


@dataclasses.dataclass
class Reconciliation:
    """The draw's models against the run's successful baseline models."""
    shared: int
    only_in_draw: int     # weight the run cannot carry: the model failed or is absent here
    only_in_run: int      # models the draw never picked: no weight here

    def describe(self) -> str:
        s = f"{self.shared:,} models weighted"
        if self.only_in_draw:
            s += (f"; {self.only_in_draw:,} models the draw picked are not in this run "
                  "(failed or absent here), so their rows carry no results")
        if self.only_in_run:
            s += f"; {self.only_in_run:,} models in this run were not picked, so they have no weight"
        return s


def reconcile(draw_ids: set[int], run_ids: set[int]) -> Reconciliation:
    return Reconciliation(shared=len(draw_ids & run_ids),
                          only_in_draw=len(draw_ids - run_ids),
                          only_in_run=len(run_ids - draw_ids))


@dataclasses.dataclass
class AllocationStatus:
    """What a draw file is to a run: missing, unverified (legacy, no
    provenance), stale (provenance does not fit the run) or valid."""
    state: str
    path: str
    reasons: list[str] = dataclasses.field(default_factory=list)
    provenance: Provenance | None = None

    def describe(self) -> str:
        if self.state == "valid":
            return f"valid: {self.provenance.describe()}"
        if self.state == "missing":
            return "missing"
        return f"{self.state}: " + "; ".join(self.reasons)


def status_of(path: str, *, estimate_version: str, bootstrap_coefficient: int,
              sample_hash: str | None, fs=None) -> AllocationStatus:
    if not exists(path, fs):
        return AllocationStatus("missing", path)
    prov = read_provenance(path, fs)
    if prov is None:
        return AllocationStatus("unverified", path,
                                ["written before draws carried provenance, so it cannot be "
                                 "checked against this run"])
    bad = mismatches(prov, estimate_version=estimate_version,
                     bootstrap_coefficient=bootstrap_coefficient, sample_hash=sample_hash)
    if bad:
        return AllocationStatus("stale", path, bad, prov)
    return AllocationStatus("valid", path, [], prov)


# ----------------------------------------------------------- the sharing plan

@dataclasses.dataclass
class Decision:
    """What a driver does about one run's allocation."""
    run: str
    action: str          # draw | reuse | redraw | share | use
    source: str = ""     # the owner run (share) or the file (use)
    reason: str = ""

    def describe(self) -> str:
        return {
            "draw": "DRAW (no draw on disk)",
            "reuse": "REUSE own draw",
            "redraw": f"REDRAW: {self.reason}",
            "share": f"SHARE {self.source}'s draw" + (f" ({self.reason})" if self.reason else ""),
            "use": f"USE {self.source}",
        }[self.action]


def plan_allocations(runs: list[dict], review_run: str, reuse: bool = True) -> list[Decision]:
    """Who draws, who shares, who uses a given file. Pure, so a driver can log it
    before anything expensive starts.

    Each run is a dict: `run`; `estimate`; `sample_hash` (None when the sample
    could not be fingerprinted); `status` (an AllocationStatus for its own draw
    file); optional `allocation` (a file the entry asks to use, or the draw its
    export published) and `allocation_id` (that file's id, when known).

    Runs on one (estimate, sample) form a group and share one draw. The owner is
    the run under review when it is in the group, else the first listed: it
    reuses its own draw when that is valid and `reuse` is on, and draws
    otherwise; the others copy the owner's. A group in which entries name files
    uses ONE of them for every member -- the run under review's, else the first
    named -- and two files that are different draws in one group is an error. A
    run whose sample has no fingerprint is a group of its own. Owners come
    before their sharers in the result, so a driver can execute it in order.
    """
    groups: dict[tuple, list[dict]] = {}
    for r in runs:
        key = (str(r["estimate"]), r.get("sample_hash") or f"__alone__{r['run']}")
        groups.setdefault(key, []).append(r)

    out: list[Decision] = []
    for (estimate, sample), members in groups.items():
        named = [m for m in members if m.get("allocation")]
        # Two files are the same draw when their ids agree; without ids, only
        # the same path is.
        distinct = {m.get("allocation_id") or m["allocation"] for m in named}
        if len(distinct) > 1:
            raise AllocationError(
                f"runs {[m['run'] for m in named]} are on one sample but name different "
                f"draws {sorted(str(m['allocation']) for m in named)}; one draw per sample. "
                "Set rebuild=True on the runs whose tables should take the other draw, or "
                "name one file on every entry.")
        if named:
            chosen = next((m for m in named if m["run"] == review_run), named[0])
            out += [Decision(m["run"], "use", source=chosen["allocation"]) for m in members]
            continue
        owner = next((m for m in members if m["run"] == review_run), members[0])
        st = owner["status"]
        if st.state == "missing":
            out.append(Decision(owner["run"], "draw"))
        elif st.state == "valid" and reuse:
            out.append(Decision(owner["run"], "reuse"))
        elif st.state == "valid":
            out.append(Decision(owner["run"], "redraw", reason="REUSE_CACHES=False"))
        else:
            out.append(Decision(owner["run"], "redraw", reason=st.describe()))
        why = ("same sample and estimate" if not sample.startswith("__alone__") else "")
        out += [Decision(m["run"], "share", source=owner["run"], reason=why)
                for m in members if m is not owner]
    return out


# ------------------------------------------------------- derived-cache marker

def derived_is_current(marker_id: str | None, current_id: str | None) -> bool:
    """May a cache built from allocation `marker_id` serve a run whose draw is
    `current_id`? A legacy draw has no id and nothing can be compared, so the
    cache is taken as it is (the behaviour before markers existed). Once the
    draw has an id, the cache must carry the same one: a cache with no marker
    was built from some draw that cannot be identified, and is rebuilt."""
    if current_id is None:
        return True
    return marker_id == current_id


def write_marker(folder: str, allocation_id: str, fs=None, name: str = MARKER_NAME) -> None:
    body = json.dumps({"allocation_id": allocation_id,
                       "written": datetime.datetime.now().isoformat(timespec="seconds")})
    with _open(f"{folder.rstrip('/')}/{name}", "w", fs) as f:
        f.write(body)


def read_marker(folder: str, fs=None, name: str = MARKER_NAME) -> str | None:
    path = f"{folder.rstrip('/')}/{name}"
    if not exists(path, fs):
        return None
    with _open(path, "r", fs) as f:
        return json.loads(f.read()).get("allocation_id")
