import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "loophony_watchdog.py"
SPEC = importlib.util.spec_from_file_location("loophony_watchdog", SCRIPT)
WATCHDOG = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(WATCHDOG)


class WatchdogTest(unittest.TestCase):
    def test_healthy_service_is_not_restarted(self):
        restarts = []
        result = WATCHDOG.run_watchdog(
            "http://localhost",
            "service",
            fetcher=lambda _url: {"state": {"running": []}},
            restarter=restarts.append,
        )
        self.assertEqual(result["status"], "healthy")
        self.assertFalse(result["restarted"])
        self.assertEqual(restarts, [])

    def test_single_transient_failure_is_rechecked_without_restart(self):
        calls = []
        restarts = []

        def fetcher(_url):
            calls.append(1)
            if len(calls) == 1:
                raise TimeoutError("timed out")
            return {"state": {"running": []}}

        result = WATCHDOG.run_watchdog(
            "http://localhost",
            "service",
            failure_threshold=2,
            delay_seconds=0,
            fetcher=fetcher,
            restarter=restarts.append,
        )
        self.assertEqual(result["status"], "recovered")
        self.assertFalse(result["restarted"])
        self.assertEqual(len(calls), 2)
        self.assertEqual(restarts, [])

    def test_failed_health_is_restarted_and_rechecked(self):
        calls = []
        restarts = []

        def fetcher(_url):
            calls.append(1)
            if len(calls) <= 2:
                raise OSError("connection refused")
            return {"state": {"running": []}}

        result = WATCHDOG.run_watchdog(
            "http://localhost",
            "service",
            attempts=1,
            delay_seconds=0,
            fetcher=fetcher,
            restarter=restarts.append,
        )
        self.assertEqual(result["status"], "recovered")
        self.assertTrue(result["restarted"])
        self.assertEqual(len(calls), 3)
        self.assertEqual(restarts, ["service"])

    def test_threshold_one_preserves_immediate_restart(self):
        calls = []
        restarts = []

        def fetcher(_url):
            calls.append(1)
            if len(calls) == 1:
                raise OSError("connection refused")
            return {"state": {"running": []}}

        result = WATCHDOG.run_watchdog(
            "http://localhost",
            "service",
            attempts=1,
            delay_seconds=0,
            failure_threshold=1,
            fetcher=fetcher,
            restarter=restarts.append,
        )
        self.assertTrue(result["restarted"])
        self.assertEqual(len(calls), 2)
        self.assertEqual(restarts, ["service"])

    def test_invalid_failure_threshold_does_not_probe_or_restart(self):
        calls = []
        restarts = []

        with self.assertRaisesRegex(ValueError, "failure_threshold"):
            WATCHDOG.run_watchdog(
                "http://localhost",
                "service",
                failure_threshold=0,
                fetcher=lambda url: calls.append(url),
                restarter=restarts.append,
            )

        self.assertEqual(calls, [])
        self.assertEqual(restarts, [])

    def test_fetch_health_accepts_direct_state_payload(self):
        normalized = {"state": {"polling": {}, "running": []}}
        self.assertEqual(normalized["state"]["running"], [])

    def test_failed_recheck_returns_failure(self):
        calls = []
        restarts = []

        def fetcher(_url):
            calls.append(1)
            raise OSError("down")

        with self.assertRaisesRegex(RuntimeError, "remained unhealthy"):
            WATCHDOG.run_watchdog(
                "http://localhost",
                "service",
                attempts=2,
                delay_seconds=0,
                failure_threshold=2,
                fetcher=fetcher,
                restarter=restarts.append,
            )

        self.assertEqual(len(calls), 4)
        self.assertEqual(restarts, ["service"])


if __name__ == "__main__":
    unittest.main()
