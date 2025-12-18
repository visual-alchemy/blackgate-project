import { Typography, Card, Row, Col, Statistic, Table, Tag, Spin } from 'antd';
import { ApiOutlined, PlayCircleOutlined, StopOutlined, HomeOutlined, ClockCircleOutlined } from '@ant-design/icons';
import { useEffect, useState } from 'react';
import React from 'react';
import { nodesApi, routesApi } from '../utils/api';
import { useNavigate } from 'react-router-dom';

const { Title } = Typography;

const Dashboard = () => {
  const [nodeStats, setNodeStats] = useState({
    cpu: null,
    ram: null,
    swap: null,
    la: 'N/A / N/A / N/A'
  });
  const [routeStats, setRouteStats] = useState({
    total: 0,
    active: 0,
    stopped: 0,
    recentRoutes: []
  });
  const [loading, setLoading] = useState(true);
  const navigate = useNavigate();

  // Set breadcrumb items for the Dashboard page
  useEffect(() => {
    if (window.setBreadcrumbItems) {
      window.breadcrumbSet = true;
      window.setBreadcrumbItems([
        {
          href: '/',
          title: <HomeOutlined />,
        }
      ]);
    }
  }, []);

  // Fetch node stats and route stats
  useEffect(() => {
    const fetchStats = async () => {
      try {
        setLoading(true);

        // Fetch node stats
        const nodeData = await nodesApi.getAll();
        const selfNode = nodeData.find(node => node.status === 'self');
        if (selfNode) {
          setNodeStats(selfNode);
        }

        // Fetch route stats
        const routeData = await routesApi.getAll();
        const routes = routeData.data || [];
        const activeRoutes = routes.filter(r => r.status === 'started');
        const stoppedRoutes = routes.filter(r => r.status === 'stopped' || r.status !== 'started');

        // Get recent routes (sorted by updated_at, limit 5)
        const recentRoutes = [...routes]
          .sort((a, b) => new Date(b.updated_at) - new Date(a.updated_at))
          .slice(0, 5);

        setRouteStats({
          total: routes.length,
          active: activeRoutes.length,
          stopped: stoppedRoutes.length,
          recentRoutes
        });
      } catch (error) {
        console.error('Error fetching stats:', error);
      } finally {
        setLoading(false);
      }
    };

    fetchStats();
    // Set up auto-refresh every 30 seconds
    const intervalId = setInterval(fetchStats, 30000);

    // Clean up interval on component unmount
    return () => clearInterval(intervalId);
  }, []);

  const getProgressColor = (value) => {
    if (value === null || value === undefined) return '#ccc';
    if (value > 80) return '#ff4d4f';
    if (value > 50) return '#faad14';
    return '#52c41a';
  };

  // Columns for recent routes table
  const recentRoutesColumns = [
    {
      title: 'Name',
      dataIndex: 'name',
      key: 'name',
      render: (text, record) => (
        <a onClick={() => navigate(`/routes/${record.id}`)}>{text}</a>
      ),
    },
    {
      title: 'Status',
      dataIndex: 'status',
      key: 'status',
      render: (status) => (
        <Tag color={status === 'started' ? 'green' : 'default'}>
          {status || 'stopped'}
        </Tag>
      ),
    },
    {
      title: 'Input',
      key: 'input',
      render: (_, record) => {
        if (record.schema === 'SRT') {
          return `${record.schema}:${record?.schema_options?.mode || 'N/A'}:${record?.schema_options?.localport || 'N/A'}`;
        }
        return record.schema || 'N/A';
      },
    },
    {
      title: 'Last Updated',
      dataIndex: 'updated_at',
      key: 'updated_at',
      render: (date) => new Date(date).toLocaleString(),
    },
  ];

  return (
    <div>
      <Title level={3} style={{ margin: 0, fontSize: '2rem', fontWeight: 600 }}>Dashboard</Title>

      {/* Route Statistics */}
      <Row gutter={[16, 16]} style={{ marginTop: '16px' }}>
        <Col xs={24} sm={8}>
          <Card>
            <Statistic
              title="Total Routes"
              value={routeStats.total}
              prefix={<ApiOutlined />}
              loading={loading}
            />
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
        <Col xs={24} sm={6}>
          <Card>
            <div style={{ padding: '16px 0' }}>
              <div style={{ fontSize: '14px', color: 'rgba(255, 255, 255, 0.45)' }}>CPU Usage</div>
              <div style={{ fontSize: '24px', marginTop: '8px' }}>{nodeStats.cpu !== null ? `${Math.round(nodeStats.cpu)}%` : 'N/A'}</div>
            </div>
          </Card>
        </Col>
        <Col xs={24} sm={6}>
          <Card>
            <div style={{ padding: '16px 0' }}>
              <div style={{ fontSize: '14px', color: 'rgba(255, 255, 255, 0.45)' }}>RAM Usage</div>
              <div style={{ fontSize: '24px', marginTop: '8px' }}>{nodeStats.ram !== null ? `${Math.round(nodeStats.ram)}%` : 'N/A'}</div>
            </div>
          </Card>
        </Col>
        <Col xs={24} sm={6}>
          <Card>
            <div style={{ padding: '16px 0' }}>
              <div style={{ fontSize: '14px', color: 'rgba(255, 255, 255, 0.45)' }}>SWAP Usage</div>
              <div style={{ fontSize: '24px', marginTop: '8px' }}>{nodeStats.swap !== null ? `${Math.round(nodeStats.swap)}%` : 'N/A'}</div>
            </div>
          </Card>
        </Col>
        <Col xs={24} sm={6}>
          <Card>
            <div style={{ padding: '16px 0' }}>
              <div style={{ fontSize: '14px', color: 'rgba(255, 255, 255, 0.45)' }}>System Load</div>
              <div style={{ fontSize: '24px', marginTop: '8px' }}>{nodeStats.la}</div>
            </div>
          </Card>
        </Col>
      </Row>

      {/* Recent Routes */}
      <Row gutter={[16, 16]} style={{ marginTop: '24px' }}>
        <Col xs={24}>
          <Card
            title={
              <span>
                <ClockCircleOutlined style={{ marginRight: '8px' }} />
                Recent Routes
              </span>
            }
            extra={<a onClick={() => navigate('/routes')}>View All</a>}
          >
            <Table
              columns={recentRoutesColumns}
              dataSource={routeStats.recentRoutes}
              rowKey="id"
              pagination={false}
              loading={loading}
              size="small"
              locale={{ emptyText: 'No routes configured yet' }}
            />
          </Card>
        </Col>
      </Row>
    </div>
  );
};

export default Dashboard;