import { useEffect, useState } from 'react';
import {
  Card,
  Typography,
  Space,
  Tag,
  Row,
  Col,
  Button,
  Table,
  Modal,
  Descriptions,
  Collapse,
  message,
  Input,
  Alert
} from 'antd';
import {
  PlayCircleOutlined,
  PauseCircleOutlined,
  EditOutlined,
  DeleteOutlined,
  PlusOutlined,
  ExclamationCircleFilled,
  HomeOutlined,
  LoadingOutlined,
  SearchOutlined,
  CopyOutlined
} from '@ant-design/icons';
import { useParams, useNavigate } from 'react-router-dom';
import { routesApi, destinationsApi } from '../../utils/api';
import { DEVICE_TO_SDI } from '../../utils/sdiPorts';
import RouteStats from '../../components/RouteStats';
import DestinationStats from '../../components/DestinationStats';

const { Title, Text } = Typography;

const RouteItem = () => {
  const navigate = useNavigate();
  const { id } = useParams();
  const [routeData, setRouteData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [messageApi, contextHolder] = message.useMessage();
  const [modal, modalContextHolder] = Modal.useModal();
  const [destinationFilter, setDestinationFilter] = useState('');

  // Breadcrumb setup
  useEffect(() => {
    if (window.setBreadcrumbItems) {
      window.breadcrumbSet = true;
      window.setBreadcrumbItems([
        {
          href: '/',
          title: <HomeOutlined />,
        },
        {
          href: '/routes',
          title: 'Routes',
        },
        {
          title: loading ? <><LoadingOutlined style={{ marginRight: 8 }} />Loading...</> : (routeData ? routeData.name : 'Route Details'),
        }
      ]);
    }
  }, [id, routeData, loading]);

  // Fetch route data
  useEffect(() => {
    fetchRouteData();
  }, [id]);

  // Automatic failover changes persisted route state outside this page. Poll
  // route metadata while failover is running so active-source badges follow
  // native acknowledgements without requiring manual refresh.
  useEffect(() => {
    const routeStatus = routeData?.status?.toLowerCase();
    const failoverRunning =
      routeData?.failover_enabled && ['started', 'reconnecting'].includes(routeStatus);

    if (!failoverRunning) return undefined;

    let cancelled = false;
    const interval = window.setInterval(async () => {
      try {
        const result = await routesApi.getById(id);
        if (!cancelled) setRouteData(result.data);
      } catch (error) {
        console.error('Failed to refresh failover route state:', error);
      }
    }, 3000);

    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, [id, routeData?.failover_enabled, routeData?.status]);

  const fetchRouteData = async () => {
    try {
      const result = await routesApi.getById(id);
      setRouteData(result.data);
    } catch (error) {
      messageApi.error(`Failed to fetch route data: ${error.message}`);
      console.error('Error:', error);
    } finally {
      setLoading(false);
    }
  };

  // Status color and button mapping
  const getStatusDetails = (routeData) => {
    // First check if routeData exists
    if (!routeData) {
      return {
        color: 'default',
        buttonColor: 'default',
        buttonIcon: <PlayCircleOutlined />,
        buttonText: 'Start',
        buttonType: 'default'
      };
    }

    // Check if status field exists and use it as the primary indicator
    if (routeData.status) {
      const status = routeData.status.toLowerCase();

      if (status === 'started') {
        return {
          color: 'success',
          buttonColor: 'default',
          buttonIcon: <PauseCircleOutlined />,
          buttonText: 'Stop',
          buttonType: 'default'
        };
      } else if (status === 'reconnecting') {
        return {
          color: 'warning',
          buttonColor: 'default',
          buttonIcon: <PauseCircleOutlined />,
          buttonText: 'Stop',
          buttonType: 'default'
        };
      } else {
        return {
          color: 'error',
          buttonColor: 'primary',
          buttonIcon: <PlayCircleOutlined />,
          buttonText: 'Start',
          buttonType: 'primary'
        };
      }
    } else {
      // Fallback if status field is not available (should not happen)
      return {
        color: 'warning',
        buttonColor: 'primary',
        buttonIcon: <PlayCircleOutlined />,
        buttonText: 'Start',
        buttonType: 'primary'
      };
    }
  };

  // Destination table columns
  const destinationColumns = [
    {
      title: 'Name',
      dataIndex: 'name',
      key: 'name',
      sorter: (a, b) => (a?.name || '').localeCompare(b?.name || ''),
      render: (text, record) => (
        <Space>
          <a href={`#/routes/${id}/destinations/${record.id}/edit`}>
            {text || 'Unnamed'}
          </a>
        </Space>
      ),
    },
    {
      title: 'Schema',
      dataIndex: 'schema',
      key: 'schema',
      filters: [
        { text: 'SRT', value: 'SRT' },
        { text: 'Other', value: 'Other' }
      ],
      onFilter: (value, record) => record?.schema === value,
      render: (schema) => (
        <Tag color={schema === 'SRT' ? 'blue' : 'orange'}>
          {schema || 'N/A'}
        </Tag>
      ),
    },
    {
      title: 'Destination',
      key: 'host_port',
      render: (_, record) => {
        if (!record) return '—';
        switch (record.schema) {
          case 'SRT':
            return `${record.schema_options?.localaddress || 'N/A'}:${record.schema_options?.localport || 'N/A'}:${record.schema_options?.mode || 'N/A'}`;
          case 'UDP':
            return `${record.schema_options?.host || record.schema_options?.address || 'N/A'}:${record.schema_options?.port || 'N/A'}`;
          case 'SDI': {
            const port = DEVICE_TO_SDI[record.schema_options?.device_number] ?? '?';
            const modeMap = { 0: 'Auto', 9: '1080p25', 11: '1080p30', 12: '1080p50', 13: '1080p60', 7: '1080i50', 8: '1080i60', 14: '720p50', 15: '720p60', 17: 'PAL', 18: 'NTSC', 22: '4K25', 23: '4K30', 24: '4K50', 25: '4K60' };
            const mode = modeMap[record.schema_options?.video_mode] || '1080p25';
            return `SDI ${port} · ${mode}`;
          }
          default:
            return '—';
        }
      },
      sorter: (a, b) => {
        const aPort = a?.schema_options?.localport || a?.schema_options?.port || 0;
        const bPort = b?.schema_options?.localport || b?.schema_options?.port || 0;
        return aPort - bPort;
      },
    },
    {
      title: 'Latency',
      key: 'latency',
      render: (_, record) => {
        if (record?.schema === 'SDI') return '—';
        const latency = record?.schema_options?.latency || record?.latency;
        return latency ? `${latency}ms` : '—';
      },
      sorter: (a, b) => {
        const aLatency = a?.schema_options?.latency || a?.latency || 0;
        const bLatency = b?.schema_options?.latency || b?.latency || 0;
        return aLatency - bLatency;
      },
    },
    {
      title: 'Last Updated',
      dataIndex: 'updated_at',
      key: 'updated_at',
      render: (date) => date ? new Date(date).toLocaleString() : '—',
      sorter: (a, b) => new Date(a?.updated_at || 0) - new Date(b?.updated_at || 0),
    },
    {
      title: 'Actions',
      key: 'actions',
      render: (_, record) => (
        <Space>
          <Button
            type="link"
            icon={<EditOutlined />}
            aria-label={`Edit destination ${record.name}`}
            onClick={() => navigate(`/routes/${id}/destinations/${record.id}/edit`)}
          >
            Edit
          </Button>
          <Button
            type="link"
            danger
            icon={<DeleteOutlined />}
            aria-label={`Delete destination ${record.name}`}
            onClick={() => handleDeleteDestination(record)}
          >
            Delete
          </Button>
        </Space>
      ),
    },
  ];

  // Delete destination handler
  const handleDeleteDestination = (record) => {
    modal.confirm({
      title: 'Are you sure you want to delete this destination?',
      icon: <ExclamationCircleFilled />,
      content: `Destination: ${record.name}`,
      okText: 'Yes, delete',
      okType: 'danger',
      cancelText: 'No, cancel',
      onOk() {
        return deleteDestination(record.id);
      },
    });
  };

  // Delete destination API call
  const deleteDestination = async (destId) => {
    try {
      await destinationsApi.delete(id, destId);
      messageApi.success('Destination deleted successfully');
      fetchRouteData(); // Refresh the data
    } catch (error) {
      messageApi.error(`Failed to delete destination: ${error.message}`);
      console.error('Error:', error);
    }
  };

  if (loading) {
    return (
      <div style={{ padding: '24px' }}>
        <Card loading={true} />
      </div>
    );
  }

  if (!routeData) {
    return (
      <div style={{ padding: '24px' }}>
        {contextHolder}
        <Alert
          message="Route Not Found"
          description="The requested route could not be found or may have been deleted."
          type="error"
          showIcon
          action={
            <Button type="primary" onClick={() => navigate('/routes')}>
              Back to Routes
            </Button>
          }
        />
      </div>
    );
  }

  // Get status details
  const statusDetails = getStatusDetails(routeData);

  // Helper function to check if route is started
  const isRouteStarted = routeData && routeData.status && routeData.status.toLowerCase() === 'started';

  // Failover mode human-readable labels
  const failoverModeLabels = {
    'maintain-primary': 'Maintain Primary',
    'maintain-stability': 'Maintain Stability',
    'manual-switchback': 'Manual Switchback',
    'manual': 'Manual',
  };

  // Switch failover source handler
  const handleSwitchSource = async () => {
    const target = (routeData.active_source || 'primary') === 'primary' ? 'secondary' : 'primary';
    try {
      await routesApi.switchSource(id, target);
      messageApi.success(`Source switch to ${target} requested`);
      fetchRouteData();
    } catch (error) {
      messageApi.error(`Failed to switch source: ${error.message}`);
    }
  };

  // Route status toggle handler
  const handleRouteStatusToggle = async () => {
    try {
      let result;
      if (routeData.status && routeData.status.toLowerCase() === 'started') {
        // If the route is started, stop it
        result = await routesApi.stop(id);

        // Only update if result has data
        if (result && result.data) {
          setRouteData(prev => ({
            ...prev,
            status: result.data.status
          }));
        } else {
          // If no data is returned, assume the route is stopped
          setRouteData(prev => ({
            ...prev,
            status: 'stopped'
          }));
        }

        messageApi.success('Route stopped successfully');
      } else {
        // If the route is not started, start it
        result = await routesApi.start(id);

        // Only update if result has data
        if (result && result.data) {
          setRouteData(prev => ({
            ...prev,
            status: result.data.status
          }));
        } else {
          // If no data is returned, assume the route is started
          setRouteData(prev => ({
            ...prev,
            status: 'started'
          }));
        }

        messageApi.success('Route started successfully');
      }
    } catch (error) {
      // Handle specific error cases
      if (error.message && error.message.includes('already_started')) {
        messageApi.info('Route is already started');

        // Update the UI to reflect that the route is started
        setRouteData(prev => ({
          ...prev,
          status: 'started'
        }));
      } else if (error.message && error.message.includes('not_found')) {
        messageApi.info('Route process not found. It may have already been stopped.');

        // Update the UI to reflect that the route is stopped
        setRouteData(prev => ({
          ...prev,
          status: 'stopped'
        }));
      } else if (error.response && error.response.status === 422) {
        // Handle 422 Unprocessable Entity error
        messageApi.error('Invalid request. The server could not process the request.');

        // Keep the current state
        console.error('422 Error:', error);
      } else {
        const action = isRouteStarted ? 'stop' : 'start';
        messageApi.error(`Failed to ${action} route: ${error.message}`);
      }
      console.error('Error:', error);
    }
  };

  // Route deletion handler
  const handleRouteDelete = () => {
    modal.confirm({
      title: 'Are you sure you want to delete this route?',
      icon: <ExclamationCircleFilled />,
      content: `Route: ${routeData.name}`,
      okText: 'Yes, delete',
      okType: 'danger',
      cancelText: 'No, cancel',
      onOk() {
        return deleteRoute();
      },
    });
  };

  // Delete route API call
  const deleteRoute = async () => {
    try {
      await routesApi.delete(id);
      messageApi.success('Route deleted successfully');
      navigate('/routes');
    } catch (error) {
      messageApi.error(`Failed to delete route: ${error.message}`);
      console.error('Error:', error);
    }
  };

  // Filter destinations safely
  const filteredDestinations = (routeData?.destinations || []).filter(dest => {
    if (!dest) return false;
    const filter = (destinationFilter || '').toLowerCase();
    if (!filter) return true;
    const nameMatch = (dest.name || '').toLowerCase().includes(filter);
    const hostMatch = (dest.host || dest.schema_options?.localaddress || dest.schema_options?.address || '').toString().toLowerCase().includes(filter);
    return nameMatch || hostMatch;
  });

  return (
    <Space
      direction="vertical"
      size="large"
      style={{
        width: '100%',
        padding: '0 24px',
        '@media(maxWidth: 768px)': {
          padding: '0 12px'
        }
      }}
    >
      {contextHolder}
      {modalContextHolder}

      {routeData && routeData.status && routeData.status.toLowerCase() === 'error' && (
        <Alert
          message="Hardware / Driver Error"
          description={routeData.error_message || "The DeckLink hardware or kernel driver has stopped responding. Please verify PCIe installation and ensure DesktopVideoHelper is running."}
          type="error"
          showIcon
          style={{ marginBottom: 16 }}
        />
      )}

      {/* Route Info Card */}
      <Card style={{ marginBottom: 24 }}>
        <Row justify="space-between" align="middle">
          <Col>
            <Space direction="vertical" size="small">
              <Title level={4} style={{ margin: 0 }}>{routeData.name}</Title>
              <Space>
                <Tag color={statusDetails.color}>
                  {routeData.status ? routeData.status.charAt(0).toUpperCase() + routeData.status.slice(1) : 'Unknown'}
                </Tag>
                <Text type="secondary">
                  Last Updated: {new Date(routeData.updated_at).toLocaleString()}
                </Text>
              </Space>
            </Space>
          </Col>
          <Col>
            <Space>
              <Button
                type={statusDetails.buttonType}
                icon={statusDetails.buttonIcon}
                onClick={handleRouteStatusToggle}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  minWidth: '80px'
                }}
              >
                {statusDetails.buttonText}
              </Button>
              {isRouteStarted && routeData.failover_enabled && (
                <Button onClick={handleSwitchSource}>
                   Switch to {(routeData.active_source || 'primary') === 'primary' ? 'Secondary' : 'Primary'}
                </Button>
              )}
              <Button
                icon={<CopyOutlined />}
                onClick={async () => {
                  const loadingMsg = messageApi.loading(`Cloning "${routeData.name}"...`, 0);
                  try {
                    const result = await routesApi.clone(id);
                    loadingMsg();
                    messageApi.success(`Route cloned successfully`);
                    navigate(`/routes/${result.data.id}`);
                  } catch (error) {
                    loadingMsg();
                    messageApi.error(`Failed to clone: ${error.message}`);
                  }
                }}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  minWidth: '80px'
                }}
              >
                Clone
              </Button>
              <Button
                danger
                type="primary"
                icon={<DeleteOutlined />}
                onClick={handleRouteDelete}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  minWidth: '80px'
                }}
              >
                Delete
              </Button>
            </Space>
          </Col>
        </Row>
      </Card>

      {/* Source Details */}
      <Card
        title="Source Configuration"
        style={{ marginBottom: 24 }}
        extra={
          <Button
            onClick={() => navigate(`/routes/${id}/edit`)}
            icon={<EditOutlined />}
          >
            Edit
          </Button>
        }
      >
        <Descriptions
          column={2}
          bordered
          styles={{ content: { textAlign: 'left' } }}
        >
          <Descriptions.Item label="Source">
            <Tag color={routeData.schema === 'SRT' ? 'blue' : routeData.schema === 'RTMP' ? 'purple' : 'orange'}>
              {routeData.schema}
            </Tag>
            {' '}
            {routeData.schema === 'SRT' ?
              `${routeData.schema_options?.localaddress || 'N/A'}:${routeData.schema_options?.localport || 'N/A'}:${routeData.schema_options?.mode || 'N/A'}` :
              routeData.schema === 'UDP' ?
                `${routeData.schema_options?.address || 'N/A'}:${routeData.schema_options?.port || 'N/A'}` :
                (routeData.schema_options?.url || 'N/A')
            }
          </Descriptions.Item>
          <Descriptions.Item label="Node">{routeData.node}</Descriptions.Item>

          {routeData.schema === 'SRT' ? (
            <>
              <Descriptions.Item label="Stream ID">
                {routeData.schema_options?.streamid ? (
                  <Tag color="geekblue">{routeData.schema_options.streamid}</Tag>
                ) : (
                  <Text type="secondary">None</Text>
                )}
              </Descriptions.Item>
              <Descriptions.Item label="Latency">{routeData.schema_options?.latency ? `${routeData.schema_options.latency}ms` : 'Default (125ms)'}</Descriptions.Item>
              <Descriptions.Item label="Auto Reconnect">
                <Tag color={routeData.schema_options?.['auto-reconnect'] ? 'green' : 'red'}>
                  {routeData.schema_options?.['auto-reconnect'] ? 'Enabled' : 'Disabled'}
                </Tag>
              </Descriptions.Item>
              <Descriptions.Item label="Keep Listening">
                <Tag color={routeData.schema_options?.['keep-listening'] ? 'green' : 'red'}>
                  {routeData.schema_options?.['keep-listening'] ? 'Enabled' : 'Disabled'}
                </Tag>
              </Descriptions.Item>
              <Descriptions.Item label="Authentication">
                <Tag color={routeData.schema_options?.authentication ? 'green' : 'red'}>
                  {routeData.schema_options?.authentication ? 'Enabled' : 'Disabled'}
                </Tag>
              </Descriptions.Item>
              {routeData.schema_options?.authentication === true && (
                <Descriptions.Item label="Key Length">
                  {routeData.schema_options?.pbkeylen !== undefined ? routeData.schema_options.pbkeylen : '0 (Default)'}
                </Descriptions.Item>
              )}
            </>
          ) : routeData.schema === 'UDP' ? (
            <>
              <Descriptions.Item label="Address">{routeData.schema_options?.address || '0.0.0.0 (Default)'}</Descriptions.Item>
              <Descriptions.Item label="Port">{routeData.schema_options?.port || 'N/A'}</Descriptions.Item>
              <Descriptions.Item label="Buffer Size">{routeData.schema_options?.['buffer-size'] ? `${routeData.schema_options['buffer-size']} bytes` : '0 bytes (Default)'}</Descriptions.Item>
              <Descriptions.Item label="MTU">{routeData.schema_options?.mtu || '1492 (Default)'}</Descriptions.Item>
            </>
          ) : null}

          {routeData.failover_enabled && (
            <>
              <Descriptions.Item label="Failover Mode">
                {failoverModeLabels[routeData.failover_mode] || routeData.failover_mode}
              </Descriptions.Item>
              <Descriptions.Item label="Active Source">
                <Tag color={(routeData.active_source || 'primary') === 'primary' ? 'blue' : 'orange'}>
                  {(routeData.active_source || 'primary').toUpperCase()}
                </Tag>
              </Descriptions.Item>
              <Descriptions.Item label="SDI Switch Strategy">
                {routeData.seamless_sdi_failover ? (
                  <Tag color="green">KEYFRAME-GATED</Tag>
                ) : (
                  <Tag>RESTART FALLBACK</Tag>
                )}
              </Descriptions.Item>
              <Descriptions.Item label="Secondary Source">
                <Tag color="orange">
                  {routeData.secondary_source?.schema || 'SRT'}
                </Tag>
                {' '}
                {`${routeData.secondary_source?.schema_options?.localaddress || 'N/A'}:${routeData.secondary_source?.schema_options?.localport || 'N/A'}:${routeData.secondary_source?.schema_options?.mode || 'N/A'}`}
              </Descriptions.Item>
              <Descriptions.Item label="Secondary Stream ID">
                {routeData.secondary_source?.schema_options?.streamid ? (
                  <Tag color="geekblue">{routeData.secondary_source.schema_options.streamid}</Tag>
                ) : (
                  <Text type="secondary">None</Text>
                )}
              </Descriptions.Item>
            </>
          )}
        </Descriptions>
      </Card>

      {/* Source Statistics - Show when route is running */}
      <RouteStats
        routeId={id}
        isRunning={routeData?.status?.toLowerCase() === 'started'}
        failoverEnabled={routeData?.failover_enabled}
        activeSource={routeData?.active_source || 'primary'}
      />

      {/* Destination Statistics - Show when route is running and has SRT destinations */}
      <DestinationStats
        routeId={id}
        isRunning={routeData?.status?.toLowerCase() === 'started'}
        destinations={routeData?.destinations || []}
      />

      {/* Destinations Table */}
      <Card
        title="Destinations"
        extra={
          <Button
            type="primary"
            icon={<PlusOutlined />}
            onClick={() => navigate(`/routes/${id}/destinations/new/edit`)}
          >
            Add Destination
          </Button>
        }
      >
        <Input
          prefix={<SearchOutlined />}
          placeholder="Filter destinations by name or host"
          style={{ marginBottom: 16, width: '100%' }}
          value={destinationFilter}
          onChange={(e) => setDestinationFilter(e.target.value)}
        />
        <Table
          columns={destinationColumns}
          dataSource={filteredDestinations}
          rowKey="id"
          pagination={{
            defaultPageSize: 10,
            showSizeChanger: true,
            showTotal: (total) => `Total ${total} destinations`,
          }}
          scroll={{ x: true }}
          expandable={{
            expandedRowRender: record => {
              if (record.schema !== 'SRT' || !record.schema_options || !record.schema_options.authentication) {
                return null;
              }

              return (
                <Card size="small" title="Authentication Details" style={{ margin: '0 16px' }}>
                  <Descriptions column={2} size="small">
                    <Descriptions.Item label="Authentication">
                      <Tag color="green">Enabled</Tag>
                    </Descriptions.Item>
                    <Descriptions.Item label="Key Length">
                      {record.schema_options.pbkeylen || '0 (Default)'}
                    </Descriptions.Item>
                  </Descriptions>
                </Card>
              );
            },
            rowExpandable: record => record.schema === 'SRT' && record.schema_options && record.schema_options.authentication,
          }}
        />
      </Card>
    </Space>
  );
};

export default RouteItem;
