"""Nightly Wonder DQ validation trigger (docs/GO-LIVE-AZURE.md §7).

Deliberately the thinnest possible Function: one timer, one POST. All the logic lives in the
console's own `/api/run` endpoint (wonder/api/routes.py -> run_daily), exactly as it does behind
Cloud Scheduler on GCP. Nothing here is Wonder-specific beyond the URL path.

Config comes from app settings that Terraform sets (see scheduler.tf):
  TARGET_URL         base URL of the Container App
  DAILY_RUN_SCHEDULE NCRONTAB expression, interpreted in WEBSITE_TIME_ZONE
"""
import json
import logging
import os
import urllib.error
import urllib.request

import azure.functions as func

app = func.FunctionApp()

# Cold start + a full BigQuery validation pass can take minutes; keep this under the host's
# functionTimeout (host.json sets 10m, the Consumption-plan maximum).
REQUEST_TIMEOUT_SECONDS = 540


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

    request = urllib.request.Request(
        url,
        data=b"{}",
        method="POST",
        headers={"Content-Type": "application/json"},
    )

    try:
        with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
            body = response.read().decode("utf-8", "replace")
            logging.info("POST %s -> %s %s", url, response.status, body[:1000])
    except urllib.error.HTTPError as exc:
        # Surface the response body — the API returns a JSON error the run log should keep.
        detail = exc.read().decode("utf-8", "replace")[:1000]
        logging.error("POST %s failed: HTTP %s %s", url, exc.code, detail)
        raise
    except urllib.error.URLError as exc:
        logging.error("POST %s failed: %s", url, exc.reason)
        raise
    else:
        # Log the run summary (scanned/seen/new/autoClosed) as structured data when it parses.
        try:
            logging.info("Run summary: %s", json.dumps(json.loads(body))[:1000])
        except (ValueError, TypeError):
            pass
