import { Typography, Card, Row, Col, Statistic, Tag, Spin, Alert } from 'antd';
import { ApiOutlined, PlayCircleOutlined, StopOutlined, HomeOutlined, VideoCameraOutlined, DisconnectOutlined, WarningOutlined } from '@ant-design/icons';
import { useEffect, useState, useRef, useCallback } from 'react';
import React from 'react';
import { nodesApi, routesApi } from '../utils/api';
import { useNavigate } from 'react-router-dom';
import { useRouteStats } from '../hooks/useRouteStats';
import HealthBadge from '../components/HealthBadge';

const { Title } = Typography;

// --- Route Preview Card ---
const RoutePreviewCard = ({ route, onHealthChange }) => {
  const navigate = useNavigate();
  const [blobUrl, setBlobUrl] = useState(null);
  const intervalRef = useRef(null);
  const blobUrlRef = useRef(null);
  const isRunning = route.status === 'started';

  // Live health via WebSocket
  const { health } = useRouteStats(route.id, isRunning);

  // Notify Dashboard of health changes so it can aggregate alerts
  useEffect(() => {
    onHealthChange(route.id, health);
  }, [route.id, health, onHealthChange]);

  const fetchThumbnail = useCallback(async () => {
    try {
      const blob = await routesApi.previewBlob(route.id);
      if (blob) {
        const url = URL.createObjectURL(blob);
        if (blobUrlRef.current) URL.revokeObjectURL(blobUrlRef.current);
        blobUrlRef.current = url;
        setBlobUrl(url);
      }
    } catch {
      // Silently ignore fetch errors
    }
  }, [route.id]);

  useEffect(() => {
    if (!isRunning) {
      setBlobUrl(null);
      return;
    }
    fetchThumbnail();
    intervalRef.current = setInterval(fetchThumbnail, 5000);
    return () => {
      clearInterval(intervalRef.current);
      if (blobUrlRef.current) URL.revokeObjectURL(blobUrlRef.current);
    };
  }, [isRunning, fetchThumbnail]);

  // Card border color based on health
  const borderColor = {
    critical: '#ff4d4f',
    warning:  '#faad14',
    healthy:  '#303030',
    disconnected: '#303030',
  }[health] ?? '#303030';

  return (
    <div
      onClick={() => navigate(`/routes/${route.id}`)}
      style={{
        cursor: 'pointer',
        borderRadius: '8px',
        overflow: 'hidden',
        background: '#141414',
        border: `1px solid ${borderColor}`,
        transition: 'border-color 0.3s, box-shadow 0.3s',
        boxShadow: health === 'critical' ? `0 0 8px ${borderColor}55` : 'none',
      }}
      onMouseEnter={e => {
        e.currentTarget.style.boxShadow = '0 4px 20px rgba(0,0,0,0.4)';
      }}
      onMouseLeave={e => {
        e.currentTarget.style.boxShadow = health === 'critical' ? `0 0 8px ${borderColor}55` : 'none';
      }}
    >
      {/* Thumbnail — 16:9 ratio */}
      <div style={{ position: 'relative', width: '100%', paddingTop: '56.25%', background: '#0a0a0a' }}>
        {blobUrl ? (
          <img
            src={blobUrl}
            alt={route.name}
            style={{ position: 'absolute', top: 0, left: 0, width: '100%', height: '100%', objectFit: 'cover' }}
          />
        ) : (
          <div style={{
            position: 'absolute', top: 0, left: 0, width: '100%', height: '100%',
            display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center',
            gap: '8px', color: '#434343',
          }}>
            {isRunning ? (
              <>
                <Spin size="small" />
                <span style={{ fontSize: '11px' }}>Loading preview…</span>
              </>
            ) : (
              <>
                <DisconnectOutlined style={{ fontSize: '24px' }} />
                <span style={{ fontSize: '11px' }}>No Signal</span>
              </>
            )}
          </div>
        )}

        {/* Health badge top-left, LIVE/Stopped top-right */}
        <div style={{ position: 'absolute', top: '8px', left: '8px' }}>
          {isRunning && health ? (
            <HealthBadge health={health} compact />
          ) : (
            <Tag
              color={isRunning ? 'green' : 'default'}
              style={{ margin: 0, fontSize: '10px', lineHeight: '16px', padding: '0 6px' }}
            >
              {isRunning ? '● LIVE' : '○ Stopped'}
            </Tag>
          )}
        </div>
      </div>

      {/* Route info */}
      <div style={{ padding: '10px 12px' }}>
        <div style={{ fontWeight: 600, fontSize: '13px', color: '#e8e8e8', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
          {route.name}
        </div>
        <div style={{ fontSize: '11px', color: '#595959', marginTop: '2px' }}>
          {route.schema || 'SRT'} · {route.schema_options?.localport || route.schema_options?.localaddress || '—'}
        </div>
      </div>
    </div>
  );
};

// --- Dashboard ---
const Dashboard = () => {
  const [nodeStats, setNodeStats] = useState({ cpu: null, ram: null, swap: null, la: 'N/A / N/A / N/A' });
  const [routeStats, setRouteStats] = useState({ total: 0, active: 0, stopped: 0, routes: [] });
  const [loading, setLoading] = useState(true);
  const [healthMap, setHealthMap] = useState({});
  const navigate = useNavigate();

  useEffect(() => {
    if (window.setBreadcrumbItems) {
      window.breadcrumbSet = true;
      window.setBreadcrumbItems([{ href: '/', title: <HomeOutlined /> }]);
    }
  }, []);

  useEffect(() => {
    const fetchStats = async () => {
      try {
        setLoading(true);

        const nodeData = await nodesApi.getAll();
        const selfNode = nodeData.find(n => n.status === 'self');
        if (selfNode) setNodeStats(selfNode);

        const routeData = await routesApi.getAll();
        const routes = routeData.data || [];
        const activeRoutes = routes.filter(r => r.status === 'started');
        const stoppedRoutes = routes.filter(r => r.status !== 'started');

        // Running routes first
        const sorted = [
          ...activeRoutes.sort((a, b) => new Date(b.updated_at) - new Date(a.updated_at)),
          ...stoppedRoutes.sort((a, b) => new Date(b.updated_at) - new Date(a.updated_at)),
        ];

        setRouteStats({ total: routes.length, active: activeRoutes.length, stopped: stoppedRoutes.length, routes: sorted });
      } catch (error) {
        console.error('Error fetching stats:', error);
      } finally {
        setLoading(false);
      }
    };

    fetchStats();
    const id = setInterval(fetchStats, 30000);
    return () => clearInterval(id);
  }, []);

  // Callback for cards to report health changes
  const handleHealthChange = useCallback((routeId, health) => {
    setHealthMap(prev => {
      if (prev[routeId] === health) return prev;
      return { ...prev, [routeId]: health };
    });
  }, []);

  // Aggregate critical/warning routes for the alert banner
  const criticalRoutes = routeStats.routes.filter(r => healthMap[r.id] === 'critical');
  const warningRoutes = routeStats.routes.filter(r => healthMap[r.id] === 'warning');

  const getProgressColor = (value) => {
    if (value === null || value === undefined) return undefined;
    if (value > 80) return '#ff4d4f';
    if (value > 50) return '#faad14';
    return '#52c41a';
  };

  return (
    <div>
      <Title level={3} style={{ margin: 0, fontSize: '2rem', fontWeight: 600 }}>Dashboard</Title>

      {/* Health alert banners */}
      {criticalRoutes.length > 0 && (
        <Alert
          type="error"
          showIcon
          icon={<WarningOutlined />}
          style={{ marginTop: '16px' }}
          message={
            criticalRoutes.length === 1
              ? `Critical: "${criticalRoutes[0].name}" has severe packet loss or very high RTT.`
              : `Critical: ${criticalRoutes.length} routes have severely degraded metrics.`
          }
        />
      )}
      {warningRoutes.length > 0 && criticalRoutes.length === 0 && (
        <Alert
          type="warning"
          showIcon
          style={{ marginTop: '16px' }}
          message={
            warningRoutes.length === 1
              ? `Warning: "${warningRoutes[0].name}" has slightly degraded metrics.`
              : `Warning: ${warningRoutes.length} routes have slightly degraded metrics.`
          }
        />
      )}

      {/* Route Statistics */}
      <Row gutter={[16, 16]} style={{ marginTop: '16px' }}>
        <Col xs={24} sm={8}>
          <Card>
            <Statistic title="Total Routes" value={routeStats.total} prefix={<ApiOutlined />} loading={loading} />
          </Card>
        </Col>
        <Col xs={24} sm={8}>
          <Card>
            <Statistic
              title="Active Routes"
              value={routeStats.active}
              prefix={<PlayCircleOutlined style={{ color: '#52c41a' }} />}
              valueStyle={{ color: '#52c41a' }}
              loading={loading}
            />
          </Card>
        </Col>
        <Col xs={24} sm={8}>
          <Card>
            <Statistic
              title="Stopped Routes"
              value={routeStats.stopped}
              prefix={<StopOutlined style={{ color: '#8c8c8c' }} />}
              valueStyle={{ color: '#8c8c8c' }}
              loading={loading}
            />
          </Card>
        </Col>
      </Row>

      {/* System Stats */}
      <Row gutter={[16, 16]} style={{ marginTop: '24px' }}>
        {[
          { label: 'CPU Usage', val: nodeStats.cpu },
          { label: 'RAM Usage', val: nodeStats.ram },
          { label: 'SWAP Usage', val: nodeStats.swap },
        ].map(({ label, val }) => (
          <Col xs={24} sm={6} key={label}>
            <Card>
              <div style={{ padding: '16px 0' }}>
                <div style={{ fontSize: '14px', color: 'rgba(255,255,255,0.45)' }}>{label}</div>
                <div style={{ fontSize: '24px', marginTop: '8px', color: getProgressColor(val) }}>
                  {val !== null ? `${Math.round(val)}%` : 'N/A'}
                </div>
              </div>
            </Card>
          </Col>
        ))}
        <Col xs={24} sm={6}>
          <Card>
            <div style={{ padding: '16px 0' }}>
              <div style={{ fontSize: '14px', color: 'rgba(255,255,255,0.45)' }}>System Load</div>
              <div style={{ fontSize: '24px', marginTop: '8px' }}>{nodeStats.la}</div>
            </div>
          </Card>
        </Col>
      </Row>

      {/* Live Preview Grid */}
      <Row gutter={[16, 16]} style={{ marginTop: '24px' }}>
        <Col xs={24}>
          <Card
            title={<span><VideoCameraOutlined style={{ marginRight: '8px' }} />Live Preview</span>}
            extra={<a onClick={() => navigate('/routes')}>View All</a>}
            loading={loading}
          >
            {routeStats.routes.length === 0 ? (
              <div style={{ textAlign: 'center', color: '#595959', padding: '32px 0' }}>
                No routes configured yet
              </div>
            ) : (
              <div style={{
                display: 'grid',
                gridTemplateColumns: 'repeat(auto-fill, minmax(220px, 1fr))',
                gap: '16px',
              }}>
                {routeStats.routes.map(route => (
                  <RoutePreviewCard
                    key={route.id}
                    route={route}
                    onHealthChange={handleHealthChange}
                  />
                ))}
              </div>
            )}
          </Card>
        </Col>
      </Row>
    </div>
  );
};

export default Dashboard;