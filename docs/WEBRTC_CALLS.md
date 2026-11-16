# Nipto Live Calls — WebRTC Architecture

Status: architecture baseline; implementation and deployment are not yet complete.

## Product scope

Nipto will support real-time voice and video calls from direct conversations. The initial release target is one-to-one audio and video. Group calls are a later phase and require an SFU media server; do not attempt multi-party mesh calls as a production design.

## Media and signaling architecture

- **Media plane:** WebRTC peer connections carry encrypted audio/video directly where possible.
- **NAT traversal:** use STUN for candidate discovery and a production TURN service (UDP plus TCP/TLS fallback) for restrictive networks. TURN credentials must be short-lived and minted by a trusted server/Edge Function. Never ship static TURN secrets in Flutter.
- **Signaling plane:** use authenticated, private Supabase Realtime channels scoped to a call ID. Exchange SDP offer/answer and ICE candidates over signaling only; do not store SDP or ICE payloads in public tables or notifications.
- **Call control:** persist minimal call lifecycle metadata (caller, callee, conversation, state, timestamps, end reason) so devices can recover UI state and enforce membership. Do not persist media.
- **Push:** use push only to wake/notify the callee; the callee must authenticate and join the private signaling channel before receiving signaling.
- **Group calls:** introduce an SFU (for example, a managed WebRTC SFU) with capacity limits, regional routing and server-side participant authorization. Do not use client-mesh fan-out for production group video.

## Call lifecycle

1. Caller starts a call from an accepted direct conversation.
2. Backend validates caller membership, callee membership, active account state, block state and call rate limits.
3. Backend creates a short-lived ringing call session and emits an incoming-call notification without SDP/ICE or secrets.
4. Callee accepts or declines. Only the invited callee can accept; either participant can end.
5. Both clients join a private call signaling channel and exchange offer/answer and trickled ICE candidates.
6. Clients establish the peer connection, request camera/microphone permission only after a user action, and display explicit mute/camera/hang-up controls.
7. End, decline, timeout, disconnect and app-background transitions converge on an idempotent terminal state. Expired ringing sessions are cleaned up server-side.

## Security and privacy requirements

- Private channel authorization must check authenticated user identity against the call's two participants on every join.
- Re-check accepted conversation membership, account state and blocks when creating a call; do not trust client-supplied participant IDs.
- Only the invited callee can accept. A participant cannot forge another participant's state or terminate unrelated calls.
- Use short-lived, single-purpose TURN credentials; never expose service-role keys or TURN shared secrets to the app.
- WebRTC DTLS-SRTP encrypts media in transit. Document that TURN relays encrypted packets but can observe connection metadata; avoid claiming end-to-end encryption beyond the WebRTC security properties actually verified.
- Do not record calls by default. Any future recording requires a separate explicit consent flow and legal/privacy review.
- Add per-user and per-target call rate limits, spam controls, block enforcement, abuse reporting and clear permission-denied handling.
- Never auto-enable camera or microphone on incoming call acceptance without a clear user action and OS permission.
- Avoid leaking SDP, ICE candidates, IP addresses, tokens or TURN credentials to analytics, logs, crash reports or push payloads.

## Flutter implementation requirements

- Use a maintained Flutter WebRTC plugin and pin a reviewed compatible version.
- Implement a call service/repository separate from widgets; keep signaling, peer-connection lifecycle and call state out of screen build methods.
- Handle permission denial, Bluetooth/audio route changes, speaker toggle, mute, camera switch, camera-off, network handoff, app lifecycle, remote track removal and peer-connection failure.
- Dispose tracks, renderers, peer connections and Realtime subscriptions on every terminal path.
- Add call UI for outgoing ringing, incoming call, connecting, active audio/video, reconnecting, declined, missed and ended states.
- Provide accessible controls and a voice-only fallback when camera permission is unavailable.
- Add tests for call authorization, state transitions, duplicate events, timeout, reconnect, blocks, rejected invites and resource cleanup.

## Release gates

- Choose and configure a TURN provider; verify UDP and TCP/TLS relay from mobile networks.
- Configure private Realtime channel authorization and test cross-user isolation.
- Add secure server-side call creation/accept/end operations and call rate limits.
- Complete two-physical-device tests on Wi-Fi, mobile data, restrictive NAT and background/foreground transitions.
- Verify Android microphone/camera permissions, audio routing, interruption handling and battery/network behavior.
- Complete privacy policy, Play Console permission declarations and incident/abuse handling.
- Group calls remain out of scope until an SFU is deployed and load-tested.

## Explicit non-goals for the first calling milestone

- No recording, transcription or call analytics containing media or network identifiers.
- No public call rooms or arbitrary user-ID dialing.
- No group video mesh.
- No static TURN credentials embedded in the APK.
