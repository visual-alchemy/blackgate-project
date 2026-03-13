import { useEffect, useState } from 'react';
import { Table, Card, Button, Tag, Space, Typography, message, Modal, Input, Select, Badge } from 'antd';
import { PlusOutlined, EditOutlined, DeleteOutlined, ExclamationCircleFilled, CaretRightOutlined, StopOutlined, HomeOutlined, CopyOutlined, SearchOutlined, TagOutlined } from '@ant-design/icons';
import { useNavigate } from 'react-router-dom';
import { routesApi } from '../../utils/api';
import HealthBadge from '../../components/HealthBadge';

const { Title } = Typography;

const Routes = () => {
  const [routes, setRoutes] = useState([]);
  const [loading, setLoading] = useState(true);
  const [messageApi, contextHolder] = message.useMessage();
  const [modal, modalContextHolder] = Modal.useModal();
  const navigate = useNavigate();
  const [selectedRowKeys, setSelectedRowKeys] = useState([]);
  const [searchText, setSearchText] = useState(() => sessionStorage.getItem('routes_search') || '');
  const [statusFilter, setStatusFilter] = useState(() => sessionStorage.getItem('routes_status') || 'all');
  const [schemaFilter, setSchemaFilter] = useState(() => sessionStorage.getItem('routes_schema') || 'all');
  const [tagFilter, setTagFilter] = useState(() => sessionStorage.getItem('routes_tag') || 'all');
  const [availableTags, setAvailableTags] = useState([]);
  const [bulkLoading, setBulkLoading] = useState(false);

  // Persist filters to sessionStorage
  useEffect(() => { sessionStorage.setItem('routes_search', searchText); }, [searchText]);
  useEffect(() => { sessionStorage.setItem('routes_status', statusFilter); }, [statusFilter]);
  useEffect(() => { sessionStorage.setItem('routes_schema', schemaFilter); }, [schemaFilter]);
  useEffect(() => { sessionStorage.setItem('routes_tag', tagFilter); }, [tagFilter]);

  // Set breadcrumb items for the Routes page
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
        }
      ]);
    }
  }, []);

  useEffect(() => {
    fetchRoutes();
    routesApi.getTags().then(r => {
      const tags = r.data || [];
      setAvailableTags(tags.map(t => ({ label: t, value: t })));
    }).catch(() => {});
  }, []);

  const fetchRoutes = async () => {
    try {
      setLoading(true);
      const result = await routesApi.getAll();
      setRoutes(result.data);
    } catch (error) {
      messageApi.error(`Failed to fetch routes: ${error.message}`);
      console.error('Error:', error);
    } finally {
      setLoading(false);
    }
  };

  const showDeleteConfirm = (record) => {
    modal.confirm({
      title: 'Are you sure you want to delete this route?',
      icon: <ExclamationCircleFilled />,
      content: `Route: ${record.name}`,
      okText: 'Yes, delete',
      okType: 'danger',
      cancelText: 'No, cancel',
      onOk() {
        return handleDelete(record.id);
      },
    });
  };

  const handleDelete = async (id) => {
    try {
      await routesApi.delete(id);
      messageApi.success('Route deleted successfully');
      fetchRoutes(); // Refresh the list
    } catch (error) {
      messageApi.error(`Failed to delete route: ${error.message}`);
      console.error('Error:', error);
    }
  };

  const handleRouteStatus = async (id, action) => {
    try {
      const result = action === 'start'
        ? await routesApi.start(id)
        : await routesApi.stop(id);

      // Update the specific route in the routes array
      setRoutes(routes.map(route =>
        route.id === id ? { ...route, status: result.data.status } : route
      ));

      messageApi.success(`Route ${action}ed successfully`);
    } catch (error) {
      messageApi.error(`Failed to ${action} route: ${error.message}`);
      console.error('Error:', error);
    }
  };

  // Bulk action handler
  const handleBulkAction = async (action) => {
    if (selectedRowKeys.length === 0) return;

    setBulkLoading(true);
    try {
      const result = await routesApi.bulkAction(action, selectedRowKeys);
      const successCount = result.data.filter(r => r.status && !r.error).length;
      const failCount = result.data.filter(r => r.error).length;

      if (failCount > 0) {
        messageApi.warning(`${successCount} routes ${action}ed, ${failCount} failed`);
      } else {
        messageApi.success(`${successCount} routes ${action}ed successfully`);
      }

      setSelectedRowKeys([]);
      fetchRoutes();
    } catch (error) {
      messageApi.error(`Bulk ${action} failed: ${error.message}`);
    } finally {
      setBulkLoading(false);
    }
  };

  // Clone handler
  const handleClone = async (id, name) => {
    const loadingMessage = messageApi.loading(`Cloning "${name}"...`, 0);
    try {
      await routesApi.clone(id);
      loadingMessage();
      messageApi.success(`Route "${name}" cloned successfully`);
      fetchRoutes();
    } catch (error) {
      loadingMessage();
      messageApi.error(`Failed to clone route: ${error.message}`);
    }
  };

  // Filter routes
  const filteredRoutes = routes.filter(route => {
    const matchesSearch = !searchText ||
      (route.name || '').toLowerCase().includes(searchText.toLowerCase());
    const matchesStatus = statusFilter === 'all' ||
      (route.status || '').toLowerCase() === statusFilter;
    const matchesSchema = schemaFilter === 'all' ||
      (route.schema || '').toUpperCase() === schemaFilter;
    const matchesTag = tagFilter === 'all' ||
      (route.tags || []).includes(tagFilter);
    return matchesSearch && matchesStatus && matchesSchema && matchesTag;
  });

  // Row selection config
  const rowSelection = {
    selectedRowKeys,
    onChange: (keys) => setSelectedRowKeys(keys),
  };

  const columns = [
    {
      title: 'Name',
      dataIndex: 'name',
      key: 'name',
      sorter: (a, b) => (a.name || '').localeCompare(b.name || ''),
      render: (text, record) => {
        const tags = record.tags || [];
        return (
          <Space direction="vertical" size={2}>
            <a href={`#/routes/${record.id}`}>{text}</a>
            {tags.length > 0 && (
              <Space size={4} wrap>
                {tags.map(tag => (
                  <Tag
                    key={tag}
                    icon={<TagOutlined />}
                    color="geekblue"
                    style={{ fontSize: 11, cursor: 'pointer' }}
                    onClick={() => setTagFilter(tag)}
                  >
                    {tag}
                  </Tag>
                ))}
              </Space>
            )}
          </Space>
        );
      },
    },
    {
      title: 'Enabled',
      dataIndex: 'enabled',
      key: 'enabled',
      render: (schema) => (
        <Tag color={schema ? 'green' : 'gray'}>
          {schema ? 'yes' : 'no'}
        </Tag>
      ),
    },
    {
      title: 'Status',
      dataIndex: 'status',
      key: 'status',
      sorter: (a, b) => (a.status || '').localeCompare(b.status || ''),
    },
    {
      title: 'Health',
      key: 'health',
      render: (_, record) => (
        <HealthBadge routeId={record.id} isRunning={record.status === 'started'} />
      ),
    },
    {
      title: 'Authentication',
      key: 'authentication',
      render: (_, record) => {
        if (record.schema !== 'SRT') return <Tag color="default">N/A</Tag>;
        return record.schema_options && record.schema_options.authentication ? (
          <Tag color="green">yes</Tag>
        ) : (
          <Tag color="default">no</Tag>
        );
      },
    },
    {
      title: 'Input',
      dataIndex: 'input',
      key: 'input',
      render: (text, record) => {
        switch (record.schema) {
          case 'SRT':
            return (`${record.schema}:${record?.schema_options?.mode || 'N/A'}:${record?.schema_options?.localport || 'N/A'}`);
          case 'UDP':
            return (`${record.schema}:${record?.schema_options?.address || 'N/A'}:${record?.schema_options?.port || 'N/A'}`);
          default:
            return ('Unknown');
        }
      }

    },
    {
      title: 'Last Updated',
      dataIndex: 'updated_at',
      key: 'updated_at',
      sorter: (a, b) => new Date(a.updated_at || 0) - new Date(b.updated_at || 0),
      render: (date) => new Date(date).toLocaleString(),
    },
    {
      title: 'Actions',
      key: 'actions',
      render: (_, record) => (
        <Space>
          <Button
            type="link"
            icon={record.status === 'started' ? <StopOutlined /> : <CaretRightOutlined />}
            onClick={() => handleRouteStatus(record.id, record.status === 'started' ? 'stop' : 'start')}
          >
            {record.status === 'started' ? 'Stop' : 'Start'}
          </Button>
          <Button
            type="link"
            icon={<CopyOutlined />}
            onClick={() => handleClone(record.id, record.name)}
          >
            Clone
          </Button>
          <Button
            type="link"
            icon={<EditOutlined />}
            onClick={() => navigate(`/routes/${record.id}/edit`)}
          >
            Edit
          </Button>
          <Button
            type="link"
            danger
            icon={<DeleteOutlined />}
            onClick={() => showDeleteConfirm(record)}
          >
            Delete
          </Button>
        </Space>
      ),
    },
  ];

  return (
    <div>
      {contextHolder}
      {modalContextHolder}
      <Space direction="vertical" size="large" style={{ width: '100%' }}>
        <Space style={{ width: '100%', justifyContent: 'space-between' }}>
          <Title level={3} style={{ margin: 0, fontSize: '2rem', fontWeight: 600 }}>Routes</Title>
          <Space>
            <Button
              type="primary"
              icon={<PlusOutlined />}
              onClick={() => navigate('/routes/new/edit')}
            >
              Add Route
            </Button>
          </Space>
        </Space>

        <Card>
          {/* Search and Filter Bar */}
          <Space style={{ width: '100%', marginBottom: 16, flexWrap: 'wrap' }} wrap>
            <Input
              placeholder="Search by name..."
              prefix={<SearchOutlined />}
              value={searchText}
              onChange={(e) => setSearchText(e.target.value)}
              style={{ width: 240 }}
              allowClear
            />
            <Select
              value={statusFilter}
              onChange={setStatusFilter}
              style={{ width: 140 }}
              options={[
                { label: 'All Status', value: 'all' },
                { label: 'Started', value: 'started' },
                { label: 'Stopped', value: 'stopped' },
              ]}
            />
            <Select
              value={schemaFilter}
              onChange={setSchemaFilter}
              style={{ width: 140 }}
              options={[
                { label: 'All Schema', value: 'all' },
                { label: 'SRT', value: 'SRT' },
                { label: 'UDP', value: 'UDP' },
              ]}
            />
            {availableTags.length > 0 && (
              <Select
                value={tagFilter}
                onChange={setTagFilter}
                style={{ width: 150 }}
                options={[
                  { label: 'All Tags', value: 'all' },
                  ...availableTags,
                ]}
                placeholder="Filter by tag"
              />
            )}
            {selectedRowKeys.length > 0 && (
              <>
                <Badge count={selectedRowKeys.length} style={{ backgroundColor: '#1890ff' }}>
                  <Button
                    type="primary"
                    icon={<CaretRightOutlined />}
                    loading={bulkLoading}
                    onClick={() => handleBulkAction('start')}
                  >
                    Start Selected
                  </Button>
                </Badge>
                <Button
                  icon={<StopOutlined />}
                  loading={bulkLoading}
                  onClick={() => handleBulkAction('stop')}
                >
                  Stop Selected
                </Button>
              </>
            )}
          </Space>

          <Table
            columns={columns}
            dataSource={filteredRoutes}
            rowKey="id"
            loading={loading}
            rowSelection={rowSelection}
            pagination={{
              defaultPageSize: 10,
              showSizeChanger: true,
              showTotal: (total) => `Total ${total} routes`,
            }}
          />
        </Card>
      </Space>
    </div>
  );
};

export default Routes; 