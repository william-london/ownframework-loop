#!/usr/bin/env bash
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/../_helpers.sh"
export PYTHONPATH="$ROOT_DIR/lib"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$TMP" <<'PY'
import json, sys
from pathlib import Path
from ownframework_loop import supervisor
root=Path(sys.argv[1])
p=root/"cost.json"
p.write_text(json.dumps({"total_cost_usd":1.25}))
assert supervisor._parse_cost_from_durable_stdout(str(p)) == 1.25
p.write_text('{"total_cost_usd": NaN}')
assert supervisor._parse_cost_from_durable_stdout(str(p)) is None
p.write_text('{"result":"ok"}')
assert supervisor._parse_cost_from_durable_stdout(str(p)) is None

db=root/"s.sqlite"
conn=supervisor._connect(db)
conn.execute("INSERT INTO jobs(repo,run_id,runner,status,created_at,updated_at) VALUES(?,?,?,?,?,?)",
             (str(root),"run-cost-proof","claude-code","RUNNING",1.0,1.0))
job_id=conn.execute("SELECT id FROM jobs").fetchone()[0]
conn.execute("INSERT INTO semantic_attempts(attempt_id,job_id,role,status,started_at,stdout_path,stderr_path) VALUES(?,?,?,?,?,?,?)",
             ("a1",job_id,"builder","RUNNING",1.0,str(p),str(p)))
conn.commit()
try:
    supervisor._account_attempt_cost(conn,job_id=job_id,attempt_id="a1",cost_usd=float("nan"))
except RuntimeError:
    pass
else:
    raise SystemExit("non-finite model cost was accounted")
conn.close()
PY

grep -Fq 'cost_known' "$ROOT_DIR/lib/ownframework_loop/supervisor.py"
grep -Fq 'model_cost_unknown' "$ROOT_DIR/lib/ownframework_loop/supervisor.py"
grep -Fq 'def _terminate_group' "$ROOT_DIR/lib/ownframework_loop/supervisor.py"
if grep -Fq 'or proc.returncode == 0' "$ROOT_DIR/lib/ownframework_loop/supervisor.py"; then
  fail "structured Claude output can still be bypassed by returncode zero"
fi

echo "V061_RUNNER_COST_PROOF=PASS"
