import { useCallback, useEffect, useState } from 'react';
import { Table, Card, Button, Space, Typography, message, Modal, Tag } from 'antd';
import { ReloadOutlined, StopOutlined, ExclamationCircleFilled, HomeOutlined } from '@ant-design/icons';
import { systemPipelinesApi } from '../../utils/api';
import { ROUTES } from '../../utils/constants';

const { Title } = Typography;

// The engine's start time arrives as `ps` prints it ("Wed Oct 21 10:28:27 2026"). Drop the weekday
// so the column reads as a time, not as a sentence.
const formatStarted = (value) => {
  if (!value) return '—';

  const parts = value.trim().split(' ');
  if (parts.length < 5) return value;

  const [, month, day, clock, year] = parts;
  return `${month} ${day}, ${clock} ${year}`;
};

// Linux single-letter process states, as `ps` prints them in its `s` column. A working pipeline normally
// shows "S": its main thread waits in poll() while its worker threads do the decoding.
const STATE_LABELS = {
  R: 'Running',
  S: 'Sleeping',
  D: 'Uninterruptible',
  T: 'Stopped',
  t: 'Tracing',
  Z: 'Zombie',
  I: 'Idle',
};

const formatState = (value) => STATE_LABELS[value] || value || '—';

const SystemPipelines = () => {
  const [pipelines, setPipelines] = useState([]);
  const [loading, setLoading] = useState(true);
  const [messageApi, contextHolder] = message.useMessage();
  const [modal, modalContextHolder] = Modal.useModal();

  // Set breadcrumb items for the System Pipelines page
  useEffect(() => {
    if (window.setBreadcrumbItems) {
      window.breadcrumbSet = true;
      window.setBreadcrumbItems([
        {
          href: ROUTES.DASHBOARD,
          title: <HomeOutlined />,
        },
        {
          href: ROUTES.SYSTEM_PIPELINES,
          title: 'System Pipelines',
        }
      ]);
    }
  }, []);

  const fetchPipelines = useCallback(async () => {
    try {
      setLoading(true);
      const data = await systemPipelinesApi.getDetailed();
      setPipelines(Array.isArray(data) ? data : []);
    } catch (error) {
      messageApi.error(`Failed to fetch pipeline processes: ${error.message}`);
      console.error('Error:', error);
    } finally {
      setLoading(false);
    }
  }, [messageApi]);

  useEffect(() => {
    fetchPipelines();
    const intervalId = setInterval(fetchPipelines, 5000);

    return () => clearInterval(intervalId);
  }, [fetchPipelines]);

  const showKillConfirm = (record) => {
    modal.confirm({
      title: `Kill pipeline PID ${record.pid}?`,
      icon: <ExclamationCircleFilled />,
      content: `Route: ${record.route_name || record.route_id || 'unknown'}`,
      okText: 'Kill',
      okType: 'danger',
      cancelText: 'Cancel',
      onOk() {
        return handleKill(record.pid);
      },
    });
  };

  const handleKill = async (pid) => {
    try {
      await systemPipelinesApi.kill(pid);
      messageApi.success(`Pipeline PID ${pid} killed`);
      fetchPipelines();
    } catch (error) {
      messageApi.error(`Failed to kill process: ${error.message}`);
      console.error('Error:', error);
    }
  };

  const formatBytes = (bytes, decimals = 2) => {
    if (!Number.isFinite(bytes) || bytes === 0) return '0 B';

    const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(1024));
    return parseFloat((bytes / Math.pow(1024, i)).toFixed(decimals)) + ' ' + sizes[i];
  };

  const cpuColor = (value) => {
    if (value > 80) return 'red';
    if (value > 50) return 'orange';
    return 'green';
  };

  const columns = [
    {
      title: 'PID',
      dataIndex: 'pid',
      key: 'pid',
      width: 90,
      sorter: (a, b) => a.pid - b.pid,
    },
    {
      title: 'Route',
      key: 'route',
      sorter: (a, b) => (a.route_name || a.route_id || '').localeCompare(b.route_name || b.route_id || ''),
      render: (_, record) => record.route_name || record.route_id || '—',
    },
    {
      title: 'CPU',
      dataIndex: 'cpu_percent',
      key: 'cpu',
      width: 100,
      sorter: (a, b) => (a.cpu_percent ?? -1) - (b.cpu_percent ?? -1),
      render: (_, record) =>
        Number.isFinite(record.cpu_percent) ? (
          <Tag color={cpuColor(record.cpu_percent)}>{record.cpu_percent.toFixed(1)}%</Tag>
        ) : (
          <Tag>{record.cpu_average || '—'}</Tag>
        ),
    },
    {
      title: 'Memory',
      dataIndex: 'resident_memory',
      key: 'memory',
      width: 110,
      sorter: (a, b) => (a.memory_bytes ?? 0) - (b.memory_bytes ?? 0),
      render: (_, record) => record.resident_memory || record.memory || '—',
    },
    {
      title: 'Threads',
      dataIndex: 'thread_count',
      key: 'thread_count',
      width: 100,
      sorter: (a, b) => (a.thread_count ?? -1) - (b.thread_count ?? -1),
      render: (value) => value ?? '—',
    },
    {
      title: 'State',
      dataIndex: 'state',
      key: 'state',
      width: 120,
      render: (value) => <Tag>{formatState(value)}</Tag>,
    },
    {
      title: 'Started',
      dataIndex: 'start_time',
      key: 'start_time',
      width: 190,
      render: formatStarted,
    },
    {
      title: 'Actions',
      key: 'actions',
      width: 110,
      render: (_, record) => (
        <Button
          danger
          icon={<StopOutlined />}
          onClick={() => showKillConfirm(record)}
        >
          Kill
        </Button>
      ),
    },
  ];

  const expandedRowRender = (record) => {
    const items = [
      { label: 'PID', value: record.pid },
      { label: 'Route', value: record.route_name || '—' },
      { label: 'Route ID', value: record.route_id || '—' },
      {
        label: 'CPU now (1 core = 100%)',
        value: Number.isFinite(record.cpu_percent)
          ? `${record.cpu_percent.toFixed(1)}%`
          : '—'
      },
      { label: 'CPU average (1 core = 100%)', value: record.cpu_average || '—' },
      { label: 'CPU time', value: record.cpu_time || '—' },
      { label: 'Memory', value: `${record.resident_memory || record.memory || '—'} (${record.memory_percent || '—'})` },
      { label: 'Virtual memory', value: record.virtual_memory || '—' },
      { label: 'Swap', value: record.swap || formatBytes(record.swap_bytes) },
      { label: 'Threads', value: record.thread_count ?? '—' },
      { label: 'State', value: formatState(record.state) },
      { label: 'Parent PID', value: record.ppid ?? '—' },
      { label: 'User', value: record.user || '—' },
      { label: 'Started', value: record.start_time || '—' },
    ];

    return (
      <Card title="Detailed Information" size="small">
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: '12px' }}>
          {items.map((item, index) => (
            <div key={index}>
              <strong>{item.label}:</strong> {item.value}
            </div>
          ))}
        </div>
      </Card>
    );
  };

  return (
    <div>
      {contextHolder}
      {modalContextHolder}
      <Space direction="vertical" size="large" style={{ width: '100%' }}>
        <Space style={{ width: '100%', justifyContent: 'space-between' }}>
          <Title level={3} style={{ margin: 0, fontSize: '2rem', fontWeight: 600 }}>System Pipelines</Title>
          <Button
            type="primary"
            icon={<ReloadOutlined />}
            onClick={fetchPipelines}
          >
            Refresh
          </Button>
        </Space>

        <Card>
          <Table
            columns={columns}
            dataSource={pipelines}
            rowKey="pid"
            loading={loading}
            size="middle"
            expandable={{
              expandedRowRender,
            }}
            pagination={{
              defaultPageSize: 10,
              showSizeChanger: true,
              showTotal: (total) => `${total} pipelines`,
            }}
          />
        </Card>
      </Space>
    </div>
  );
};

export default SystemPipelines;
