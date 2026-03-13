/**
 * socket.js — shared Phoenix WebSocket client with HTTP polling fallback
 */
import { Socket } from 'phoenix';
import { API_BASE_URL } from './constants';

// Derive WebSocket URL from API_BASE_URL (http → ws, https → wss)
const WS_URL = API_BASE_URL.replace(/^http/, 'ws') + '/socket';

let _socket = null;

function getSocket() {
  if (_socket && _socket.isConnected()) return _socket;

  if (_socket) {
    try { _socket.disconnect(); } catch (_) {}
  }

  _socket = new Socket(WS_URL, {
    params: {},
    reconnectAfterMs: (tries) => [1000, 2000, 5000, 10000][tries - 1] || 10000,
  });
  _socket.connect();
  return _socket;
}

/**
 * Subscribe to live stats for a route.
 * Returns an unsubscribe function.
 */
export function subscribeToStats(routeId, token, onStats, onSinkStats, onError) {
  let channel;
  try {
    const socket = getSocket();
    channel = socket.channel(`stats:${routeId}`, {});
  } catch (e) {
    console.warn('[socket.js] Failed to create channel', e);
    if (onError) onError(e);
    return () => {};
  }

  channel.on('stats_update', (payload) => {
    if (onStats) onStats(payload.stats);
  });

  channel.on('sink_stats_update', (payload) => {
    if (onSinkStats) onSinkStats(payload.sink_index, payload.stats);
  });

  channel
    .join()
    .receive('ok', (reply) => {
      if (reply.stats && onStats) onStats(reply.stats);
    })
    .receive('error', (err) => {
      console.warn(`[StatsChannel] Failed to join stats:${routeId}`, err);
      if (onError) onError(err);
    })
    .receive('timeout', () => {
      console.warn(`[StatsChannel] Timeout joining stats:${routeId}`);
      if (onError) onError(new Error('timeout'));
    });

  return () => {
    try { channel.leave(); } catch (_) {}
  };
}
