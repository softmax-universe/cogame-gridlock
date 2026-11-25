#!/usr/bin/env python3
"""Run mixed Gridlock players against a local native model fixture (zero receipt authority)."""

import http.server
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class ModelHandler(http.server.BaseHTTPRequestHandler):
    calls = []

    def do_POST(self):
        data = self.rfile.read(int(self.headers["Content-Length"]))
        request = json.loads(data)
        if self.path == "/v1/messages":
            body = {
                "id": "fixture-mixed-player",
                "model": "fixture/served",
                "stop_reason": "end_turn",
                "content": [
                    {
                        "type": "text",
                        "text": json.dumps(
                            {
                                "congestion_weight": 80,
                                "patience": 20,
                                "dispatch": 20,
                                "spread": 90,
                                "corridor": None,
                                "avoid": [1, 1],
                                "priority": "far",
                                "note": "Stub prompt plan",
                                "say": "route around jams",
                            }
                        ),
                    }
                ],
            }
            self.calls.append(("prompt", None, request))
        else:
            self.send_error(404)
            return
        payload = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_args):
        pass


def play(game_bin, player_bin, scenario):
    ModelHandler.calls.clear()
    model_port = free_port()
    game_port = free_port()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", model_port), ModelHandler)
    thread = threading.Thread(target=server.serve_forever)
    with server, tempfile.TemporaryDirectory(prefix="gridlock-player-smoke-") as work:
        directory = Path(work)
        config = {
            "promptVariant": "mixed",
            "promptSeed": 4,
            "tokens": [f"token-{slot}" for slot in range(4)],
            "players": [{"name": f"P{slot + 1}"} for slot in range(4)],
            "num_agents": 4,
            "seed": 42,
            "episodeTicks": 480,
            "turnTicks": 240,
            "minTurnSpacingSeconds": 2 if scenario == "disconnect" else 0,
            "playerConnectTimeoutSeconds": 1 if scenario == "missing" else 5,
            "wallClockBudgetSeconds": 90,
            "episodeTimeoutSeconds": 180,
            "cityPath": "gridcity",
        }
        (directory / "config.json").write_text(json.dumps(config))
        env = os.environ.copy()
        for name in (
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_API_KEY_URI",
            "METTA_CAPTURE_URL",
            "METTA_CAPTURE_KEY",
            "COWORLD_LLM_ENDPOINT",
            "AWS_BEARER_TOKEN_BEDROCK",
        ):
            env.pop(name, None)
        game_env = env | {
            "COGAME_HOST": "127.0.0.1",
            "COGAME_PORT": str(game_port),
            "COGAME_CONFIG_URI": f"file://{directory / 'config.json'}",
            "COGAME_RESULTS_URI": f"file://{directory / 'results.json'}",
            "COGAME_SAVE_REPLAY_URI": f"file://{directory / 'replay.json'}",
            "COGAME_PLAYER_FAILURE_URI": (directory / "player-failure.json").as_uri(),
        }
        processes = []
        thread.start()
        try:
            processes.append(
                subprocess.Popen(
                    [game_bin],
                    env=game_env,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                )
            )
            ready = False
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                with socket.socket() as probe:
                    ready = probe.connect_ex(("127.0.0.1", game_port)) == 0
                if ready:
                    break
                assert processes[0].poll() is None, "game exited before readiness"
                time.sleep(0.02)
            assert ready, "game socket never opened"
            for slot in range(0 if scenario == "missing" else 4):
                player_env = env | {
                    "COWORLD_PLAYER_WS_URL": (f"ws://127.0.0.1:{game_port}/player?slot={slot}&token=token-{slot}")
                }
                if slot < 2:
                    player_env["COWORLD_LLM_ENABLED"] = "true"
                    player_env["COWORLD_LLM_MODEL"] = "fixture/requested"
                    player_env["PLAYER_PROMPT"] = "Route around traffic and meter vans."
                    player_env["COWORLD_LLM_ENDPOINT"] = f"http://127.0.0.1:{model_port}"
                else:
                    player_env["PLAYER_SCRIPTED"] = "dispatcher"
                processes.append(
                    subprocess.Popen(
                        [player_bin],
                        env=player_env,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT,
                    )
                )
            if scenario == "disconnect":
                deadline = time.monotonic() + 25
                while not ModelHandler.calls and time.monotonic() < deadline:
                    time.sleep(0.01)
                assert ModelHandler.calls, "model seat never received a decision"
                processes[1].terminate()
                processes[1].wait(timeout=5)
            if scenario in ("missing", "disconnect"):
                game_log, _ = processes[0].communicate(timeout=40)
                assert (directory / "player-failure.json").exists(), game_log.decode(errors="replace")
                results_path = directory / "results.json"
                if results_path.exists():
                    results = json.loads(results_path.read_text())
                    assert results["reason"] != "complete", game_log
                    assert results["scores"] == [None] * 4, results
                    assert results["winner"] is None and not any(results["win"]), results
                if scenario == "missing":
                    assert not ModelHandler.calls
                print(f"Gridlock {scenario} roster was unscored")
                return
            outputs = []
            for process in processes:
                output, _ = process.communicate(timeout=75)
                outputs.append(output.decode(errors="replace"))
                assert process.returncode == 0, output.decode(errors="replace")
            results = json.loads((directory / "results.json").read_text())
            replay = json.loads((directory / "replay.json").read_text())
            assert results["reason"] == "complete", results
            assert results["turns_llm"][:2] == [2, 2], results["turns_llm"]
            assert results["fallback_turns"] == [0, 0, 0, 0], results["fallback_turns"]
            assert results["policy_kinds"] == ["llm", "llm", "scripted", "scripted"]
            assert replay["results"]["turns_llm"][:2] == [2, 2]
            prompt_calls = [call for call in ModelHandler.calls if call[0] == "prompt"]
            assert len(prompt_calls) == 4, len(prompt_calls)
            for _, _, request in prompt_calls:
                assert "Earn one point for each parcel" in request["system"]
            print("Gridlock mixed native episode: 4 prompt plans accepted; zero fallback")
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=5)
            server.shutdown()
            thread.join(timeout=2)
            assert not thread.is_alive()


def certify(manifest, docker_host):
    from coworld.certifier import certify_coworld
    from coworld.runner.runner import run_coworld_episode

    with http.server.ThreadingHTTPServer(("0.0.0.0", 0), ModelHandler) as server:
        threading.Thread(target=server.serve_forever, daemon=True).start()
        endpoint = f"http://{docker_host}:{server.server_port}"

        def run_roster(job, artifacts, timeout):
            model_slots = {
                slot: {"COWORLD_LLM_ENDPOINT": endpoint}
                for slot, player in enumerate(job.players)
                if player.env.get("COWORLD_LLM_ENABLED") == "true"
            }
            run_coworld_episode(
                job, artifacts, timeout_seconds=timeout,
                player_secret_env=model_slots, require_websocket_pong=True,
            )

        result = certify_coworld(Path(manifest), timeout_seconds=300, episode_runner=run_roster)
        print(f"Certified {len(result.step_results)} steps; artifacts in {result.artifacts.workspace}")
        server.shutdown()


if __name__ == "__main__":
    if sys.argv[1] == "--certify":
        certify(*sys.argv[2:])
    else:
        for scenario in ("complete", "missing", "disconnect"):
            play(sys.argv[1], sys.argv[2], scenario)
