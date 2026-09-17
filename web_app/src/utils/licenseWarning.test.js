import test from 'node:test';
import assert from 'node:assert/strict';
import { licenseExpiryWarning, formatExpiryDeadline } from './licenseWarning.js';

const entitlement = (seconds, fields = {}) => ({
  status: 'licensed', expired: false,
  expires_at: '2026-09-24T00:00:00Z', expires_in_seconds: seconds, ...fields,
});

test('warnings switch at exact 7-day, 3-day and 24-hour boundaries', () => {
  assert.equal(licenseExpiryWarning(entitlement(7 * 86400 + 1)), null);
  assert.match(licenseExpiryWarning(entitlement(7 * 86400)).message, /7 days/);
  assert.match(licenseExpiryWarning(entitlement(3 * 86400 + 1)).message, /7 days/);
  assert.match(licenseExpiryWarning(entitlement(3 * 86400)).message, /3 days/);
  assert.match(licenseExpiryWarning(entitlement(86401)).message, /3 days/);
  assert.deepEqual(licenseExpiryWarning(entitlement(86400)), {
    type: 'error', message: 'License expires within 24 hours',
  });
  assert.equal(licenseExpiryWarning(entitlement(1)).type, 'error');
});

test('expired, missing, lifetime and invalid entitlements do not show upcoming-expiry warnings', () => {
  for (const license of [null, {}, entitlement(0), entitlement(-1), entitlement(null),
    entitlement(NaN), entitlement(60, { expired: true }),
    entitlement(60, { status: 'revoked' }), entitlement(60, { expires_at: null })]) {
    assert.equal(licenseExpiryWarning(license), null);
  }
});

test('trial warning uses trial wording; renewal outside warning window clears banner', () => {
  assert.match(licenseExpiryWarning(entitlement(60, { status: 'trial' })).message, /^Trial/);
  assert.equal(licenseExpiryWarning(entitlement(30 * 86400)), null);
});

test('deadline includes local timezone and UTC and handles malformed dates', () => {
  const label = formatExpiryDeadline('2026-09-24T00:00:00Z');
  assert.match(label, /your local time/);
  assert.match(label, /24 Sept 2026, 00:00:00 UTC/);
  assert.equal(formatExpiryDeadline('invalid'), 'Unavailable');
});
