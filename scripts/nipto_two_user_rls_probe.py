"""Manual, consented two-user RLS and Storage probe against the live project.

Creates two real Nipto accounts, verifies connected direct-chat visibility,
non-member group isolation, and chat-media Storage policies, then deletes the
Storage objects it created. The Supabase auth users must be deleted by the
operator using the printed IDs after every run.
"""

import base64
import hashlib
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request


BASE = os.environ.get(
    "NIPTO_PROBE_BASE_URL", "https://advmjribduqzyuwktkod.supabase.co"
).rstrip("/")
KEY = os.environ.get(
    "NIPTO_PROBE_PUBLISHABLE_KEY",
    "sb_publishable_zxqki-GLfT6zi-BXT1h6zw_nWq9Nhye",
)
PASSWORD = "NiptoE2E!2026"
PNG_1X1 = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII="
)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class ProbeError(RuntimeError):
    pass


def http(url, method="GET", body=None, headers=None, data=None, content_type=None):
    payload = data
    all_headers = {"apikey": KEY, "Accept": "application/json"}
    if body is not None:
        payload = json.dumps(body).encode("utf-8")
        content_type = "application/json"
    if content_type:
        all_headers["Content-Type"] = content_type
    if headers:
        all_headers.update(headers)
    request = urllib.request.Request(url, data=payload, headers=all_headers, method=method)
    try:
        response = urllib.request.build_opener(NoRedirect).open(request)
        return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def json_http(url, method="GET", body=None, token=None, extra_headers=None, params=None):
    if params:
        url += "?" + urllib.parse.urlencode(params)
    headers = dict(extra_headers or {})
    if token:
        headers["Authorization"] = "Bearer " + token
    status, raw = http(url, method=method, body=body, headers=headers)
    parsed = json.loads(raw.decode("utf-8")) if raw else None
    return status, parsed


def expect_status(label, actual, allowed, detail=None):
    if actual not in allowed:
        suffix = f"; response={detail}" if detail is not None else ""
        raise ProbeError(f"{label}: expected {allowed}, got {actual}{suffix}")


def rest(token, method, table, body=None, token_override=None, params=None):
    status, value = json_http(
        BASE + "/rest/v1/" + table,
        method=method,
        body=body,
        token=token if token_override is None else token_override,
        extra_headers={"Prefer": "return=representation"},
        params=params,
    )
    return status, value


def rpc(token, name, body):
    status, value = json_http(
        BASE + "/rest/v1/rpc/" + name, method="POST", body=body, token=token
    )
    return status, value


def storage_path(*segments):
    return "/".join(urllib.parse.quote(str(segment), safe="") for segment in segments)


def storage(token, method, path, data=None, content_type=None):
    return http(
        BASE + "/storage/v1/object/" + path,
        method=method,
        headers={"Authorization": "Bearer " + token},
        data=data,
        content_type=content_type,
    )


def register(action, nipto_id, password, display_name=None):
    verifier = base64.urlsafe_b64encode(
        hashlib.sha256((nipto_id + action).encode("utf-8")).digest()
    ).decode("utf-8").rstrip("=") + "A" * 43
    verifier = verifier[:86]
    challenge = base64.urlsafe_b64encode(
        hashlib.sha256(verifier.encode("utf-8")).digest()
    ).decode("utf-8").rstrip("=")
    query = urllib.parse.urlencode(
        {
            # supabase_flutter omits client_id here; Supabase adds it on the
            # provider redirect. Exercise the same URL shape as the app.
            "provider": "custom:nipto",
            "redirect_to": "nipto://auth-callback",
            "flow_type": "pkce",
            "code_challenge": challenge,
            "code_challenge_method": "s256",
            "screen": action,
        }
    )
    authorize_url = BASE + "/auth/v1/authorize?" + query
    status, _ = http(authorize_url)
    expect_status(action + " authorize", status, (302,))

    status, raw = http(
        BASE + "/functions/v1/nipto-identity/authorize/prepare",
        method="POST",
        body={"authorize_url": authorize_url},
    )
    expect_status(action + " prepare", status, (200,))
    prepared = json.loads(raw.decode("utf-8"))

    native_body = {
        "action": action,
        "screen": prepared.get("screen", action),
        "client_id": prepared["client_id"],
        "redirect_uri": prepared["redirect_uri"],
        "response_type": prepared["response_type"],
        "scope": prepared["scope"],
        "state": prepared["state"],
        "code_challenge": prepared["code_challenge"],
        "code_challenge_method": "S256",
        "nipto_id": nipto_id,
        "password": password,
    }
    if prepared.get("nonce") is not None:
        native_body["nonce"] = prepared["nonce"]
    if display_name is not None:
        native_body["display_name"] = display_name
        native_body["password_confirmation"] = password
    status, raw = http(
        BASE + "/functions/v1/nipto-identity/authorize/native",
        method="POST",
        body=native_body,
    )
    expect_status(action + " native", status, (200,))
    native = json.loads(raw.decode("utf-8"))

    status, raw = http(
        BASE + "/auth/v1/token?grant_type=pkce",
        method="POST",
        body={"auth_code": native["code"], "code_verifier": verifier},
    )
    expect_status(action + " token", status, (200,))
    token = json.loads(raw.decode("utf-8"))

    status, user = json_http(
        BASE + "/auth/v1/user", method="GET", token=token["access_token"]
    )
    expect_status(action + " user", status, (200,))
    claim = user.get("user_metadata", {}).get("custom_claims", {}).get("nipto_id")
    if claim != nipto_id:
        raise ProbeError(action + ": missing native nipto_id claim")
    if user.get("email") not in (None, ""):
        raise ProbeError(action + ": probe account unexpectedly has an email")
    return user["id"], token["access_token"]


def main():
    suffix = str(int(time.time() * 1000))
    id_a = "rlsa" + suffix
    id_b = "rlsb" + suffix
    storage_objects = []
    user_ids = []
    token_a = None
    try:
        a, token_a = register("register", id_a, PASSWORD, "RLS Probe A")
        user_ids.append(a)
        b, token_b = register("register", id_b, PASSWORD, "RLS Probe B")
        user_ids.append(b)
        print("TWO_USER_PROBE_A", id_a, a)
        print("TWO_USER_PROBE_B", id_b, b)

        # The follow-state guard derives the initial status from the target
        # profile's privacy. Clients only have INSERT on the two identity
        # columns, so sending `status` here would be rejected as a 403.
        status, follow_result = rest(
            token_a,
            "POST",
            "follows",
            {"follower_id": a, "following_id": b},
        )
        expect_status("follow insert", status, (201,), follow_result)
        status, _ = rest(
            token_b,
            "PATCH",
            "follows",
            {"status": "accepted"},
            params={"follower_id": "eq." + a, "following_id": "eq." + b},
        )
        expect_status("follow accept", status, (200,))

        status, direct = rpc(
            token_a, "create_or_get_direct_conversation", {"p_other_user": b}
        )
        expect_status("direct conversation", status, (200,))
        direct_id = direct if isinstance(direct, str) else direct["id"]

        status, sent = rest(
            token_a,
            "POST",
            "messages",
            {
                "conversation_id": direct_id,
                "sender_id": a,
                "message_type": "text",
                "body": "two-user RLS probe",
            },
        )
        expect_status("direct message insert", status, (201,))
        status, visible = rest(
            token_b,
            "GET",
            "messages",
            params={
                "conversation_id": "eq." + direct_id,
                "select": "id,body",
            },
        )
        expect_status("direct message read by member", status, (200,))
        if not any(row.get("id") == sent[0]["id"] for row in visible):
            raise ProbeError("connected member could not read the direct message")
        status, _ = rest(
            None,
            "GET",
            "messages",
            token_override="",
            params={"conversation_id": "eq." + direct_id, "select": "id"},
        )
        expect_status("anonymous message read", status, (401, 403))

        # Group invitations honor the invitee's message-access preference,
        # which defaults to mutual accepted follows. Direct chat only needs
        # one accepted follow, so establish the reciprocal follow here.
        status, _ = rest(
            token_b,
            "POST",
            "follows",
            {"follower_id": b, "following_id": a},
        )
        expect_status("reciprocal follow insert", status, (201,))
        status, _ = rest(
            token_a,
            "PATCH",
            "follows",
            {"status": "accepted"},
            params={"follower_id": "eq." + b, "following_id": "eq." + a},
        )
        expect_status("reciprocal follow accept", status, (200,))

        status, group = rpc(
            token_a,
            "create_group_conversation",
            {"p_title": "RLS probe group", "p_member_ids": [b]},
        )
        expect_status("group conversation", status, (200,), group)
        group_id = group if isinstance(group, str) else group["id"]
        status, _ = rest(
            token_a,
            "POST",
            "messages",
            {
                "conversation_id": group_id,
                "sender_id": a,
                "message_type": "text",
                "body": "non-member isolation probe",
            },
        )
        expect_status("group message insert", status, (201,))
        status, hidden = rest(
            token_b,
            "GET",
            "messages",
            params={"conversation_id": "eq." + group_id, "select": "id"},
        )
        expect_status("group message read by invitee", status, (200,))
        if hidden:
            raise ProbeError("unaccepted group invitee could read group messages")

        direct_media = storage_path("chat-media", direct_id, a, suffix + ".png")
        status, _ = storage(
            token_a, "POST", direct_media, data=PNG_1X1, content_type="image/png"
        )
        expect_status("direct media upload", status, (200, 201))
        storage_objects.append(direct_media)
        status, _ = rest(
            token_a,
            "POST",
            "messages",
            {
                "conversation_id": direct_id,
                "sender_id": a,
                "message_type": "image",
                "media_path": direct_media,
            },
        )
        expect_status("direct media message insert", status, (201,))

        group_media = storage_path("chat-media", group_id, a, str(int(suffix) + 1) + ".png")
        status, _ = storage(
            token_a, "POST", group_media, data=PNG_1X1, content_type="image/png"
        )
        expect_status("group media upload", status, (200, 201))
        storage_objects.append(group_media)
        status, _ = rest(
            token_a,
            "POST",
            "messages",
            {
                "conversation_id": group_id,
                "sender_id": a,
                "message_type": "image",
                "media_path": group_media,
            },
        )
        expect_status("group media message insert", status, (201,))

        status, body = storage(token_b, "GET", direct_media)
        expect_status("direct media read by member", status, (200,))
        if body != PNG_1X1:
            raise ProbeError("connected member read unexpected media bytes")
        status, _ = storage(token_b, "GET", group_media)
        expect_status("group media read by invitee", status, (403, 404))
        status, _ = storage(token_a, "GET", group_media)
        expect_status("group media read by owner", status, (200,))
        print("TWO_USER_RLS_STORAGE_PASS")
    finally:
        if token_a:
            for object_path in storage_objects:
                status, _ = storage(token_a, "DELETE", object_path)
                if status not in (200, 204):
                    print("TWO_USER_STORAGE_CLEANUP_FAILED", object_path, status)
        print("TWO_USER_CLEANUP_AUTH_USER_IDS", ",".join(user_ids))


if __name__ == "__main__":
    main()
