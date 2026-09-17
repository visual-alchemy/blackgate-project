// The gateway clock determines remaining time, independent of the browser clock.
export function licenseExpiryWarning(license) {
  const seconds = license?.expires_in_seconds;
  if (!license || license.expired || !['licensed', 'trial'].includes(license.status)
      || !license.expires_at || !Number.isFinite(seconds) || seconds <= 0
      || seconds > 7 * 86400) return null;

  const name = license.status === 'trial' ? 'Trial' : 'License';
  if (seconds <= 86400) return { type: 'error', message: `${name} expires within 24 hours` };
  if (seconds <= 3 * 86400) return { type: 'warning', message: `${name} expires within 3 days` };
  return { type: 'warning', message: `${name} expires within 7 days` };
}

export function formatExpiryDeadline(timestamp) {
  const date = new Date(timestamp);
  if (!timestamp || Number.isNaN(date.getTime())) return 'Unavailable';

  const options = {
    year: 'numeric', month: 'short', day: 'numeric',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
    hourCycle: 'h23', timeZoneName: 'short',
  };
  const local = new Intl.DateTimeFormat(undefined, options).format(date);
  const utc = new Intl.DateTimeFormat('en-GB', { ...options, timeZone: 'UTC' }).format(date);
  return `${local} (your local time) · ${utc}`;
}
