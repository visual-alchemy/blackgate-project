import { useEffect, useState, useRef } from 'react';
import { joinStatsChannel } from '../utils/socket';
import { routesApi } from '../utils/api';

/**
 * Hybrid stats hook: HTTP fetch on mount for immediate data,
 * WebSocket for live updates. Handles both primary and secondary source stats.
 *
 * @param {string|null} routeId - The route UUID (pass null to skip)
 * @param {boolean} isRunning   - Only subscribe when the route is running
 * @returns {{ stats: object|null, secondaryStats: object|null, health: string|null }}
 */
export function useRouteStats(routeId, isRunning) {
  const [stats, setStats] = useState(null);
  const [secondaryStats, setSecondaryStats] = useState(null);
  const [health, setHealth] = useState(null);
  const pollingRef = useRef(null);

  useEffect(() => {
    if (!routeId || !isRunning) {
      setStats(null);
      setSecondaryStats(null);
      setHealth(null);
      return;
    }

    // 1. HTTP fetch immediately so stats appear right away
    const fetchOnce = async () => {
      try {
        const result = await routesApi.getStats(routeId);
        if (result?.data !== undefined) setStats(result.data);
        if (result?.secondary_source_stats !== undefined) setSecondaryStats(result.secondary_source_stats);
      } catch { /* ignore */ }
    };
    fetchOnce();

    // 2. Poll every 3s as a reliable fallback
    pollingRef.current = setInterval(fetchOnce, 3000);

    // 3. WebSocket channel for sub-second push updates
    //    Safely update stats without overwriting primary stats with null on secondary broadcasts
    const channel = joinStatsChannel(routeId, (msg) => {
      if (msg.stats !== undefined) {
        setStats(msg.stats);
      }
      if (msg.secondary_source_stats !== undefined) {
        setSecondaryStats(msg.secondary_source_stats);
      }
      if (msg.health !== undefined) {
        setHealth(msg.health);
      }
    });

    return () => {
      clearInterval(pollingRef.current);
      channel.leave();
    };
  }, [routeId, isRunning]);

  return { stats, secondaryStats, health };
}
