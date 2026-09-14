"""Nightly Wonder DQ validation trigger (docs/GO-LIVE-AZURE.md §7).

One timer, one POST. All the logic lives in the console's own `/api/run` endpoint
(wonder/api/routes.py -> run_daily), exactly as it does behind Cloud Scheduler on GCP. Nothing here
is Wonder-specific beyond the URL paths.

The only reason this isn't four lines is the App Service front end: it drops any HTTP request that
sends no response bytes for ~230 seconds, and that limit is not configurable. `/api/run` blocks for
~15 minutes, so a *successful* run still hands us a 502/504 or a dropped socket. So:

  1. POST /api/run and accept that we probably won't get the response body.
  2. If it's cut off, poll GET /api/runinfo until `runDate` advances past what it was before the
     POST — that's positive confirmation the run completed.
  3. Never raise on a timeout. A raised exception marks the timer invocation failed, and a retry
     would fire a SECOND concurrent validation run — duplicate Jira churn is worse than an
     unconfirmed run. Only genuine "the run never started" errors raise.

Confirmation is best-effort by design: the Consumption plan caps functionTimeout at 10 minutes,
under the current ~15 minute run, so "started, not confirmed" is the expected steady state until
`/api/run` is made asynchronous (return a run id immediately, poll /api/runinfo). Tracked in
docs/GO-LIVE-AZURE.md §7.5.

Config comes from app settings that Terraform sets (see scheduler.tf):
  TARGET_URL                     base URL of the App Service
  DAILY_RUN_SCHEDULE             NCRONTAB expression, interpreted in WEBSITE_TIME_ZONE
  DAILY_RUN_POLL_BUDGET_SECONDS  how long to poll for confirmation (0 disables)
"""
import http.client
import json
import logging
import os
import socket
import time
import urllib.error
import urllib.request

import azure.functions as func

app = func.FunctionApp()

# The front end cuts us off around 230s; don't sit on a socket well past that pretending otherwise.
POST_TIMEOUT_SECONDS = 240
RUNINFO_TIMEOUT_SECONDS = 30
POLL_INTERVAL_SECONDS = 20

# Errors that mean "the request was cut off mid-flight", NOT "the run failed to start". App Service
# returns 502/503/504 when its front end gives up on a slow backend.
GATEWAY_STATUSES = (502, 503, 504)


def _poll_budget() -> int:
    try:
        return max(0, int(os.environ.get("DAILY_RUN_POLL_BUDGET_SECONDS", "480")))
    except ValueError:
        logging.warning("DAILY_RUN_POLL_BUDGET_SECONDS is not an integer; defaulting to 480.")
        return 480


def _run_date(base: str):
    """Current `runDate` from GET /api/runinfo, or None if it can't be read."""
    try:
        request = urllib.request.Request(f"{base}/api/runinfo", method="GET")
        with urllib.request.urlopen(request, timeout=RUNINFO_TIMEOUT_SECONDS) as response:
            return json.loads(response.read().decode("utf-8", "replace")).get("runDate")
    except (urllib.error.URLError, OSError, ValueError, TypeError) as exc:
        logging.warning("GET %s/api/runinfo failed: %s", base, exc)
        return None


def _confirm(base: str, before, deadline: float) -> bool:
    """Poll /api/runinfo until the run date moves past `before`. True = the run demonstrably finished."""
    while time.monotonic() < deadline:
        time.sleep(min(POLL_INTERVAL_SECONDS, max(0, deadline - time.monotonic())))
        current = _run_date(base)
        if current and current != before:
            logging.info("Run confirmed: runDate advanced %s -> %s.", before, current)
            return True
    return False


@app.timer_trigger(
    arg_name="timer",
    schedule="%DAILY_RUN_SCHEDULE%",
    run_on_startup=False,
    use_monitor=True,
)
def daily_run(timer: func.TimerRequest) -> None:
    base = os.environ["TARGET_URL"].rstrip("/")
    url = f"{base}/api/run"

    if timer.past_due:
        logging.warning("Timer is past due; running the daily validation now.")

    # Snapshot the run date first so a cut-off POST can still be confirmed by comparison.
    before = _run_date(base)
    logging.info("Starting daily validation via POST %s (runDate before: %s).", url, before)

    request = urllib.request.Request(
        url,
        data=b"{}",
        method="POST",
        headers={"Content-Type": "application/json"},
    )

    started = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=POST_TIMEOUT_SECONDS) as response:
            body = response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:1000]
        if exc.code in GATEWAY_STATUSES:
            # The front end gave up on a slow backend. The run itself is almost certainly still going.
            logging.warning(
                "POST %s returned HTTP %s after %.0fs — App Service front-end timeout, not a run "
                "failure. Polling /api/runinfo for confirmation. Detail: %s",
                url, exc.code, time.monotonic() - started, detail,
            )
            _report(base, before, started)
            return
        # A real application error (400 from run_daily, 401/403, 404) — surface it.
        logging.error("POST %s failed: HTTP %s %s", url, exc.code, detail)
        raise
    except (socket.timeout, TimeoutError, http.client.IncompleteRead) as exc:
        logging.warning(
            "POST %s was cut off after %.0fs (%s) — expected while /api/run blocks for ~15 min. "
            "Polling /api/runinfo for confirmation.", url, time.monotonic() - started, exc,
        )
        _report(base, before, started)
        return
    except urllib.error.URLError as exc:
        # Reason is a socket.timeout when urlopen's own timeout trips: same "cut off" case.
        if isinstance(exc.reason, (socket.timeout, TimeoutError)):
            logging.warning(
                "POST %s timed out after %.0fs — expected while /api/run blocks for ~15 min. "
                "Polling /api/runinfo for confirmation.", url, time.monotonic() - started,
            )
            _report(base, before, started)
            return
        # DNS failure, connection refused, TLS error: the run never started. Fail loudly.
        logging.error("POST %s failed to reach the console: %s", url, exc.reason)
        raise
    else:
        logging.info("POST %s -> %s %s", url, 200, body[:1000])
        try:
            logging.info("Run summary: %s", json.dumps(json.loads(body))[:1000])
        except (ValueError, TypeError):
            pass


def _report(base: str, before, started: float) -> None:
    """Confirm-or-warn after a cut-off POST. Deliberately never raises: a failed invocation can be
    retried by the host, and a retry would start a second concurrent validation run."""
    budget = _poll_budget()
    if budget == 0:
        logging.warning("Confirmation polling disabled; run started but not confirmed.")
        return

    if _confirm(base, before, started + budget):
        logging.info("Daily validation completed in ~%.0fs.", time.monotonic() - started)
        return

    logging.warning(
        "Daily validation started but was NOT confirmed within %ss (runDate still %s). The run is "
        "most likely still in progress server-side — the ~15 min run exceeds both the App Service "
        "230s request limit and this function's 10 min Consumption timeout. Check the console's "
        "run history, or GET /api/runinfo. Not raising: a retry would start a duplicate run. "
        "Permanent fix: make POST /api/run asynchronous (GO-LIVE-AZURE.md §7.5).",
        budget, before,
    )
