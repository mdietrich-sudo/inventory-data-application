# Inventory Data-Quality Console — How It Works

*A process overview for Accounting, Supply Chain, Field Ops, and the platform team.*

---

## 1. Why this exists

Wonder has no single ERP. Inventory activity is stitched together from several upstream systems
(Pantry, Ship Hero, Fishbowl, and the ERP cost tables) into a **unified inventory ledger** and a
companion **purchase-order table**. Accounting uses those two tables as the sub-ledger for the
month-end journal entries.

That makes them mission-critical — and fragile. A bad join, a wrong unit conversion, or a
double-logged receipt flows straight into the general ledger. Until now, finding those problems
depended on someone noticing them at close.

**The Inventory Data-Quality Console checks the data every night, files a Jira ticket for every
problem it finds, routes it to the team that can fix it, closes it automatically once the data is
corrected, and measures how long the whole thing took.**

---

## 2. The daily cycle in one picture

```
   Every night (00:15 PT)
            │
            ▼
   ┌────────────────────┐     reads yesterday's data, read-only
   │  1. Validation run │ ◄─────────────────────────────────  BigQuery
   └────────┬───────────┘                                     (ledger · POs · ERP cost)
            │
            ▼
   ┌────────────────────┐     ~18 rules across PO receiving, transfers,
   │  2. Detect         │     waste, adjustments, and cost data
   └────────┬───────────┘
            │
            ▼
   ┌────────────────────┐     already-known problem?  →  bump its recurrence count,
   │  3. De-duplicate   │     add a note, do NOT create a second ticket
   └────────┬───────────┘
            │
            ▼
   ┌────────────────────┐     severity + owning team + named assignee,
   │  4. Route & ticket │     Jira issue created automatically
   └────────┬───────────┘
            │
            ▼
   ┌────────────────────┐     people work it in Jira or in the console —
   │  5. Remediate      │     the two stay in sync
   └────────┬───────────┘
            │
            ▼
   ┌────────────────────┐     next run re-tests that exact record; if it now
   │  6. Auto-close     │     passes, the ticket closes itself
   └────────┬───────────┘
            │
            ▼
   ┌────────────────────┐     turnaround, SLA breaches, repeat offenders,
   │  7. Measure        │     open work by team and by person
   └────────────────────┘
```

The run is a batch job over the **prior full data day** (Wonder's data day closes at midnight
Pacific). Nobody has to trigger it; the console shows a refresh banner when a new run lands.

---

## 3. What counts as a problem

Every check is one of two kinds:

| Kind | Meaning | Example |
|---|---|---|
| **Hard fail** | Deterministically wrong. It needs correcting. | A PO line with a $0.00 vendor price. |
| **Soft fail** | Suspicious. A human decides whether it's an error or a legitimate business exception. | A facility's waste for the day exceeding its dollar threshold. |

Each finding is stamped with a **severity**, which sets the clock:

| Severity | What it means | Resolution target |
|---|---|---|
| **Urgent** | Likely financial-statement or margin impact | Same day |
| **High** | Operationally material, or a recurring data defect | 1 business day |
| **Medium** | Needs review, limited immediate impact | 2 business days |
| **Low** | Informational / cleanup | 3–5 business days |

**The clock starts when the problem actually began in the data — not when the batch happened to
notice it.** A receipt that went wrong on the 3rd and is detected on the 5th is already two days
old when the ticket opens. That's deliberate: it measures the real exposure, not our detection lag.

---

## 4. Who owns what

Findings are routed automatically, in two ways:

- **By error type.** Most checks have a standing owner: PO pricing and unit conversions go to
  Procurement, referential/master-data breaks go to SC Product (IMS), cost-setup gaps go to
  Accounting.
- **By facility.** Receiving overages, daily waste, and daily adjustments route by where they
  happened — selling units (HDR) to **Field Ops — IKC**, Central Kitchen / Distribution /
  Production to **Field Ops — ProdCo**.

### Primary owner vs. current holder

Two distinct roles, and the difference matters for accountability:

- The **primary owner** is accountable. This never changes on a hand-off, and the SLA clock stays
  with them.
- The **current holder** is whoever is actively working the item right now.

When someone hands a ticket off, the holder changes, the hand-off is written to the ticket's
timeline, "held N days" starts counting for the new holder — and **the SLA does not reset**. The
primary owner can see exactly what they're still accountable for, including everything they've
handed to someone else.

---

## 5. What people actually use

The console has five screens.

| Screen | What it's for |
|---|---|
| **Reporting Dashboard** *(home)* | KPI tiles, a flagged-vs-auto-closed trend line, breakdowns by system, error type, facility, severity, and inventory movement type, plus a recurring-error leaderboard. Every tile and chart segment is clickable and drills into the workbench pre-filtered. |
| **Exception Workbench** | The working queue. Filter by team, owner, facility, system, severity, status, or error type; open any row for the full detail drawer. |
| **Closed / Resolved** | Everything that's been fixed — manually or automatically — with what the fix was and when. |
| **Turnaround / SLA** | Average days to close, breaches, open-by-age, a by-owner table (accountability) and a by-holder table (who's sitting on work). Click any name to see their queue. |
| **Rule & Routing Admin** | The rule catalog with plain-English explanations and the exact logic behind each check, the routing map, SLA targets, and the settings the business can change directly (below). |

### The detail drawer

Opening an exception shows the "why this flagged" evidence, not just a code — for a receiving
overage, the PO line side by side with every individual ledger receipt, its timestamp, facility,
and movement type, with an automatic warning when two identical receipts look like a
double-entry. It also holds the full timeline (created, recurred, reassigned, handed off,
commented, resolved) and the action buttons: change status, reassign, hand off, comment, resolve.

---

## 6. How Jira is used

Every finding becomes a real Jira ticket, written to be readable by the person who has to fix it:

- **Title:** the plain-English error name and the specific record — e.g. *PO Over Receipt // PO
  FB-2126 · SKU 4001234*.
- **Priority:** matched to the severity above.
- **Description:** a labelled bullet list of the relevant facts (what was ordered, what was
  received, where, when), not a dump of raw data.
- **Assignee and team label:** set from the routing rules, so each team can filter Jira to its own
  queue.
- **A fingerprint label** that makes the ticket uniquely identifiable — this is what prevents
  duplicates.

**No duplicates, ever.** If the same problem is still present tomorrow, the existing ticket gets a
recurrence note; a second ticket is never opened.

**Actions taken in the console push to Jira immediately** — status changes, reassignment,
hand-offs, and resolution all update the real issue as you click. Changes made *directly in Jira*
(someone moves a ticket to Done in their own board) flow back into the console, so the two never
drift apart.

**Auto-close is per-ticket, not per-batch.** Each run re-tests each open ticket's specific record
against current data and closes it only if it genuinely passes now. When Data Engineering fixes
something upstream, the affected tickets close themselves and the console records what changed —
without anyone filing a "fixed" update, and without closing anything that merely fell out of a
day's scope.

---

## 7. What the business can change without a developer

Some settings are deliberately in the app, editable in **Rule & Routing Admin** and applied on the
next run with no deployment:

- **Facility dollar thresholds** for daily waste and daily adjustments (a High band and an Urgent
  band per facility type).
- **The waste action allowlist** — which inventory movement combinations count as waste, so losses
  and recoveries net correctly.
- **Transfer-order aging thresholds** — how many days without a pick, or without a receipt after
  picking, counts as a problem.
- **Data retention** — how long closed tickets are kept.

Rule *logic* (the actual queries), severities, and routing live in version control and change
through the normal review-and-release path. That's intentional: thresholds are business judgment
and move often; logic is auditable and shouldn't move quietly.

---

## 8. Validation coverage

The full validation framework defines **47 tests across 11 transaction classes**. **18 are live
today**, prioritized by where the real data showed actual defects. The remainder are catalogued and
get switched on as they're validated against production data.

| Area | What's covered today |
|---|---|
| **PO receiving & 3-way match** | Missing PO references (ledger and master table), receiving more than was ordered, SKUs received against a PO that doesn't list them, unit-of-measure mismatches between the PO and the receipt, corrections that don't reference what they're correcting. |
| **Procurement / vendor data** | $0.00 or missing vendor prices, missing Consumable↔Vendor unit conversions, POs sitting unreceived past their expected date, partially-received POs never closed out. |
| **Inter-network transfers** | Picks against transfer orders that don't exist, items picked or received that aren't on the transfer order, transfer orders with no pick activity, and picked transfers never received. |
| **Waste & adjustments** | Daily net waste dollars per facility over threshold, and daily absolute adjustment dollars per facility over threshold (catches churn that nets to zero). |
| **Cost data** | Consumable SKUs with no standard-cost record at all, and SKUs whose standard cost is $0.00 or null — both of which silently corrupt any valuation. |

The complete list, with severity and owning team, is in **Appendix A**.

---

## 9. How it's hosted

Wonder's Azure environment hosts the application. **The inventory data itself does not move** — it
stays in BigQuery, where the data engineering team already builds it, and the app reads it
read-only.

| Piece | What it is | Why |
|---|---|---|
| **Azure App Service** | Runs the application (the API and the web console as one container) | Managed, HTTPS by default, and the service the client's platform team standardizes on |
| **Azure Database for PostgreSQL** | The app's own database: exceptions, tickets, SLA clocks, history, audit log | This is the system of record for the *workflow*, not for inventory |
| **Azure Key Vault** | Holds every credential (database, Jira, BigQuery) | Nothing sensitive lives in code, config files, or the container image |
| **Azure Container Registry** | Stores the built application image | Standard build-and-deploy path |
| **Azure Functions (timer)** | Fires the nightly run at 00:15 PT | One scheduled call; the schedule is the only thing it knows about |
| **Azure Monitor / Log Analytics** | Run logs and operational alerting | Visibility into failed or anomalous runs |
| **BigQuery (stays in GCP)** | The source data: unified ledger, PO table, ERP standard costs | Read-only; the app never writes to it |
| **Jira Cloud** | Ticketing | Wonder's existing instance and workflow |

Everything above is defined as code (Terraform), so the environment can be rebuilt, reviewed, or
moved without tribal knowledge.

**Sign-in.** The console is designed to sit behind **Microsoft Entra ID single sign-on** using
Azure's built-in platform authentication — Wonder users sign in with their existing corporate
account, and no separate credential or user list is maintained. This is a platform-level setting,
not application code, so it's switched on against Wonder's tenant during deployment.

---

## 10. Roles and responsibilities

| Who | Responsibility |
|---|---|
| **Field Ops (IKC / ProdCo)** | Receiving overages, waste and adjustment exceptions, transfer-order aging at their facilities |
| **Procurement** | Vendor pricing, unit conversions, PO lifecycle (unreceived, partially received) |
| **SC Product (IMS)** | Master-data and referential breaks — missing PO/TO references, SKUs not on their order, missing correction references |
| **Accounting (Cost Accountant)** | Standard-cost setup gaps in the ERP; overall ownership of the month-end impact |
| **Data Engineering** | Upstream fixes in the pipeline that feeds the ledger and PO tables — their fixes are what trigger auto-close |
| **Platform / IT** | The Azure environment, credentials, scheduled run health |

---

## 11. Data handling

- The app reads BigQuery **read-only** and never writes back to source data.
- Every query is cost-capped, and scoped to the day's partition rather than scanning the full
  186M-row ledger.
- Every state change — creation, routing, recurrence, reassignment, hand-off, comment, resolution,
  auto-close — is written to an immutable audit log with actor and timestamp.
- Closed tickets are retained for a configurable period, then purged.
- Credentials are held in Key Vault and injected at runtime; none are stored in the repository or
  the container image.

---

## Appendix A — Live validation rules

| ID | Check | Severity | Type | Owning team |
|---|---|---|---|---|
| PO-01 | Inventory log entry missing a PO number | Urgent | Hard | SC Product (IMS) |
| PO-13 | PO master-table row missing its PO number | Urgent | Hard | SC Product (IMS) |
| PO-03 | Received quantity exceeds the quantity ordered | High / Urgent¹ | Soft | Field Ops (by facility) |
| PO-03a | PO and ledger units of measure disagree² | High | Soft | Procurement |
| PO-14 | SKU received against a PO that doesn't list it | High | Hard | SC Product (IMS) |
| PO-11 | "Correct receiving" entry missing its correction reference | High | Hard | SC Product (IMS) |
| PO-09 | PO line has a $0.00 or null vendor price | Urgent | Hard | Procurement |
| PO-06 | Purchased item has no Consumable↔Vendor unit conversion | Urgent | Hard | Procurement |
| PO-07 | Open PO past its expected date with nothing received | Medium | Soft | Procurement |
| PO-08 | Partially-received PO never closed out | Medium | Soft | Procurement |
| XFER-01 | Items picked against a transfer order that doesn't exist | High | Hard | SC Product (IMS) |
| XFER-02 | Item picked that isn't on the transfer order | High | Hard | Field Ops |
| XFER-05 | Item received that isn't on the transfer order | High | Hard | SC Product (IMS) |
| XFER-04 | Transfer order with no pick activity after Y days³ | Medium | Soft | Field Ops |
| XFER-07 | Transfer picked but not received after Z days³ | Medium | Soft | Field Ops |
| WASTE-DAILY | Facility's daily net waste $ over threshold³ | High / Urgent¹ | Soft | Field Ops (by facility) |
| ADJ-DAILY | Facility's daily absolute adjustment $ over threshold³ | High / Urgent¹ | Soft | Field Ops (by facility) |
| COST-01 | Consumable SKU with activity but no standard-cost record | High | Hard | Accounting (Cost Accountant) |
| COST-02 | Consumable SKU whose standard cost is $0.00 or null | High | Hard | Accounting (Cost Accountant) |

¹ Severity is tiered by magnitude — e.g. receiving 30–99% over ordered is **High** (a supply-chain
signal), receiving 100%+ over is **Urgent** (a likely double-receive or keying error).
² A companion outcome of PO-03: when the units don't match, ordered and received aren't comparable
at all, so it's separated out rather than counted as an overage.
³ Threshold is editable in Rule & Routing Admin.

Also catalogued and pending activation: Transfer Warehouse in/out balance (TWH-01), negative
on-hand (COMPLETE-02), and the remaining tests in the production, expiration, and sales classes.

---

## Appendix B — Glossary

| Term | Meaning |
|---|---|
| **Unified inventory ledger** | The BigQuery table combining inventory movements from all upstream systems. The sub-ledger Accounting books from. |
| **Unified PO table** | The BigQuery table of purchase and transfer orders, joined to the ledger for 3-way matching. |
| **Exception** | One specific data problem found by one rule on one record. Becomes one Jira ticket. |
| **Fingerprint** | The unique signature of an exception (rule + record). What guarantees no duplicate tickets. |
| **Recurrence** | How many runs in a row the same exception has reproduced. High recurrence = a systemic upstream issue, not a one-off. |
| **Hard / Soft fail** | Deterministically wrong vs. needs-human-review. |
| **Primary owner** | Accountable for the exception. Holds the SLA. Does not change on hand-off. |
| **Current holder** | Whoever is actively working it right now. |
| **Auto-close** | The system closing a ticket by itself after re-testing the record and confirming the data is now correct. |
| **Backfill** | The one-time initial sweep that catches the existing backlog, before the daily cadence takes over. |
| **HDR / CK / DISH / Production** | Facility types — selling units vs. central kitchen, distribution, and production sites. Drives routing and dollar thresholds. |
