import { useEffect, useState, useCallback } from 'react';
import { Badge, Tooltip } from 'antd';
import { routesApi } from '../utils/api';

/**
 * HealthBadge — shows a color-coded dot indicating stream health.
 * Only polls when the route is running.
 *
 * Status colors:
 *   🟢 good     — packet loss < 0.1%, RTT < 50ms
 *   🟡 warning  — packet loss 0.1–1% OR RTT 50–200ms
 *   🔴 critical — packet loss > 1% OR RTT > 200ms OR no data
 */

const STATUS_MAP = {
  good:    { status: 'success', text: 'Healthy' },
  warning: { status: 'warning', text: 'Warning' },
  critical:{ status: 'error',   text: 'Critical' },
  no_data: { status: 'default', text: 'No data' },
};

const HealthBadge = ({ routeId, isRunning }) => {
  const [health, setHealth] = useState(null);

  const fetchHealth = useCallback(async () => {
    if (!routeId || !isRunning) {
      setHealth(null);
      return;
    }
    try {
      const result = await routesApi.getHealth(routeId);
      if (result.data) setHealth(result.data);
    } catch {
      // silently ignore — badge will not render
    }
  }, [routeId, isRunning]);

  useEffect(() => {
    if (!isRunning) {
      setHealth(null);
      return;
    }
    fetchHealth();
    const interval = setInterval(fetchHealth, 5000);
    return () => clearInterval(interval);
  }, [fetchHealth, isRunning]);

  if (!isRunning || !health) return null;

  const { status, text } = STATUS_MAP[health.status] || STATUS_MAP.no_data;
  const reasons = health.reasons || [];
  const tooltipTitle = reasons.length > 0 ? reasons.join(' · ') : text;

  return (
    <Tooltip title={tooltipTitle} placement="top">
      <Badge status={status} text={<span style={{ fontSize: 12 }}>{text}</span>} />
    </Tooltip>
  );
};

export default HealthBadge;
