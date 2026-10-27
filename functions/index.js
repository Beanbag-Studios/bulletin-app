"use strict";

const { onValueCreated } = require("firebase-functions/v2/database");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");
const {
  buildPayload,
  isNearby,
  sendApnsBatch,
} = require("./apns");

admin.initializeApp({
  databaseURL:
    process.env.FIREBASE_DATABASE_URL ||
    "https://bulletinback-63a08-default-rtdb.firebaseio.com",
});

const APNS_KEY = defineSecret("APNS_KEY");
const APNS_KEY_ID = defineSecret("APNS_KEY_ID");
const APNS_TEAM_ID = defineSecret("APNS_TEAM_ID");
const APNS_BUNDLE_ID = defineSecret("APNS_BUNDLE_ID");

const db = admin.database();

async function mapLimit(items, limit, worker) {
  const results = new Array(items.length);
  let nextIndex = 0;

  async function run() {
    while (nextIndex < items.length) {
      const index = nextIndex;
      nextIndex += 1;
      results[index] = await worker(items[index], index);
    }
  }

  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, () => run())
  );
  return results;
}

/** Events store seconds in new records and milliseconds in older ones. */
function eventTimeMs(value) {
  const number = Number(value);
  if (!Number.isFinite(number) || number <= 0) return null;
  return number > 100_000_000_000 ? number : number * 1000;
}

/**
 * When an event is created, find everyone who has the organizer in their
 * friend subscriptions, apply their own notification area, and send one APNs
 * alert per device.
 *
 * The subscriptions are written by each recipient's device, so a user cannot
 * target arbitrary accounts; only people who independently matched the
 * organizer can receive the alert.
 */
exports.notifyFriendsOfNewEvent = onValueCreated(
  {
    ref: "/events/{eventId}",
    region: "us-central1",
    memory: "512MiB",
    timeoutSeconds: 120,
    retry: false,
    secrets: [APNS_KEY, APNS_KEY_ID, APNS_TEAM_ID, APNS_BUNDLE_ID],
  },
  async (event) => {
    const eventId = event.params.eventId;
    const record = event.data.val();
    const creatorUid = record && record.creatorUid;

    if (!eventId || !record || !creatorUid) return;

    const start = eventTimeMs(record.eventDate);
    if (start !== null && start < Date.now()) {
      console.log(`Skipping ${eventId}: event is already in the past.`);
      return;
    }

    const subscriptionsSnapshot = await db
      .ref("public/friendSubscriptions")
      .get();
    const subscriptions = subscriptionsSnapshot.val() || {};

    const recipients = Object.entries(subscriptions)
      .filter(([uid, friends]) => {
        return (
          uid !== creatorUid &&
          friends &&
          typeof friends === "object" &&
          friends[creatorUid] === true
        );
      })
      .map(([uid]) => uid);

    if (!recipients.length) {
      console.log(`No friend recipients for ${eventId}.`);
      return;
    }

    const payload = buildPayload({
      eventId,
      organizerName: record.organizerName,
      title: record.title,
      description: record.description,
    });

    const messages = [];

    await mapLimit(recipients, 20, async (uid) => {
      const [areaSnapshot, tokensSnapshot] = await Promise.all([
        db.ref(`users/${uid}/notificationArea`).get(),
        db.ref(`users/${uid}/pushTokens`).get(),
      ]);

      if (!isNearby(record, areaSnapshot.val())) {
        return;
      }

      const tokens = tokensSnapshot.val() || {};
      for (const [token, info] of Object.entries(tokens)) {
        if (!token || !info || typeof info !== "object") continue;
        messages.push({
          uid,
          token,
          environment: info.environment === "sandbox" ? "sandbox" : "production",
          payload,
        });
      }
    });

    if (!messages.length) {
      console.log(`No registered devices for ${eventId}.`);
      return;
    }

    const key = APNS_KEY.value().replace(/\\n/g, "\n");
    const results = await sendApnsBatch(messages, {
      key,
      keyId: APNS_KEY_ID.value(),
      teamId: APNS_TEAM_ID.value(),
      bundleId: APNS_BUNDLE_ID.value() || "com.beanllc.Bulletin",
    });

    const invalid = results.filter((result) => result.invalidToken);
    await Promise.all(
      invalid.map((result) =>
        db
          .ref(`users/${result.uid}/pushTokens/${result.token}`)
          .remove()
          .catch((error) => {
            console.error(
              `Could not remove invalid token for ${result.uid}: ${error.message}`
            );
          })
      )
    );

    const sent = results.filter((result) => result.ok).length;
    const failed = results.length - sent;
    console.log(
      `Event ${eventId}: sent ${sent}/${results.length} alerts; ${failed} failed; ${invalid.length} invalid tokens removed.`
    );

    for (const result of results.filter((item) => !item.ok && !item.invalidToken)) {
      console.error(
        `APNs ${result.status} for ${result.uid}: ${result.reason || "unknown"}`
      );
    }
  }
);
