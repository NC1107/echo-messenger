# iOS Push Notifications (APNs) Setup

Echo uses Apple Push Notification service (APNs) to wake the iOS app when messages arrive while it's backgrounded. Only **silent pushes** are sent -- no message content ever touches Apple's servers. The app wakes, reconnects to your Echo server via WebSocket, and fetches messages over the encrypted channel.

Push notifications are **optional**. If not configured, iOS users still receive messages when they open the app (the WebSocket reconnects automatically). Android uses a foreground service and doesn't need push.

## Prerequisites

- An [Apple Developer account](https://developer.apple.com) ($99/year)
- The iOS app signed with your team's provisioning profile
- Access to the server where the Echo Rust server runs

## Step 1: Create an APNs Key

1. Go to [developer.apple.com/account](https://developer.apple.com/account)
2. Navigate to **Certificates, Identifiers & Keys** > **Keys**
3. Click **+** to create a new key
4. Name it (e.g., `Echo APNs Key`)
5. Check **Apple Push Notifications service (APNs)**
6. Click **Continue** > **Register**
7. **Download the `.p8` file** -- Apple only lets you download it once
8. Note the **Key ID** (10-character string shown on the page)
9. Note your **Team ID** (visible in the top-right of the portal or under Membership)

## Step 2: Enable Push on Your App ID

1. In the Apple Developer portal, go to **Identifiers**
2. Find your app ID (e.g., `us.echomessenger.app`)
3. Click it > scroll to **Capabilities**
4. Check **Push Notifications**
5. Click **Save**

You do NOT need to create SSL certificates -- the `.p8` key handles authentication.

## Step 3: Configure the Server

Set these environment variables on your Echo server:

```bash
# Base64-encode the .p8 file and use as env var (recommended for Docker)
APNS_AUTH_KEY_BASE64=$(base64 -w0 AuthKey_XXXXXXXXXX.p8)

# Or provide the file path directly
# APNS_AUTH_KEY_PATH=/etc/echo/AuthKey_XXXXXXXXXX.p8

# From Step 1
APNS_KEY_ID=XXXXXXXXXX
APNS_TEAM_ID=XXXXXXXXXX

# Your iOS app's bundle identifier
APNS_TOPIC=us.echomessenger.app
```

For Docker deployments, add these to your `docker-compose.prod.yml` environment section or use Docker secrets.

The server loads the config once at startup. If any required variable is missing, push is silently disabled and the server logs: `APNs disabled: no APNS_AUTH_KEY_BASE64 or APNS_AUTH_KEY_PATH set`.

## Step 4: Verify

1. Deploy the updated server and iOS app
2. Log in on the iOS device
3. Background the app
4. Send a message from another device
5. Check server logs for: `APNs push sent to user {uuid}`
6. The iOS app should wake and show the message when opened

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Server logs `APNs disabled` | Missing env vars | Set `APNS_AUTH_KEY_BASE64` + `APNS_KEY_ID` + `APNS_TEAM_ID` |
| Server logs `APNs push failed (403)` | Bad JWT -- wrong key/team ID | Verify `APNS_KEY_ID` and `APNS_TEAM_ID` match your Apple portal |
| Server logs `APNs token invalid (410)` | Stale device token | Normal -- token auto-removed from DB. User will re-register on next launch. |
| No push attempt in logs | User has no registered push token | Ensure the iOS app requested notification permission and the token was sent to `/api/push/register` |
| Push sent but app doesn't wake | iOS killed the app or battery saver | Normal iOS behavior -- silent pushes are best-effort. App will reconnect on next foreground. |

## Self-Hosting Notes

The APNs key is tied to your Apple Developer account. If you self-host and want iOS push:

1. Fork the iOS app and sign it with your own Apple Developer account
2. Create your own APNs key following the steps above
3. Set the env vars on your server

If you only use web/desktop/Android clients, you don't need any of this -- just leave the env vars unset.
