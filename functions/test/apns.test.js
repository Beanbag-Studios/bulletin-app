"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const {
  buildPayload,
  createProviderToken,
  haversineMiles,
  isNearby,
  shorten,
} = require("../apns");

test("buildPayload includes the event deep link and a short description", () => {
  const payload = buildPayload({
    eventId: "event-123",
    organizerName: "Jerome",
    title: "Rooftop music",
    description:
      "A small acoustic set at sunset. Bring a chair and something to drink.",
  });

  assert.equal(payload.eventID, "event-123");
  assert.equal(payload.aps.alert.title, "Your friend created an event");
  assert.equal(payload.aps.alert.subtitle, "Jerome · Rooftop music");
  assert.match(payload.aps.alert.body, /acoustic set/);
  assert.equal(payload.aps.sound, "default");
});

test("buildPayload has sensible fallbacks", () => {
  const payload = buildPayload({
    eventId: "event-456",
    organizerName: "",
    title: "",
    description: "",
  });

  assert.equal(payload.aps.alert.subtitle, "A friend · New event");
  assert.equal(payload.aps.alert.body, "Tap to see the details.");
});

test("shorten collapses whitespace and truncates long text", () => {
  assert.equal(shorten("  hello\n\nworld  ", 40), "hello world");
  const shortened = shorten("a".repeat(20) + " " + "b".repeat(200), 40);
  assert.ok(shortened.length <= 41, shortened);
  assert.ok(shortened.endsWith("…"));
});

test("haversineMiles is approximately correct", () => {
  const sf = { latitude: 37.7749, longitude: -122.4194 };
  const oakland = { latitude: 37.8044, longitude: -122.2712 };
  const miles = haversineMiles(sf, oakland);
  assert.ok(miles > 8 && miles < 10, `expected ~8.8 miles, got ${miles}`);
});

test("isNearby applies the recipient's radius", () => {
  const event = { latitude: 37.7749, longitude: -122.4194 };
  const near = {
    latitude: 37.78,
    longitude: -122.42,
    radiusMiles: 20,
  };
  const far = {
    latitude: 34.0522,
    longitude: -118.2437,
    radiusMiles: 20,
  };

  assert.equal(isNearby(event, near), true);
  assert.equal(isNearby(event, far), false);
  assert.equal(isNearby(event, null), true);
  assert.equal(isNearby({ title: "No coordinates" }, far), true);
});

test("createProviderToken produces a verifiable ES256 JWT", () => {
  const { privateKey, publicKey } = crypto.generateKeyPairSync("ec", {
    namedCurve: "prime256v1",
  });
  const token = createProviderToken({
    key: privateKey.export({ type: "pkcs8", format: "pem" }),
    keyId: "KEYID12345",
    teamId: "TEAM123456",
    now: 1_700_000_000,
  });

  const [header, claims, signature] = token.split(".");
  assert.ok(header && claims && signature);

  const verified = crypto.verify(
    "sha256",
    Buffer.from(`${header}.${claims}`),
    { key: publicKey, dsaEncoding: "ieee-p1363" },
    Buffer.from(signature, "base64url")
  );
  assert.equal(verified, true);

  const headerJSON = JSON.parse(Buffer.from(header, "base64url").toString());
  const claimsJSON = JSON.parse(Buffer.from(claims, "base64url").toString());
  assert.equal(headerJSON.alg, "ES256");
  assert.equal(headerJSON.kid, "KEYID12345");
  assert.equal(claimsJSON.iss, "TEAM123456");
  assert.equal(claimsJSON.iat, 1_700_000_000);
});
