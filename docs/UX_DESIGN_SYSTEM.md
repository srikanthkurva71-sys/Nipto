# Nipto UX and Visual Design System

## Brand direction

Nipto should look modern, welcoming and distinctive: a calm neutral canvas, deep ink typography, a confident violet action color and a warm coral highlight used sparingly. Avoid visual clutter and avoid cloning another product's branding or visual assets.

## Design tokens

| Token | Value | Use |
|---|---|---|
| Ink | #171827 | Primary text and dark surfaces |
| Muted | #777A8C | Secondary labels |
| Canvas | #F7F7FB | Main background |
| Surface | #FFFFFF | Cards and sheets |
| Violet | #6657E8 | Primary actions and active navigation |
| Violet soft | #ECEAFF | Selected navigation and chips |
| Coral | #FF806B | Status accents and highlights |
| Border | #E9E9F1 | Dividers and input outlines |
| Success | #239B74 | Positive confirmation |
| Danger | #D94B5B | Destructive actions |

Typography: system sans-serif, strong page titles, comfortable 14–16sp body text, short labels and no dense paragraphs in core flows.

## Navigation model

Three adjacent swipeable destinations:
1. Chats
2. Shorts
3. You

Use a Material 3 bottom navigation bar as a second access path. A swipe changes the selected destination and the navigation bar follows it. Preserve scroll position when switching tabs.

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
