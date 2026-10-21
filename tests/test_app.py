import importlib

import pytest

import app as app_module


@pytest.fixture()
def client():
    app_module.app.config.update(TESTING=True)
    return app_module.app.test_client()


def test_index_returns_service_metadata(client):
    resp = client.get("/")
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["service"] == "ecs-cicd-demo-v5"
    assert "version" in body
    assert "hostname" in body


def test_health_ok_by_default(client):
    resp = client.get("/health")
    assert resp.status_code == 201
    assert resp.get_json()["status"] == "ok"


def test_health_fails_when_forced_unhealthy(client, monkeypatch):
    monkeypatch.setenv("FORCE_UNHEALTHY", "true")
    resp = client.get("/health")
    assert resp.status_code == 500
    assert resp.get_json()["status"] == "unhealthy"


def test_version_comes_from_env(monkeypatch):
    monkeypatch.setenv("GIT_SHA", "abc1234")
    reloaded = importlib.reload(app_module)
    assert reloaded.VERSION == "abc1234"
    monkeypatch.delenv("GIT_SHA")
    importlib.reload(app_module)
