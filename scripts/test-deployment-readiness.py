"""배포 없이 실제 PowerShell 검사와 로컬 HTTP 응답의 성공·실패 경로를 검증한다."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "wait-for-deployment.ps1"
PROJECT = "fullstack-pipeline-test"


def running_rows():
    return [
        {"ID": f"fixture-{name}", "Name": f"pipeline-{name}", "Command": "fixture",
         "Project": PROJECT, "Service": name, "State": "running",
         "Health": "", "ExitCode": 0, "Publishers": None}
        for name in ("db", "backend", "frontend", "nginx")
    ]


def ps_quote(value):
    return str(value).replace("'", "''")


class ReadinessTests(unittest.TestCase):
    def invoke(self, *, frames=None, responses=None, docker_exit=0,
               pipeline=False, timeout=1):
        frames = [running_rows()] if frames is None else frames
        responses = [(200, "[]")] if responses is None else responses
        observed = []

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                observed.append(self.path)
                response = responses[min(len(observed) - 1, len(responses) - 1)]
                status, body = response[:2]
                if len(response) == 3:
                    time.sleep(response[2])
                encoded = body.encode()
                try:
                    self.send_response(status)
                    self.send_header("Content-Type", "application/json")
                    if status == 302:
                        self.send_header("Location", "/different")
                    self.send_header("Content-Length", str(len(encoded)))
                    self.end_headers()
                    self.wfile.write(encoded)
                except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                    pass

            def log_message(self, *_):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        scratch = ROOT / ".coverity" / "readiness-tests"
        scratch.mkdir(parents=True, exist_ok=True)
        try:
            with tempfile.TemporaryDirectory(prefix="case-", dir=scratch) as folder:
                fixture = Path(folder) / "docker.json"
                fixture.write_text(json.dumps({"frames": frames, "exit": docker_exit}),
                                   encoding="utf-8")
                if pipeline:
                    stage = (ROOT / "Jenkinsfile").read_text(encoding="utf-8-sig")
                    stage = stage.split("stage('Check Containers')", 1)[1]
                    match = re.search(r"script:\s*'''([\s\S]*?)'''", stage)
                    if match:
                        command = match.group(1)
                    else:
                        command = re.search(r"bat\s+'([^']+)'", stage).group(1)
                else:
                    self.assertTrue(SCRIPT.is_file(), "배포 상태 확인 스크립트가 필요함")
                    command = (
                        f"& '{ps_quote(SCRIPT)}' -ProjectName '{PROJECT}' "
                        f"-BaseUri 'http://127.0.0.1:{server.server_port}' "
                        f"-TimeoutSeconds {timeout} -PollIntervalSeconds 1"
                    )
                wrapper = r"""
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$global:ReadinessProbeCalls=0
function global:docker {
    $cli=@($args)
    $fixture=Get-Content -Raw -LiteralPath $env:READINESS_FIXTURE | ConvertFrom-Json
    if ($cli[0] -ne 'ps') {
        $projectIndex=[Array]::IndexOf($cli,'-p')
        $fileIndex=[Array]::IndexOf($cli,'-f')
        if ($cli[0] -ne 'compose' -or $projectIndex -lt 0 -or
            $cli[$projectIndex+1] -ne 'fullstack-pipeline-test' -or
            $fileIndex -lt 0 -or -not (Test-Path -LiteralPath $cli[$fileIndex+1]) -or
            $cli -notcontains 'ps' -or $cli -notcontains '--all' -or
            $cli -notcontains '--format' -or $cli -notcontains 'json') {
            throw '조회 전용 Docker 계약과 다른 명령임'
        }
    }
    $index=[Math]::Min($global:ReadinessProbeCalls,$fixture.frames.Count-1)
    $global:ReadinessProbeCalls++
    $global:LASTEXITCODE=[int]$fixture.exit
    foreach($row in $fixture.frames[$index]) {
        ConvertTo-Json -InputObject $row -Compress -Depth 8
    }
}
""" + command + "\nexit 0"
                env = dict(os.environ, READINESS_FIXTURE=str(fixture), WORKSPACE=str(ROOT))
                started = time.monotonic()
                process = subprocess.run(
                    ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", wrapper],
                    env=env, capture_output=True, text=True, encoding="utf-8",
                    errors="replace", timeout=12 + timeout)
                elapsed = time.monotonic() - started
                return process, observed, elapsed
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=2)

    def assert_pass(self, process):
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)

    def assert_fail(self, process):
        self.assertNotEqual(process.returncode, 0, "준비되지 않은 배포를 성공으로 처리함")

    def test_pipeline_rejects_no_application_containers(self):
        process, observed, _ = self.invoke(frames=[[]], pipeline=True)
        self.assert_fail(process)
        self.assertEqual(observed, [])

    def test_running_services_and_user_response_pass(self):
        body = '[{"id":1,"username":"sample","email":"sample@example.invalid","createdAt":"2026-11-03T12:00:00"}]'
        process, observed, _ = self.invoke(responses=[(200, body)])
        self.assert_pass(process)
        self.assertEqual(observed, ["/api/users"])

    def test_empty_user_list_is_valid(self):
        process, _, _ = self.invoke()
        self.assert_pass(process)

    def test_missing_service_fails_even_if_api_would_pass(self):
        process, observed, _ = self.invoke(frames=[running_rows()[:-1]])
        self.assert_fail(process)
        self.assertEqual(observed, [])

    def test_exited_backend_fails(self):
        rows = running_rows()
        rows[1]["State"] = "exited"
        rows[1]["ExitCode"] = 1
        process, _, _ = self.invoke(frames=[rows])
        self.assert_fail(process)

    def test_other_project_cannot_satisfy_readiness(self):
        rows = running_rows()
        for row in rows:
            row["Project"] = "different-project"
        process, _, _ = self.invoke(frames=[rows])
        self.assert_fail(process)

    def test_api_failure_times_out(self):
        process, _, elapsed = self.invoke(responses=[(503, '{"error":"unavailable"}')])
        self.assert_fail(process)
        self.assertLess(elapsed, 8)

    def test_non_list_json_cannot_pass(self):
        process, _, _ = self.invoke(responses=[(200, '{"status":"ok"}')])
        self.assert_fail(process)

    def test_malformed_json_cannot_pass(self):
        process, _, _ = self.invoke(responses=[(200, "not-json")])
        self.assert_fail(process)

    def test_invalid_user_shape_cannot_pass(self):
        process, _, _ = self.invoke(responses=[(200, "[{}]")])
        self.assert_fail(process)

    def test_redirect_cannot_pass(self):
        process, _, _ = self.invoke(responses=[(302, "[]")])
        self.assert_fail(process)

    def test_stalled_http_request_is_bounded(self):
        process, _, elapsed = self.invoke(responses=[(200, "[]", 3)])
        self.assert_fail(process)
        self.assertLess(elapsed, 8)

    def test_null_user_item_cannot_pass(self):
        process, _, _ = self.invoke(responses=[(200, "[null]")])
        self.assert_fail(process)

    def test_temporary_api_failure_recovers(self):
        process, observed, _ = self.invoke(responses=[(503, "{}"), (200, "[]")], timeout=4)
        self.assert_pass(process)
        self.assertGreaterEqual(len(observed), 2)

    def test_created_service_is_retried(self):
        rows = running_rows()
        rows[1]["State"] = "created"
        process, _, _ = self.invoke(frames=[rows, running_rows()], timeout=4)
        self.assert_pass(process)

    def test_docker_failure_cannot_pass(self):
        process, _, _ = self.invoke(docker_exit=1)
        self.assert_fail(process)

    def test_unhealthy_service_cannot_pass(self):
        rows = running_rows()
        rows[1]["Health"] = "unhealthy"
        process, _, _ = self.invoke(frames=[rows])
        self.assert_fail(process)


if __name__ == "__main__":
    unittest.main(testRunner=unittest.TextTestRunner(stream=sys.stdout, verbosity=2))