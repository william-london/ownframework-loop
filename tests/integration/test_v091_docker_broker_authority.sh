#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PYTHONPATH="$ROOT/lib${PYTHONPATH:+:$PYTHONPATH}"
python3 - <<'PY'
import os, tempfile
from pathlib import Path
from ownframework_loop import guards

with tempfile.TemporaryDirectory() as td:
    root=Path(td); broker_dir=root/"broker"; broker_dir.mkdir()
    broker=broker_dir/"docker"; broker.write_text("#!/bin/sh\nexit 0\n"); broker.chmod(0o700)
    base={
      "OFLOOP_SEMANTIC_CONTEXT":"1","OFLOOP_RUN_ID":"r1","OFLOOP_ROLE":"builder",
      "OFLOOP_CANONICAL_REPO":str(root),"OFLOOP_PRIVILEGED_CAPABILITIES":"container.docker",
      "OFLOOP_CONTAINER_BROKER_EXECUTABLE":str(broker.resolve()),
      "PATH":str(broker_dir)+os.pathsep+os.environ.get("PATH",""),
    }
    def severity(cmd, env=None):
        return guards.classify_bash_command_with_env(cmd, env or base)["severity"]

    assert severity("docker compose up -d")=="allowed"
    assert severity("command docker compose up -d")=="allowed"
    assert severity("env FOO=bar docker compose ps")=="allowed"

    negatives=[
      "/usr/bin/docker compose up",
      "PATH=/tmp/evil docker compose up",
      "DOCKER_HOST=tcp://127.0.0.1:2375 docker ps",
      "DOCKER_CONTEXT=desktop-linux docker ps",
      "DOCKER_CONFIG=/tmp/x docker ps",
      "env DOCKER_HOST=unix:///tmp/evil.sock docker ps",
      "docker -H tcp://127.0.0.1:2375 ps",
      "docker --host unix:///tmp/evil.sock ps",
      "docker --context desktop-linux ps",
      "docker --config /tmp/evil ps",
      "sh -c 'docker --host=tcp://127.0.0.1:2375 ps'",
      "bash -c 'env DOCKER_CONTEXT=x docker ps'",
      "docker-compose up",
      "podman ps",
      "nerdctl ps",
      "ctr containers list",
      "crictl ps",
      "docker push example.invalid/x:latest",
      "docker compose push",
      "docker buildx build --push .",
      "docker manifest push example.invalid/x:latest",
      "docker buildx imagetools create example.invalid/x:latest",
    ]
    for cmd in negatives:
        assert severity(cmd)=="forbidden", cmd

    no_cap=dict(base); no_cap["OFLOOP_PRIVILEGED_CAPABILITIES"]=""
    assert severity("docker compose up",no_cap)=="forbidden"
    wrong_broker=dict(base); wrong_broker["OFLOOP_CONTAINER_BROKER_EXECUTABLE"]=str(root/"other"/"docker")
    assert severity("docker compose up",wrong_broker)=="forbidden"

print("OF_LOOP_V091_DOCKER_BROKER_AUTHORITY=PASS")
PY
