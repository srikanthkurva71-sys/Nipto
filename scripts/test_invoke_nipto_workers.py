import unittest
from unittest import mock

import invoke_nipto_workers as workers


class FakeResponse:
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False


class FakeOpener:
    def __init__(self, status: int = 200):
        self.status = status
        self.request = None
        self.timeout = None

    def __call__(self, request, timeout):
        self.request = request
        self.timeout = timeout
        response = FakeResponse()
        response.status = self.status
        return response


class InvokeNiptoWorkersTests(unittest.TestCase):
    def test_build_request_uses_worker_endpoint_and_secret_header(self):
        request = workers.build_request("push", "test-secret")
        self.assertEqual(request.full_url, workers.WORKERS["push"])
        self.assertEqual(request.get_header("Authorization"), "Bearer test-secret")
        self.assertEqual(request.get_header("Apikey"), workers.PUBLISHABLE_KEY)
        self.assertEqual(request.data, b"{}")

    def test_privacy_worker_uses_bounded_body(self):
        request = workers.build_request("privacy", "test-secret")
        self.assertEqual(request.data, b'{"limit": 5}')

    def test_missing_secret_is_rejected(self):
        with self.assertRaises(workers.InvocationError):
            workers.build_request("push", "")

    def test_invoke_returns_http_status_without_logging_body(self):
        opener = FakeOpener(200)
        status = workers.invoke("push", "test-secret", opener=opener)
        self.assertEqual(status, 200)
        self.assertEqual(opener.timeout, 60.0)
        self.assertIsNotNone(opener.request)

    def test_invoke_returns_error_status(self):
        opener = FakeOpener(401)
        self.assertEqual(workers.invoke("privacy", "test-secret", opener=opener), 401)

    def test_main_invokes_all_workers(self):
        with (
            mock.patch.object(workers, "resolve_secret", return_value="test-secret"),
            mock.patch.object(workers, "invoke", side_effect=[200, 200]) as invoke,
            mock.patch("sys.stdout.write") as write,
        ):
            result = workers.main(["--all"])
        self.assertEqual(result, 0)
        self.assertEqual(invoke.call_count, 2)
        output = "".join(call.args[0] for call in write.call_args_list)
        self.assertIn("push: HTTP 200", output)
        self.assertIn("privacy: HTTP 200", output)

    def test_main_fails_when_any_worker_fails(self):
        with (
            mock.patch.object(workers, "resolve_secret", return_value="test-secret"),
            mock.patch.object(workers, "invoke", side_effect=[200, 503]),
            mock.patch("sys.stdout.write"),
        ):
            result = workers.main(["--all"])
        self.assertEqual(result, 1)


if __name__ == "__main__":
    unittest.main()
