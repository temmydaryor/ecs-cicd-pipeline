"""Tiny Flask service used as the deployment target for the CI/CD pipeline.

Endpoints
  /          -> JSON with the running version (git SHA) so a deploy is visible
  /health    -> liveness/readiness probe used by the ALB target group and Docker
  /fail      -> returns 500 when FORCE_UNHEALTHY=true (used to demo auto-rollback)
"""
import os
import socket
import time

from flask import Flask, jsonify

app = Flask(__name__)

START_TIME = time.time()
VERSION = os.getenv("GIT_SHA", "local")
APP_ENV = os.getenv("APP_ENV", "dev")


def _unhealthy() -> bool:
    # Flip this env var in the task definition to simulate a bad release.
    return os.getenv("FORCE_UNHEALTHY", "false").lower() == "true"


@app.get("/")
def index():
    return jsonify(
        service="ecs-cicd-demo-v5",
        version=VERSION,
        environment=APP_ENV,
        hostname=socket.gethostname(),
        uptime_seconds=round(time.time() - START_TIME, 1),
    )


@app.get("/health")
def health():
    if _unhealthy():
        return jsonify(status="unhealthy", version=VERSION), 500
    return jsonify(status="ok", version=VERSION), 200


if __name__ == "__main__":  # local dev only; containers use gunicorn
    app.run(host="0.0.0.0", port=8080)
