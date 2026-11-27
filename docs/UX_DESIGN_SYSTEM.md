# Nipto UX and Visual Design System

## Brand direction

Nipto should look modern, welcoming and distinctive: a calm neutral canvas, deep ink typography, a confident violet action color and a warm coral highlight used sparingly. Avoid visual clutter and avoid cloning another product's branding or visual assets.

## Design tokens

| Token | Value | Use |
|---|---|---|
| Ink | #101C50 | Primary text and dark surfaces |
| Muted | #737A94 | Secondary labels |
| Canvas | #F7F8FF | Main background |
| Surface | #FFFFFF | Cards and sheets |
| Violet | #5528E8 | Primary actions and active navigation |
| Violet soft | #EDE9FF | Selected navigation and chips |
| Coral | #FF4D9B | Status accents and highlights |
| Brand cyan | #08C9F4 | Start of the logo gradient |
| Brand blue | #0876F8 | Logo gradient |
| Brand magenta | #E516B8 | End of the logo gradient |
| Border | #E9E9F1 | Dividers and input outlines |
| Success | #239B74 | Positive confirmation |
| Danger | #D94B5B | Destructive actions |

These values are the canonical tokens in `mobile/app/lib/theme/nipto_theme.dart` and are locked by `mobile/app/test/nipto_theme_test.dart`.

Typography: system sans-serif, strong page titles, comfortable 14–16sp body text, short labels and no dense paragraphs in core flows.

## Navigation model

Four adjacent destinations in the authenticated shell:
1. Home — approved feed with likes, comments and reports.
2. Chats — inbox, discovery, status tray, direct and group conversations.
3. Shorts — vertical approved video feed with upload and interactions.
4. You — profile, posts, settings, privacy and security.

Use a Material 3 bottom navigation bar as the primary access path. Preserve scroll position when switching tabs.

## Chats screen

Header:
- Nipto wordmark at left.
- Search and compose actions at right.
- Status/story row below the header.
- Search field placeholder: Search by Nipto ID.
- Recent conversations use a compact avatar, display name, short message preview, time and unread marker.
- Empty state should offer one obvious action: find people.

Conversation screen:
- Clear participant identity and online/last-seen state only when allowed by privacy.
- Messages have generous spacing and distinct outgoing/incoming shapes.
- Composer stays anchored above the keyboard.
- Show delivery/read state without dominating the message text.
- Media upload shows progress and retry.

## Shorts screen

- Full-bleed vertical media; no persistent bottom navigation overlay over the video.
- Creator, follow action, caption and interaction rail have safe-area padding.
- Only the foreground video plays. Pause on tab change, app backgrounding and route exit.
- Comments open in a bottom sheet.
- Upload affordance is visible but does not promise a completed publish until upload/moderation state is known.

## Profile screen

- Profile header with avatar, display name, @nipto_id, biography and counts.
- Primary action is Edit profile for self; Follow/Requested/Following for other profiles.
- Grid/Shorts tabs below identity.
- Settings is a separate page with grouped Privacy, Notifications, Security and Account sections.

## Interaction and accessibility

- At least 48dp target size for primary controls.
- Never communicate state by color alone.
- Form validation appears beside the field and retains entered values.
- Keep destructive actions behind confirmation.
- Add loading skeletons for network-backed screens and clear retry states.
- Respect reduced motion and system font scaling.
- Provide text alternatives for icons and media controls.

## Motion

- Tab transitions: short, subtle horizontal motion.
- Like action: brief scale/opacity feedback.
- New message: insert without a large list jump.
- Video page: snap vertically; no autoplay of off-screen clips.
- Avoid long splash animations and layout shifts.
