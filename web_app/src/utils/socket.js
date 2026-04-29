/**
 * Phoenix WebSocket singleton.
 * Manages a single socket connection and provides a helper to join
 * per-route stats channels.
 */
import { Socket } from 'phoenix';
import { getToken } from './auth';

let socket = null;

/**
 * Returns the shared Socket instance, creating it on first call.
 * The token is read from localStorage at connection time.
 */
function getSocket() {
  if (socket) return socket;

  // Derive ws:// or wss:// from the current page protocol
  const protocol = window.location.protocol === 'https:' ? 'wss' : 'ws';
  const host = window.location.hostname;
  const url = `${protocol}://${host}:4000/socket`;

  socket = new Socket(url, { params: { token: getToken() } });
  socket.connect();
  return socket;
}

/**
 * Join the stats channel for a given route.
 *
 * @param {string} routeId - The route UUID
 * @param {function} onStats - Called with { stats, health, updated_at } on every update
 * @returns {object} The Phoenix Channel — call channel.leave() on cleanup
 */
export function joinStatsChannel(routeId, onStats) {
  const channel = getSocket().channel(`route:stats:${routeId}`, {});

  channel.on('stats_update', onStats);

  channel.join().receive('error', (err) => {
    console.error(`[StatsChannel] Failed to join route:stats:${routeId}`, err);
  });

  return channel;
}

/**
 * Disconnect the shared socket (e.g. on logout).
 */
export function disconnectSocket() {
  if (socket) {
    socket.disconnect();
    socket = null;
  }
}
