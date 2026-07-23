from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]
EXPECTED_MODEL = '--config \'model="gpt-5.6-sol"\''
EXPECTED_EFFORT = "--config model_reasoning_effort=medium"
EXPECTED_PLANNER_MODEL = "planner_model: gpt-5.6-sol"
EXPECTED_EXECUTION_MODEL = "default_execution_model: gpt-5.3-codex-spark"
EXPECTED_HANDOFF_MARKER = "loophony-handoff:v1"


class CodexModelDefaultsTest(unittest.TestCase):
    def test_all_bundled_workflows_pin_codex_model_and_effort(self) -> None:
        for relative_path in ("quant/WORKFLOW.md", "elixir/WORKFLOW.md"):
            with self.subTest(workflow=relative_path):
                workflow = (ROOT / relative_path).read_text()
                self.assertIn(EXPECTED_MODEL, workflow)
                self.assertIn(EXPECTED_EFFORT, workflow)
                self.assertIn(EXPECTED_PLANNER_MODEL, workflow)
                self.assertIn(EXPECTED_EXECUTION_MODEL, workflow)
                self.assertIn(EXPECTED_HANDOFF_MARKER, workflow)
                self.assertNotIn("agents.default_subagent_model", workflow)


if __name__ == "__main__":
    unittest.main()
