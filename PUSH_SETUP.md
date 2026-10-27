# Friend-event push notifications

Bulletin now has the complete client side of friend-event notifications:

- Requests notification permission on app open when the person has not chosen yet.
- Registers the APNs device token and stores it under the signed-in account.
- Publishes the account IDs of matched friends (never names, phone numbers, or photos) so the server knows who should hear about an organizer's new event.
- Stores the person's selected search center and radius so the server can apply the same "nearby" rule as the feed.
- Shows the alert even when the app is open.
- Opens the event detail when the notification is tapped, including a cold launch.
- Adds an Notifications section in Settings with the current status and a shortcut to iOS Settings when permission is off.

The server side is in `functions/`. It must be deployed once before closed-app delivery works.

## Why a server is required

iOS will not let an app send a push to another device by itself. The organizer's phone would need the APNs credentials and every friend's device token, and embedding the APNs key in the app would be a serious security problem. The included Cloud Function watches `events/{eventId}`, finds people who matched the organizer, filters by their notification area, and sends the alert through APNs.

## Prerequisites

1. **Apple Developer Program** membership for team `DB2H5XRWM3`.
2. **Push Notifications capability** enabled for the App ID `com.beanllc.Bulletin`.
3. An **APNs Auth Key** (`.p8`) created in the Apple Developer portal. Save the Key ID and your Team ID. You can only download the key once.
4. **Firebase Blaze plan** for project `bulletinback-63a08`. Cloud Functions and Secret Manager require billing to be enabled. Usage for a small app is normally well inside the free allowance, but a card must be on file.
5. **Node.js 20** and the **Firebase CLI** on the machine doing the deploy.
   ```sh
   brew install node@20
   npm install -g firebase-tools
   ```

## One-time deploy

From the repository root:

```sh
firebase login
firebase use bulletinback-63a08
cd functions
npm install
cd ..
```

Store the APNs credentials as Cloud Functions secrets. The `.p8` file must not be committed.

```sh
firebase functions:secrets:set APNS_KEY --data-file=/absolute/path/AuthKey_ABC123XYZ.p8
firebase functions:secrets:set APNS_KEY_ID
firebase functions:secrets:set APNS_TEAM_ID
firebase functions:secrets:set APNS_BUNDLE_ID
# APNS_BUNDLE_ID: com.beanllc.Bulletin
```

Deploy the database rules and the function:

```sh
firebase deploy --only database,functions
```

The function is `notifyFriendsOfNewEvent` in `us-central1`. It uses:
- `public/friendSubscriptions/{recipientUid}/{organizerUid} = true`
- `users/{recipientUid}/notificationArea`
- `users/{recipientUid}/pushTokens/{token}`

Only the owner can write those nodes. The function reads them with admin privileges.

## Xcode setup

The project already contains:

- `Bulletin/Bulletin.entitlements` with `aps-environment = $(APS_ENVIRONMENT)`
- `APS_ENVIRONMENT = development` for Debug and `production` for Release
- `CODE_SIGN_ENTITLEMENTS = Bulletin/Bulletin.entitlements`
- The Push Notifications system capability

If Xcode reports a signing error, open the target's **Signing & Capabilities** tab, confirm the team is `DB2H5XRWM3`, and add **Push Notifications** if it is not shown. Automatic signing should then create or update the provisioning profile.

> The simulator can show the permission prompt and receive a simulated payload with `xcrun simctl push`, but it cannot receive a real APNs alert. Use a physical device for end-to-end testing.

## Testing with two accounts

1. Install the app on two physical devices (or one device and one authenticated simulator for the in-app side).
2. Sign in on both accounts, add a phone number to each, and grant Contacts access.
3. Grant Notifications on the recipient device.
4. Make sure the two accounts match as friends (pull to refresh the feed or use **Settings → Refresh friend matches**).
5. On the organizer account, create an event within the recipient's selected radius.
6. The recipient should get **“Your friend created an event”** with the event title and description.
7. Tap it. The app should open that event's detail page, even if the app was terminated.

If nothing arrives:

- Check `firebase functions:log` for `Event ...: sent ...`.
- Confirm the function has all four secrets: `firebase functions:secrets:access APNS_KEY_ID`.
- Confirm the recipient has a token under `users/{uid}/pushTokens`.
- Confirm the recipient's `public/friendSubscriptions/{uid}` contains the organizer's UID.
- Confirm the event is in the future and has coordinates, or that the recipient's notification area is close enough.
- For a Debug build the token is a **sandbox** token. The function sends to `api.sandbox.push.apple.com` when the stored environment is `sandbox`. TestFlight and App Store builds use production.

## Simulated notification on a simulator

With the app installed and running at least once:

```sh
xcrun simctl push booted com.beanllc.Bulletin - <<'JSON'
{
  "aps": {
    "alert": {
      "title": "Your friend created an event",
      "subtitle": "Jerome · Rooftop music",
      "body": "A small acoustic set at sunset."
    },
    "sound": "default"
  },
  "eventID": "PUT-A-REAL-EVENT-UUID-HERE"
}
JSON
```

Tapping the simulated alert exercises the deep-link path. The app must be signed in for the event to open; otherwise it waits behind the auth gate and opens the event after sign-in.

## Privacy and scale notes

- The server stores friend **account IDs**, the recipient's search center/radius, and APNs device tokens. It never receives contact names, contact photos, raw phone numbers, or email addresses from the address book.
- The Privacy Policy and Terms of Service have been updated to describe these practices.
- The function scans `public/friendSubscriptions` on each event creation. That is simple and fine for early growth. If Bulletin reaches many thousands of users, replace the scan with a reverse index written by a trusted backend.
- Event images are still stored as base64 in the Realtime Database. Moving images to Firebase Storage remains a separate scalability task.
