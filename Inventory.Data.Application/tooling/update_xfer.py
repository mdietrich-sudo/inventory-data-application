"""Update ONLY the XFER-04 and XFER-07 sections of the reviewed Wonder Rule SQL Guide .docx.

Everything else in the file — including hand-added rows like "Jonny Signoff" — is left untouched.
SQL bodies are lifted from docs/rule-sql-guide.md so the Word doc matches the markdown exactly, and
re-highlighted with the same skylighting character styles pandoc used for the rest of the document.
"""
import io
import re
import sys

from docx import Document
from docx.oxml.ns import qn
from docx.text.paragraph import Paragraph
from docx.table import Table

sys.path.insert(0, "/private/tmp/claude-502/-Users-mikedietrich-Eliassen-Clients-Wonder-Group/0383dc5a-23ec-47aa-ac6b-1c65b9627330/scratchpad/dx")
import dxedit as dx
import skylight as sk

DOCX_IN, DOCX_OUT, MD = sys.argv[1], sys.argv[2], sys.argv[3]

md = io.open(MD, encoding="utf-8").read()
SQL = {}
for block in re.findall(r"```sql\n(.*?)```", md, re.S):
    SQL[block.split("\n")[0].strip()] = block.rstrip("\n")


def sql_for(first_line):
    for k, v in SQL.items():
        if k.startswith(first_line):
            return v
    raise LookupError(first_line)


doc = Document(DOCX_IN)
word_style, op_chars = sk.harvest(doc)
items = dx.body_items(doc)

H = lambda text: (lambda p: p.style.name.startswith("Heading") and text in p.text)
i04 = dx.find_item(items, H("XFER-04 · Transfer Order No Pick Activity"))
i07 = dx.find_item(items, H("XFER-07 · Transfer Picked"))
log = []

# ════════════════════════════ XFER-04 ════════════════════════════
sec = items[i04:i07]
P = lambda pred: next(o for o in sec if isinstance(o, Paragraph) and pred(o))
T = lambda n: [o for o in sec if isinstance(o, Table)][n]

# 1 — one-sentence summary
dx.write(P(lambda p: p.style.name == "Block Text"),
         "**In one sentence:** find Transfer Orders still in an early lifecycle status (not yet "
         "shipped, not cancelled) that have had **zero pick activity** more than **Y days** "
         "(default 2, **Admin-editable**) past the **scheduled delivery date** of the lines still "
         "awaiting a pick.")
log.append("XFER-04 summary")

# 2 — at-a-glance: new "The clock" row + refreshed "Live status"
glance = T(0)
rows = [glance.rows[i].cells[0].text.strip() for i in range(len(glance.rows))]
ri_live = rows.index("Live status")
dx.set_row(glance, ri_live, ["Live status",
    "🟢 **Live — runs daily.** Added 2026-08-17; re-anchored to the delivery date 2026-09-14 after "
    "data-analyst review. Current backlog: **266** (30-day lookback window) — was 497 on the "
    "order-date clock, so the change removed 231 not-yet-due flags."])
dx.insert_row_after(glance, ri_live - 1, ["The clock",
    "`expected_date` (delivery date) of the still-unpicked lines — **not** the order date. "
    "`order_date` is the fallback only when the TO carries no `expected_date`. See the write-up "
    "below."])
log.append("XFER-04 at-a-glance (+The clock row, Live status)")

# 3 — new subsection, inserted after the "The fix:" paragraph, before "### The SQL"
anchor = P(lambda p: p.text.startswith("The fix:"))
h3_tpl = P(lambda p: p.style.name == "Heading 3")
first_tpl = P(lambda p: p.style.name == "First Paragraph")
body_tpl = P(lambda p: p.style.name == "Body Text")
bullet_tpl = [o for o in dx.body_items(doc)
              if isinstance(o, Paragraph) and o.style.name == "Compact"
              and o._p.find(qn("w:pPr")).find(qn("w:numPr")) is not None
              and o._p.find(qn("w:pPr")).find(qn("w:numPr")).find(qn("w:numId")).get(qn("w:val")) == "13"][0]

cur = dx.clone_para(h3_tpl, anchor._p, "Why the clock runs off the delivery date, not the order date")
cur = dx.clone_para(first_tpl, cur._p,
    "Raised in the 2026-09-14 data-analyst review of this SQL: *\"some POs have multiple delivery "
    "dates, need a where clause that filters these, or all later lines will show up once the first "
    "lines are shipped.\"*")
cur = dx.clone_para(body_tpl, cur._p, "Two things were checked against live data:")
cur = dx.clone_para(bullet_tpl, cur._p,
    "**Multiple delivery dates per order is real, but rare on transfers.** In a 60-day window, "
    "**23 of 92,757** transfer orders carry more than one `expected_date` (max 2). It is far more "
    "common on **Purchase** POs — **612 of 5,654** (11%, up to 5 dates), which is why `PO-07` / "
    "`PO-08` already take `MAX(expected_date)` over their still-open lines. Example transfer: "
    "`VDC 5452`, wave 1 due 2026-08-30 (cancelled), wave 2 due **2026-09-15** (`PENDING`, 896 "
    "units, nothing shipped).")
cur = dx.clone_para(bullet_tpl, cur._p,
    "**The underlying defect — clocking from creation instead of delivery — was much bigger than "
    "the multi-date case.** Transfers are normally delivered the day after they are cut "
    "(`expected_date = order_date + 1` for 87,511 of 92,757), but a real tail is scheduled 5–14+ "
    "days out. On the order-date clock, **231 of 497** live candidates (46%) were flagged "
    "**before their delivery date had even passed** — every one of the 83 `VENDOR_ACCEPTED` "
    "orders and 131 of the 185 `PLANNED` ones, some scheduled six weeks out. Nothing *should* "
    "have been picked yet.")
cur = dx.clone_para(first_tpl, cur._p,
    "**The fix:** `due_date` = the **latest** `expected_date` across the lines still awaiting a "
    "pick, and the rule ages off `COALESCE(due_date, order_date)`. Taking the latest such date is "
    "what answers the analyst's point directly — once the first delivery wave ships, the "
    "later-dated wave governs the clock and cannot pull the order into the list before its own "
    "date arrives. Backlog went 497 → **266**; the 231 that dropped out were all not-yet-due.")
log.append("XFER-04 new subsection (heading + 3 paras + 2 bullets)")

# 4 — both SQL blocks
codes = [o for o in sec if isinstance(o, Paragraph) and o.style.name == "Source Code"]
sk.set_code(codes[0], sql_for("-- Catalog XFER-04"), doc, word_style, op_chars)
sk.set_code(codes[1], sql_for("-- XFER-04: current backlog"), doc, word_style, op_chars)
log.append("XFER-04 catalog + live SQL")

# 5 — walkthrough items 1, 3, 4
steps = [o for o in sec if isinstance(o, Paragraph) and o.style.name == "Compact"]
dx.write(steps[0], "`to_agg` — every Transfer Order, one row per `po`, with its most recent creation "
                   "date, the full set of distinct statuses seen across its lines, and `due_date`: "
                   "the **latest** `expected_date` among the lines still awaiting a pick.")
dx.write(steps[2], "`flagged` — `LEFT JOIN … WHERE p.po IS NULL` (no ledger pick), **and** none of "
                   "the order's statuses fall in the \"already advanced or dead\" list, **and** the "
                   "delivery date has passed by the threshold "
                   "(`COALESCE(due_date, order_date) < run_date - Y days` — so an order scheduled "
                   "for next week isn't flagged today), **and** it's recent enough to matter "
                   "(`order_date >= run_date - 30 days`, so the rule stays on the current backlog "
                   "rather than the full historical population).")
dx.write(steps[3], "`ranked` + final line — count, cap at 500, oldest-**due** first (the "
                   "longest-overdue orders surface first, same convention as PO-07).")
log.append("XFER-04 walkthrough steps 1/3/4")

# 6 — tables & columns
cols = T(1)
dx.set_row(cols, 2, ["`po_date_utc` (PO table)", "When the order was created.",
                     "Fallback clock when the TO carries no `expected_date`; also the 30-day "
                     "recency window."])
dx.set_row(cols, 3, ["`status` (PO table)", "The order's lifecycle status.",
                     "**The safety filter** — excludes dead and already-advanced orders (see "
                     "write-up above), and picks which lines `due_date` is measured over."])
dx.insert_row_after(cols, 1, ["`expected_date` (PO table)", "The line's scheduled delivery date.",
                              "**The clock** — `due_date`, the latest delivery date across the "
                              "still-unpicked lines, is the aging baseline."])
log.append("XFER-04 columns table (+expected_date row)")

# 7 — worked example
dx.write(P(lambda p: p.text.startswith("Live BigQuery, run date")), "Live BigQuery, run date 2026-09-14:")
ex = T(2)
for ri, vals in enumerate([
        ["Field", "Value"],
        ["`transfer_order`", "`PO-445621`"],
        ["`facility`", "Arcadia"],
        ["`to_status`", "`NOT_RECEIVED`"],
        ["`order_date`", "2026-08-19"],
        ["`days_since_order`", "26"]]):
    dx.set_row(ex, ri, vals)
dx.insert_row_after(ex, 2, ["`system`", "POMS"])            # after facility
dx.insert_row_after(ex, 5, ["`expected_date`", "2026-08-20"])  # after order_date
dx.insert_row_after(ex, 7, ["`days_since_expected`", "25"])    # after days_since_order
dx.insert_row_after(ex, 8, ["`breached_at`", "2026-08-22"])
why = P(lambda p: p.text.startswith("Why it’s flagged") or p.text.startswith("Why it's flagged"))
dx.write(why, "**Why it's flagged:** due for delivery on 2026-08-20, still in an early "
              "(`NOT_RECEIVED`) status 25 days later, and no Transfer Out ledger row has ever been "
              "recorded against it — well past the 2-day threshold. The breach date is delivery "
              "date + 2.")
dx.clone_para(why, why._p,
    "**And one that is no longer flagged:** a `VENDOR_ACCEPTED` transfer order created 2026-09-05 "
    "and scheduled for delivery 2026-10-29. On the old order-date clock it was flagged on "
    "2026-09-08 for \"no pick activity\"; nothing is supposed to be picked for another six weeks. "
    "231 of the 497 candidates on 2026-09-14 were of this kind.")
log.append("XFER-04 example table + why-flagged paragraphs")

# ════════════════════════════ XFER-07 ════════════════════════════
items = dx.body_items(doc)            # refresh: indices shifted
i07 = dx.find_item(items, H("XFER-07 · Transfer Picked"))
try:
    iend = dx.find_item(items, H("Transfer Warehouse In/Out Balance"))
except LookupError:
    iend = len(items)
sec = items[i07:iend]
P = lambda pred: next(o for o in sec if isinstance(o, Paragraph) and pred(o))
T = lambda n: [o for o in sec if isinstance(o, Table)][n]

dx.write(P(lambda p: p.style.name == "Block Text"),
         "**In one sentence:** find real Transfer Orders that **were** picked but have had **zero "
         "receiving activity** more than **Z days** (default 2, **Admin-editable**) after the "
         "receipt was **due** — the later of the first pick and the scheduled delivery date of the "
         "unreceived lines.")

glance = T(0)
rows = [glance.rows[i].cells[0].text.strip() for i in range(len(glance.rows))]
ri_live = rows.index("Live status")
dx.set_row(glance, ri_live, ["Live status",
    "🟢 **Live — runs daily.** Added 2026-08-17 (backlog was 0 then); delivery-date gate added "
    "2026-09-14 after data-analyst review. Current backlog: **58** (30-day lookback) — 61 on the "
    "pick-only clock, so the gate held back 3 not-yet-due orders."])
dx.insert_row_after(glance, ri_live - 1, ["The clock",
    "`GREATEST(first_pick, due_date)` — the later of the first pick and the latest `expected_date` "
    "across the lines with nothing received. Falls back to `first_pick` alone when there is no "
    "`expected_date`."])
log.append("XFER-07 summary + at-a-glance")

# new subsection, before the existing "Why this one doesn't need..." heading
nxt = P(lambda p: p.style.name == "Heading 3" and "safety net" in p.text)
prev = nxt._p.getprevious()
h3_tpl = nxt
first_tpl = P(lambda p: p.style.name == "First Paragraph")
# this section has no Body Text paragraph of its own — borrow one from elsewhere in the document
body_tpl = next(o for o in items if isinstance(o, Paragraph) and o.style.name == "Body Text")

cur = dx.clone_para(h3_tpl, prev, "Why the delivery date gates this one too")
cur = dx.clone_para(first_tpl, cur._p,
    "The same 2026-09-14 analyst note that re-anchored XFER-04 applies here: *\"some POs have "
    "multiple delivery dates, need a where clause that filters these, or all later lines will show "
    "up once the first lines are shipped.\"* Two guards come out of it:")
cur = dx.clone_para(bullet_tpl, cur._p,
    "**Picked early.** `first_pick` alone starts the receipt clock the moment anything is picked, "
    "even when delivery isn't scheduled for another week. Using "
    "`GREATEST(first_pick, due_date)` holds the clock until the receipt is genuinely due (3 of "
    "today's 61 candidates).")
cur = dx.clone_para(bullet_tpl, cur._p,
    "**Multiple delivery dates.** `due_date` is measured over the lines with **nothing received** "
    "(`received_qty <= 0`) and takes the **latest** such date, so a later-dated delivery wave keeps "
    "the order out of the list until its own date passes rather than arriving already-overdue.")
cur = dx.clone_para(first_tpl, cur._p,
    "Rare on transfers today (23 of 92,757 orders carry more than one `expected_date`) — see the "
    "XFER-04 write-up above for the full data profile, including why this is much more common on "
    "Purchase POs.")
log.append("XFER-07 new subsection (heading + 2 paras + 2 bullets)")

codes = [o for o in sec if isinstance(o, Paragraph) and o.style.name == "Source Code"]
sk.set_code(codes[0], sql_for("-- Catalog XFER-07"), doc, word_style, op_chars)
sk.set_code(codes[1], sql_for("-- XFER-07: current backlog"), doc, word_style, op_chars)
log.append("XFER-07 catalog + live SQL")

steps = [o for o in sec if isinstance(o, Paragraph) and o.style.name == "Compact"]
dx.write(steps[2], "`to_exists` — requires the order to be real (skips XFER-01's territory) and "
                   "carries status for the cancelled-order exclusion plus `due_date`, the latest "
                   "delivery date across the lines with nothing received.")
dx.write(steps[3], "`flagged` — picked, not received, not cancelled, and overdue against "
                   "`GREATEST(first_pick, due_date)` (so neither an early pick nor a later-dated "
                   "delivery wave flags before its time) / recent enough "
                   "(`first_pick >= run_date - 30 days`) to matter.")
dx.write(steps[4], "`ranked` + final line — count, cap at 500, oldest-**due** first.")
log.append("XFER-07 walkthrough steps 3/4/5")

cols = T(1)
dx.set_row(cols, 1, ["`ref_order_type`, `l2_action='Transfer Out'` (ledger)", "The pick leg.",
                     "**One half of the clock start** — `first_pick`."])
dx.insert_row_after(cols, 1, ["`expected_date`, `received_qty` (PO table)",
                              "Scheduled delivery date / what's arrived per line.",
                              "**The other half of the clock start** — `due_date` = latest "
                              "`expected_date` among lines with `received_qty <= 0`; the clock "
                              "starts at the later of the two."])
log.append("XFER-07 columns table (+expected_date/received_qty row)")

# worked example: heading, lead-in, a new table cloned from XFER-04's, and the explanation
ex_head = P(lambda p: p.style.name == "Heading 3" and p.text.strip() == "Example")
dx.write(ex_head, "Example of a flagged record (from live data)")
# renaming the heading dropped its pandoc anchor — re-add it with the new slug
dx.add_bookmark(ex_head, "example-of-a-flagged-record-from-live-data-1")
lead = P(lambda p: p.text.startswith("Currently 0 in the live backlog"))
dx.write(lead, "Live BigQuery, run date 2026-09-14:")
# clone XFER-04's Field/Value example table (this section has no example table of its own)
tmpl_ex = next(t for t in doc.tables
               if len(t.columns) == 2 and t.rows[0].cells[0].text.strip() == "Field"
               and "PO-445621" in t.rows[1].cells[1].text)
new_tbl = dx.clone_table_after(tmpl_ex, lead._p)
while len(new_tbl.rows) > 8:
    new_tbl._tbl.remove(new_tbl.rows[-1]._tr)
while len(new_tbl.rows) < 8:
    dx.insert_row_after(new_tbl, len(new_tbl.rows) - 1, ["", ""])
for ri, vals in enumerate([
        ["Field", "Value"],
        ["`transfer_order`", "`PO-464636`"],
        ["`facility`", "Martin Brower"],
        ["`system`", "Martin Brower"],
        ["`first_pick`", "2026-08-31"],
        ["`expected_date`", "2026-09-01"],
        ["`days_since_pick`", "14"],
        ["`breached_at`", "2026-09-03"]]):
    dx.set_row(new_tbl, ri, vals)
p1 = dx.clone_para(body_tpl, new_tbl._tbl,
    "**Why it's flagged:** picked 2026-08-31, due at the destination 2026-09-01, and two weeks "
    "later there is still no `Transfer In` / `Received` ledger row against it. The breach date is "
    "delivery date + 2, not pick date + 2 — the clock starts at the later of the two.")
dx.clone_para(body_tpl, p1._p,
    "The backlog was 0 when the rule went live on 2026-08-17 (see the 0/76,035 note above); the "
    "Martin Brower cluster showing today is new, and worth raising with Field Ops on its own.")
log.append("XFER-07 example heading + new table + explanation")

doc.save(DOCX_OUT)
print("saved %s" % DOCX_OUT)
for l in log:
    print("  ✓", l)
