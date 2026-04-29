import { useEffect, useState, useRef } from 'react';
import { joinStatsChannel } from '../utils/socket';
import { routesApi } from '../utils/api';

/**
 * Hybrid stats hook: HTTP fetch on mount for immediate data,
 * WebSocket for live updates. Falls back gracefully if WS fails.
 *
 * @param {string|null} routeId - The route UUID (pass null to skip)
 * @param {boolean} isRunning   - Only subscribe when the route is running
 * @returns {{ stats: object|null, health: string|null }}
 */
export function useRouteStats(routeId, isRunning) {
  const [stats, setStats] = useState(null);
  const [health, setHealth] = useState(null);
  const pollingRef = useRef(null);

  useEffect(() => {
    if (!routeId || !isRunning) {
      setStats(null);
      setHealth(null);
      return;
    }

    // 1. HTTP fetch immediately so stats appear right away
    const fetchOnce = async () => {
      try {
        const result = await routesApi.getStats(routeId);
        if (result?.data) setStats(result.data);
      } catch { /* ignore */ }
    };
    fetchOnce();

    // 2. Poll every 3s as a reliable fallback
    pollingRef.current = setInterval(fetchOnce, 3000);

    // 3. WebSocket channel for sub-second push updates
    //    If WS works it will override the polled value in real-time
    const channel = joinStatsChannel(routeId, ({ stats: s, health: h }) => {
      setStats(s);
      setHealth(h);
    });

    return () => {
      clearInterval(pollingRef.current);
      channel.leave();
    };
  }, [routeId, isRunning]);

  return { stats, health };
}
