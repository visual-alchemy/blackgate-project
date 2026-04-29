import { Tag, Tooltip } from 'antd';
import {
  CheckCircleOutlined,
  WarningOutlined,
  CloseCircleOutlined,
  DisconnectOutlined,
  QuestionCircleOutlined,
} from '@ant-design/icons';

const HEALTH_CONFIG = {
  healthy: {
    color: 'success',
    icon: <CheckCircleOutlined />,
    label: 'Healthy',
    tooltip: 'Stream is connected and all metrics are within normal range.',
  },
  warning: {
    color: 'warning',
    icon: <WarningOutlined />,
    label: 'Warning',
    tooltip: 'Stream is connected but metrics are slightly degraded (packet loss > 2% or RTT > 150ms).',
  },
  critical: {
    color: 'error',
    icon: <WarningOutlined />,
    label: 'Critical',
    tooltip: 'Stream is connected but metrics are severely degraded (packet loss > 10% or RTT > 500ms).',
  },
  disconnected: {
    color: 'default',
    icon: <DisconnectOutlined />,
    label: 'No Signal',
    tooltip: 'Route is running but no active stream data is being received.',
  },
};

/**
 * Health status badge for a route.
 *
 * @param {string} health  - "healthy" | "warning" | "critical" | "disconnected" | null
 * @param {boolean} compact - If true, show only the icon (no text label)
 */
const HealthBadge = ({ health, compact = false }) => {
  if (!health) return null;

  const cfg = HEALTH_CONFIG[health] ?? {
    color: 'default',
    icon: <QuestionCircleOutlined />,
    label: health,
    tooltip: '',
  };

  return (
    <Tooltip title={cfg.tooltip}>
      <Tag
        color={cfg.color}
        icon={cfg.icon}
        style={{ margin: 0, cursor: 'default', userSelect: 'none' }}
      >
        {!compact && cfg.label}
      </Tag>
    </Tooltip>
  );
};

export default HealthBadge;
