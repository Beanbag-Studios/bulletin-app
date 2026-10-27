"use strict";

const http2 = require("node:http2");
const crypto = require("node:crypto");

const APNS_PRODUCTION = "https://api.push.apple.com";
const APNS_SANDBOX = "https://api.sandbox.push.apple.com";

function base64url(value) {
  return Buffer.from(value)
    .toString("base64")
    .replace(/=/g, "")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");
}

/**
 * Creates the short-lived ES256 JWT that APNs uses for token-based provider
 * authentication. Apple recommends reusing one token for up to an hour.
 */
function createProviderToken({ key, keyId, teamId, now = Math.floor(Date.now() / 1000) }) {
  if (!key || !keyId || !teamId) {
    throw new Error("APNs key, key ID, and team ID are required.");
  }

  const header = base64url(JSON.stringify({ alg: "ES256", kid: keyId }));
  const claims = base64url(JSON.stringify({ iss: teamId, iat: now }));
  const signingInput = `${header}.${claims}`;
  const signature = crypto.sign("sha256", Buffer.from(signingInput), {
    key,
    dsaEncoding: "ieee-p1363",
  });

  return `${signingInput}.${base64url(signature)}`;
}

function hasCoordinate(value) {
  return (
    value &&
    Number.isFinite(Number(value.latitude)) &&
    Number.isFinite(Number(value.longitude))
  );
}

/** Great-circle distance in miles. */
function haversineMiles(a, b) {
  const earthRadiusMiles = 3958.7613;
  const toRadians = (degrees) => (Number(degrees) * Math.PI) / 180;
  const lat1 = toRadians(a.latitude);
  const lat2 = toRadians(b.latitude);
  const deltaLat = toRadians(Number(b.latitude) - Number(a.latitude));
  const deltaLon = toRadians(Number(b.longitude) - Number(a.longitude));

  const h =
    Math.sin(deltaLat / 2) ** 2 +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(deltaLon / 2) ** 2;

  return 2 * earthRadiusMiles * Math.asin(Math.min(1, Math.sqrt(h)));
}

/**
 * A missing area means "don't filter" so people who have not opened the app
 * since installing the update still receive alerts. A missing event coordinate
 * is treated the same way.
 */
function isNearby(event, area) {
  if (!hasCoordinate(event) || !hasCoordinate(area)) return true;

  const radius = Number(area.radiusMiles);
  if (!Number.isFinite(radius) || radius <= 0) return true;

  return haversineMiles(event, area) <= radius;
}

function shorten(value, maxLength) {
  const normalized = String(value || "")
    .replace(/\s+/g, " ")
    .trim();
  if (normalized.length <= maxLength) return normalized;

  const clipped = normalized.slice(0, maxLength);
  const lastSpace = clipped.lastIndexOf(" ");
  const base = lastSpace > Math.floor(maxLength / 3)
    ? clipped.slice(0, lastSpace)
    : clipped;
  return `${base.trim()}…`;
}

function buildPayload({ eventId, organizerName, title, description }) {
  const eventTitle = shorten(title, 80) || "New event";
  const organizer = shorten(organizerName, 40) || "A friend";
  const body = shorten(description, 140) || "Tap to see the details.";

  return {
    aps: {
      alert: {
        title: "Your friend created an event",
        subtitle: `${organizer} · ${eventTitle}`,
        body,
      },
      sound: "default",
      badge: 1,
      "thread-id": "friend-events",
      "interruption-level": "active",
    },
    eventID: eventId,
  };
}

function parseReason(body) {
  try {
    const parsed = JSON.parse(body || "{}");
    return typeof parsed.reason === "string" ? parsed.reason : "";
  } catch {
    return "";
  }
}

function isInvalidToken(status, reason) {
  if (status === 410) return true;
  return (
    status === 400 &&
    ["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"].includes(reason)
  );
}

function sendOne(client, message, jwt, bundleId) {
  return new Promise((resolve) => {
    let status = 0;
    let body = "";
    let settled = false;
    let timer = null;

    const finish = (result) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      resolve(result);
    };

    const request = client.request({
      ":method": "POST",
      ":path": `/3/device/${message.token}`,
      authorization: `bearer ${jwt}`,
      "apns-topic": bundleId,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-expiration": "0",
      "content-type": "application/json",
      "apns-id": crypto.randomUUID(),
    });

    timer = setTimeout(() => {
      request.close();
      finish({
        ok: false,
        status: 0,
        reason: "timeout",
        invalidToken: false,
        retryable: true,
      });
    }, 15000);

    request.setEncoding("utf8");
    request.on("response", (headers) => {
      status = Number(headers[":status"] || 0);
    });
    request.on("data", (chunk) => {
      body += chunk;
    });
    request.on("end", () => {
      const reason = parseReason(body);
      finish({
        ok: status === 200,
        status,
        reason,
        body: body.slice(0, 300),
        invalidToken: isInvalidToken(status, reason),
        retryable: status === 429 || status >= 500,
      });
    });
    request.on("error", (error) => {
      finish({
        ok: false,
        status: 0,
        reason: error.message,
        invalidToken: false,
        retryable: true,
      });
    });

    request.end(JSON.stringify(message.payload));
  });
}

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

/**
 * Sends one payload per message. Messages may target either APNs environment;
 * connections are reused per environment and closed when the batch is done.
 */
async function sendApnsBatch(messages, { key, keyId, teamId, bundleId }) {
  if (!messages.length) return [];

  const jwt = createProviderToken({ key, keyId, teamId });
  const environments = new Set(messages.map((message) => message.environment));
  const clients = new Map();

  for (const environment of environments) {
    const origin = environment === "sandbox" ? APNS_SANDBOX : APNS_PRODUCTION;
    const client = http2.connect(origin);
    client.on("error", (error) => {
      console.error(`APNs ${environment} connection error: ${error.message}`);
    });
    clients.set(environment, client);
  }

  const results = await mapLimit(messages, 10, async (message) => {
    const client = clients.get(message.environment);
    const result = await sendOne(client, message, jwt, bundleId);
    return { ...message, ...result };
  });

  for (const client of clients.values()) {
    client.close();
  }

  return results;
}

module.exports = {
  createProviderToken,
  haversineMiles,
  isNearby,
  buildPayload,
  sendApnsBatch,
  shorten,
};
