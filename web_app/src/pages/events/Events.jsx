import { useEffect, useState } from 'react';
import { Card, Table, Tag, Space, Typography, Select, Button, Badge, message } from 'antd';
import { HomeOutlined, ClearOutlined, ReloadOutlined } from '@ant-design/icons';
import { eventsApi } from '../../utils/api';

const { Title, Text } = Typography;

const severityColors = {
  info: 'blue',
  warning: 'orange',
  critical: 'red',
};

const severityLabels = {
  info: 'Info',
  warning: 'Warning',
  critical: 'Critical',
};

const Events = () => {
  const [events, setEvents] = useState([]);
  const [loading, setLoading] = useState(true);
  const [severityFilter, setSeverityFilter] = useState('all');
  const [messageApi, contextHolder] = message.useMessage();

  useEffect(() => {
    if (window.setBreadcrumbItems) {
      window.breadcrumbSet = true;
      window.setBreadcrumbItems([
        { href: '/', title: <HomeOutlined /> },
        { title: 'Events' },
      ]);
    }
  }, []);

  useEffect(() => {
    fetchEvents();
    const interval = setInterval(() => fetchEvents(true), 5000);
    return () => clearInterval(interval);
  }, [severityFilter]);

  const fetchEvents = async (silent = false) => {
    try {
      if (!silent) setLoading(true);
      const params = { limit: '200' };
      if (severityFilter !== 'all') params.severity = severityFilter;
      const result = await eventsApi.getAll(params);
      setEvents(result.data || []);
    } catch (error) {
      if (!silent) messageApi.error(`Failed to fetch events: ${error.message}`);
    } finally {
      if (!silent) setLoading(false);
    }
  };

  const handleClear = async () => {
    try {
      await eventsApi.clear();
      setEvents([]);
      messageApi.success('Events cleared');
    } catch (error) {
      messageApi.error(`Failed to clear events: ${error.message}`);
    }
  };

  const columns = [
    {
      title: 'Time',
      dataIndex: 'timestamp',
      key: 'timestamp',
      width: 180,
      render: (ts) => new Date(ts).toLocaleString(),
    },
    {
      title: 'Severity',
      dataIndex: 'severity',
      key: 'severity',
      width: 100,
      render: (severity) => (
        <Tag color={severityColors[severity]}>
          {severityLabels[severity] || severity}
        </Tag>
      ),
    },
    {
      title: 'Message',
      dataIndex: 'message',
      key: 'message',
      render: (text, record) => (
        <Space direction="vertical" size={0}>
          <Text>{text}</Text>
          {record.metadata?.route_name && (
            <Text type="secondary" style={{ fontSize: 12 }}>
              Route: {record.metadata.route_name}
            </Text>
          )}
        </Space>
      ),
    },
    {
      title: 'Type',
      dataIndex: 'type',
      key: 'type',
      width: 160,
      render: (type) => (
        <Text code style={{ fontSize: 11 }}>{type}</Text>
      ),
    },
  ];

  return (
    <div>
      {contextHolder}
      <Space direction="vertical" size="large" style={{ width: '100%' }}>
        <Space style={{ width: '100%', justifyContent: 'space-between' }}>
          <Title level={3} style={{ margin: 0, fontSize: '2rem', fontWeight: 600 }}>Events</Title>
          <Space>
            <Button icon={<ReloadOutlined />} onClick={() => fetchEvents()}>Refresh</Button>
            <Button icon={<ClearOutlined />} danger onClick={handleClear}>Clear All</Button>
          </Space>
        </Space>

        <Card>
          <Space style={{ marginBottom: 16 }}>
            <Select
              value={severityFilter}
              onChange={setSeverityFilter}
              style={{ width: 160 }}
              options={[
                { label: 'All Severities', value: 'all' },
                { label: '🔴 Critical', value: 'critical' },
                { label: '🟡 Warning', value: 'warning' },
                { label: '🔵 Info', value: 'info' },
              ]}
            />
            <Badge count={events.filter(e => e.severity === 'critical').length} style={{ backgroundColor: '#ff4d4f' }}>
              <Tag color="red">Critical</Tag>
            </Badge>
            <Badge count={events.filter(e => e.severity === 'warning').length} style={{ backgroundColor: '#faad14' }}>
              <Tag color="orange">Warning</Tag>
            </Badge>
          </Space>

          <Table
            columns={columns}
            dataSource={events}
            rowKey="id"
            loading={loading}
            pagination={{
              defaultPageSize: 20,
              showSizeChanger: true,
              showTotal: (total) => `${total} events`,
            }}
            size="small"
          />
        </Card>
      </Space>
    </div>
  );
};

export default Events;
