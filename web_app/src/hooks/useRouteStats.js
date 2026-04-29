import { useEffect, useState } from 'react';
import { joinStatsChannel } from '../utils/socket';

/**
 * Subscribe to live stats for a route via WebSocket.
 *
 * @param {string|null} routeId - The route UUID (pass null to skip)
 * @param {boolean} isRunning   - Only subscribe when the route is running
 * @returns {{ stats: object|null, health: string|null }}
 *   - `stats`  — the raw stats map from GStreamer (same shape as the HTTP API)
 *   - `health` — one of: "healthy" | "warning" | "critical" | "disconnected" | null
 */
export function useRouteStats(routeId, isRunning) {
  const [stats, setStats] = useState(null);
  const [health, setHealth] = useState(null);

  useEffect(() => {
    if (!routeId || !isRunning) {
      setStats(null);
      setHealth(null);
      return;
    }

    const channel = joinStatsChannel(routeId, ({ stats: s, health: h }) => {
      setStats(s);
      setHealth(h);
    });

    return () => {
      channel.leave();
    };
  }, [routeId, isRunning]);

  return { stats, health };
}
