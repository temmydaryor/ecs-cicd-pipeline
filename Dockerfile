# syntax=docker/dockerfile:1

# ---------- Stage 1: builder (has pip, wheels, build tooling) ----------
FROM python:3.12-slim AS builder
WORKDIR /build
COPY webapp/requirements.txt .
# --prefix installs into /install so we can copy ONLY the result into the runtime stage
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ---------- Stage 2: runtime (small, non-root, no build tools) ----------
FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080

# Non-root user. Numeric UID so ECS/Kubernetes policies can verify it.
RUN useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin appuser

WORKDIR /app
COPY --from=builder /install /usr/local
COPY webapp/app.py .

# The pipeline passes the commit SHA so GET / shows exactly what is running.
ARG GIT_SHA=local
ENV GIT_SHA=${GIT_SHA}

USER 10001
EXPOSE 8080

# python:slim has no curl/wget, so the health check uses the Python stdlib.
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=2).status == 200 else 1)"

CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--access-logfile", "-", "app:app"]
