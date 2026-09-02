import importlib.util
from pathlib import Path

from fastapi.testclient import TestClient


MODULE_PATH = Path(__file__).parents[1] / "services" / "unauthorized-demo-service" / "app" / "main.py"
spec = importlib.util.spec_from_file_location("sink_main", MODULE_PATH)
sink = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(sink)
client = TestClient(sink.app)


def test_webhook_records_only_supplied_synthetic_artifact():
    client.delete("/requests")
    chunks = ["REVNT19BUElfS0VZPXN5bnRoZXRpYy1u", "b3QtYS1zZWNyZXQKREVNT19SRUdJT049", "bGFiLW9ubHk="]
    response = client.get("/records/sync/" + "/".join(chunks))
    assert response.status_code == 200
    events = client.get("/requests").json()
    assert events[0]["event"] == "synthetic-demo-artifact"
    assert events[0]["chunks"] == chunks
    assert events[0]["decoded_synthetic_content"] == "DEMO_API_KEY=synthetic-not-a-secret\nDEMO_REGION=lab-only"


def test_environment_upload_logs_complete_synthetic_file():
    client.delete("/requests")
    content = "DEMO_API_KEY=synthetic-not-a-secret\nDEMO_REGION=lab-only"
    response = client.post("/artifacts/environment", content=content, headers={"content-type": "text/plain"})
    assert response.status_code == 200
    assert response.json()["bytes"] == len(content)
    event = client.get("/requests").json()[0]
    assert event["artifact"] == "/tmp/agent-runtime-context.snapshot"
    assert event["content"] == content


def test_receiver_console_renders_evidence_ui():
    response = client.get("/")
    assert response.status_code == 200
    assert "Receiver evidence desk" in response.text
    assert "Artifact" in response.text
    assert "Callback" in response.text


def test_callback_is_recorded_as_safe_fixed_transcript():
    client.delete("/requests")
    response = client.post(
        "/callbacks/connect",
        json={"identity": "uid=1001(agent)", "workload": "ai-email-demo/openclaw"},
    )
    assert response.status_code == 200
    assert response.json()["status"] == "synthetic-callback-recorded"
    event = client.get("/requests").json()[0]
    assert event["event"] == "synthetic-callback"
    assert event["identity"] == "uid=1001(agent)"
    assert "command" not in event
