"""BigQuery adapter (used only when DATA_SOURCE=bigquery).

Reads the prior-day ledger partition and the PO table via the Storage/Query API and
returns rows as plain dicts keyed by schema_map column names. Pushdown-to-SQL of the
rule logic is a later optimization (PLAN Phase 6); this first pass selects the
partition and lets the Python engine evaluate, which is fine at prototype volumes.

Auth: on Cloud Run this picks up the runtime service account via ADC automatically.
Hosts with no GCP ADC (e.g. Azure Functions/Container Apps) instead supply the SA
key as JSON via `google_service_account_json` (e.g. an Azure Key Vault secret surfaced
as an env var) — see `settings.google_service_account_json`.
"""
import json
from typing import List, Dict, Optional

from .base import DataSource
from ..config import settings
from ..schema_map import LEDGER_TABLE, PO_TABLE, LEDGER


class BigQueryDataSource(DataSource):
    def __init__(self):
        try:
            from google.cloud import bigquery  # noqa
        except ImportError as e:  # pragma: no cover
            raise RuntimeError(
                "DATA_SOURCE=bigquery requires google-cloud-bigquery. "
                "Install with: pip install 'google-cloud-bigquery>=3.17'"
            ) from e
        from google.cloud import bigquery
        for req in ("gcp_project", "bq_dataset", "bq_ledger_table", "bq_po_table"):
            if not getattr(settings, req):
                raise RuntimeError("DATA_SOURCE=bigquery requires %s in .env" % req.upper())
        self._bq = bigquery
        credentials = None
        if settings.google_service_account_json:
            from google.oauth2 import service_account
            info = json.loads(settings.google_service_account_json)
            credentials = service_account.Credentials.from_service_account_info(
                info, scopes=["https://www.googleapis.com/auth/bigquery"]
            )
        self.client = bigquery.Client(project=settings.gcp_project, credentials=credentials)

    def _q(self, table: str) -> str:
        return "`%s.%s.%s`" % (settings.gcp_project, settings.bq_dataset, table)

    def fetch_table(self, table: str, run_date: Optional[str] = None) -> List[Dict]:
        if table == PO_TABLE:
            sql = "SELECT * FROM %s" % self._q(settings.bq_po_table)
            return [dict(r) for r in self.client.query(sql).result()]
        if table == LEDGER_TABLE:
            col = LEDGER["txn_date"]
            sql = "SELECT * FROM %s WHERE %s = @run_date" % (self._q(settings.bq_ledger_table), col)
            cfg = self._bq.QueryJobConfig(query_parameters=[
                self._bq.ScalarQueryParameter("run_date", "DATE", run_date)
            ])
            return [dict(r) for r in self.client.query(sql, job_config=cfg).result()]
        return []
