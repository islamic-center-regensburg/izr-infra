import unittest
from unittest.mock import patch

import stack


class DeploymentReadinessTests(unittest.TestCase):
    def ticket(self, kind="compose"):
        return {
            "kind": kind, "id": "app", "description": "requested",
            "deadline": 100, "app_name": "service", "previous_tasks": {"old"},
        }

    @patch("stack.time.sleep")
    @patch("stack.time.monotonic", return_value=0)
    def test_waits_for_own_queued_deployment_not_old_success(self, clock, sleep):
        with patch("stack.deployment_history", side_effect=[
            [{"description": "old", "status": "done"}],
            [{"description": "requested", "status": "running"}],
            [{"description": "requested", "status": "done"}],
        ]) as history:
            stack.wait_deployment(self.ticket())
        self.assertEqual(history.call_count, 3)
        self.assertEqual(sleep.call_count, 2)

    @patch("stack.time.monotonic", return_value=0)
    def test_deployment_failure_stops_before_rollout(self, clock):
        with patch("stack.deployment_history", return_value=[
            {"description": "requested", "status": "error", "deploymentId": "job"},
        ]), patch("stack.wait_application_rollout") as rollout:
            with self.assertRaisesRegex(stack.DeploymentError, "job.*error"):
                stack.wait_deployment(self.ticket("application"))
            rollout.assert_not_called()

    @patch("stack.time.monotonic", return_value=101)
    def test_missing_queued_job_times_out(self, clock):
        with self.assertRaisesRegex(stack.DeploymentError, "Timed out"):
            stack.wait_deployment(self.ticket())

    @patch("stack.time.sleep")
    @patch("stack.time.monotonic", return_value=0)
    def test_done_build_still_waits_for_replacement_task(self, clock, sleep):
        with patch("stack.remote", side_effect=[
            '{"State":"updating"}', '{"Replicated":{"Replicas":1}}',
            '{"State":"completed"}', '{"Replicated":{"Replicas":1}}',
            '{"State":"completed"}', '{"Replicated":{"Replicas":1}}',
        ]), patch("stack.application_tasks", side_effect=[
            [{"ID": "old", "CurrentState": "Running 10 minutes ago"}],
            [{"ID": "new", "CurrentState": "Starting 1 second ago"}],
            [{"ID": "new", "CurrentState": "Running 1 second ago"}],
        ]):
            stack.wait_application_rollout(self.ticket("application"))
        self.assertEqual(sleep.call_count, 2)

    @patch("stack.time.monotonic", return_value=0)
    def test_rollback_is_not_success(self, clock):
        with patch("stack.remote", return_value='{"State":"rollback_completed"}'):
            with self.assertRaisesRegex(stack.DeploymentError, "rollback_completed"):
                stack.wait_application_rollout(self.ticket("application"))

    @patch("stack.time.monotonic", return_value=0)
    def test_request_marks_job_and_captures_old_tasks_before_post(self, clock):
        with patch("stack.deployment_history", return_value=[]), patch(
            "stack.application_tasks", return_value=[{"ID": "old"}]
        ), patch("stack.remote", return_value="service\n"), patch(
            "stack.api", side_effect=[{"appName": "service"}, None]
        ) as api:
            ticket = stack.request_deployment({"kind": "application", "id": "app"})
        self.assertEqual(ticket["previous_tasks"], {"old"})
        self.assertEqual(api.call_args.args[2]["description"], ticket["description"])
        self.assertTrue(ticket["description"].startswith("izr-stack:"))


if __name__ == "__main__":
    unittest.main()
