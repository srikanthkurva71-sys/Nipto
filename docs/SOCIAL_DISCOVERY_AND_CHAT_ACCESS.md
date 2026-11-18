# Nipto Social Discovery and Chat Access

## Product rules

- Account discovery is available independently of follow relationships. Search supports Nipto ID and display-name prefixes.
- Discovery results never disclose email, phone, credential, or recovery information.
- Private accounts show only basic identity fields to unapproved viewers; bio and avatar path are withheld until an accepted follow exists.
- A follow is directional. Following, being followed, and mutual-follow states are distinct.
- Private-account follow requests remain pending until accepted. Pending follows do not grant content access or chat permission.
- Direct conversations appear in the Chats inbox only when at least one side has an accepted follow relationship with the other.
- A direct conversation can be created only when an accepted follow exists in either direction and no block exists.
- Message read/write policies and private chat media reads re-check this connection on the server, so client-side filters are not authorization.
- Removing the follow relationship removes direct-chat access. Group chats remain governed by group membership and block/report controls.
- Search results for disconnected accounts do not show a Message action; the follow action remains available.

## Follow relationship states

| State | Meaning | Chat access |
|---|---|---|
| No relationship | Neither follows the other | No |
| Following | Viewer follows target and follow is accepted | Yes |
| Follower | Target follows viewer and follow is accepted | Yes |
| Mutual | Both accepted follow edges exist | Yes |
| Requested | Follow edge is pending | No |
| Blocked | Either side has blocked the other | No |

## Implementation checkpoint

- Migration: `20261118100000_nipto_connected_chat_access.sql`
- Flutter screen: `mobile/app/lib/screens/chats_screen.dart`
- Static regression tests: `scripts/test_nipto_auth_migration.py`

The migration replaces the direct-conversation creation RPC with a connection gate, restricts direct-message read/write policies, gates private chat media, and changes discovery to return limited fields for private profiles. Ordinary message updates are limited to body/edited timestamp, and hard deletes are revoked; the soft-delete RPC remains the supported path.

## Research-informed principles

Nipto uses familiar social concepts without copying a competitor's implementation:

- Follow/follower lists and private-account approval are separate from account search.
- Temporary updates, short-form video, feed posts, messaging, calls, and Close Friends have separate audiences.
- Message request/connection controls and blocked-user protections should be first-class settings.
- Activity status, location sharing, recommendations, and other sensitive visibility must be opt-in, minimized, and revocable.
- Teen accounts should have protective defaults, with easy controls to report, block, mute, and manage interactions.

## References

- Meta Newsroom, [New Instagram Features to Help You Connect](https://about.fb.com/news/2025/08/new-instagram-features-help-you-connect/), describing reposts, selected location sharing, and friend activity controls.
- eSafety Commissioner, [Instagram guide](https://www.esafety.gov.au/key-topics/esafety-guide/instagram), describing posts, Stories, Reels, Notes, messaging, calls, Close Friends, Explore, and teen-account protections.
- Singapore Online Safety Commission, [Staying Safe on Instagram](https://www.osc.gov.sg/learn-about-online-safety/adults/staying-safe-on-instagram/), describing privacy, interaction controls, audience settings, and content controls.

## Validation status

This feature is source-implemented on the development branch. It is not yet validated by a passing CI run or a disposable staging database. Authorization must be tested with both relationship directions, pending private follows, unfollow, block, group membership, and attempts to call the RPC directly before deployment.
