import json
from pathlib import Path
import tempfile
import unittest

import setup_nipto_credentials as setup


class SetupNiptoCredentialsTests(unittest.TestCase):
    def test_env_round_trip_keeps_json_values(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ".env.local"
            value = json.dumps({"type": "service_account", "project_id": "nipto"})
            setup.write_env(path, {"FCM_SERVICE_ACCOUNT_JSON": value})
            self.assertEqual(setup.read_env(path)["FCM_SERVICE_ACCOUNT_JSON"], value)
            self.assertIn("# Local Nipto credential file", path.read_text(encoding="utf-8"))

    def test_env_quote_rejects_single_quotes(self):
        with self.assertRaises(setup.CredentialSetupError):
            setup._quote("it's invalid for the simple env parser")

    def test_extract_google_services_requires_nipto_package(self):
        other_app = {
            "project_info": {
                "project_id": "nipto-test",
                "project_number": "123456789",
                "storage_bucket": "nipto-test.appspot.com",
            },
            "client": [
                {
                    "client_info": {
                        "mobilesdk_app_id": "1:123456789:android:abc",
                        "android_client_info": {"package_name": "com.example.other"},
                    },
                    "api_key": [{"current_key": "public-key"}],
                }
            ],
        }
        with self.assertRaises(setup.CredentialSetupError):
            setup.extract_google_services(other_app)

    def test_extract_google_services_returns_build_defines(self):
        config = {
            "project_info": {
                "project_id": "nipto-test",
                "project_number": "123456789",
                "storage_bucket": "nipto-test.appspot.com",
            },
            "client": [
                {
                    "client_info": {
                        "mobilesdk_app_id": "1:123456789:android:abc",
                        "android_client_info": {"package_name": setup.ANDROID_PACKAGE},
                    },
                    "api_key": [{"current_key": "public-key"}],
                }
            ],
        }
        extracted = setup.extract_google_services(config)
        self.assertEqual(extracted["NIPTO_FIREBASE_PROJECT_ID"], "nipto-test")
        self.assertEqual(
            extracted["NIPTO_FIREBASE_MESSAGING_SENDER_ID"], "123456789"
        )
        self.assertEqual(
            extracted["NIPTO_FIREBASE_ANDROID_PACKAGE_NAME"], setup.ANDROID_PACKAGE
        )

    def test_service_account_validation(self):
        valid = {
            "type": "service_account",
            "project_id": "nipto-test",
            "client_email": "push@nipto-test.iam.gserviceaccount.com",
            "private_key": "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n",
        }
        self.assertEqual(setup.validate_service_account(valid), "nipto-test")
        with self.assertRaises(setup.CredentialSetupError):
            setup.validate_service_account({"type": "authorized_user"})


if __name__ == "__main__":
    unittest.main()
