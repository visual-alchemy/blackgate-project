import { Form, Input, Radio, Card, Space, InputNumber, Switch, Select, Button, Row, Col, message, Typography, Tabs } from 'antd';
import { InfoCircleOutlined, QuestionCircleOutlined, SaveOutlined, CloseOutlined, HomeOutlined, LoadingOutlined } from '@ant-design/icons';
import PropTypes from 'prop-types';
import { useNavigate, useParams } from 'react-router-dom';
import { useEffect, useState, useRef } from 'react';
import { routesApi, networkApi } from '../../utils/api';
import React from 'react';
import SourceFields from './SourceFields';

const { Title } = Typography;

const RouteSourceEdit = ({ initialValues, onChange }) => {
  const [form] = Form.useForm();
  const navigate = useNavigate();
  const { id } = useParams();
  const [messageApi, contextHolder] = message.useMessage();
  const [loading, setLoading] = useState(id !== 'new');
  const dataFetchedRef = useRef(false);
  const [routeData, setRouteData] = useState(null);
  const [interfaces, setInterfaces] = useState([]);

  // Set breadcrumb items for the RouteSourceEdit page
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
        ...(id !== 'new' ? [
          {
            href: `/routes/${id}`,
            title: loading ? <><LoadingOutlined style={{ marginRight: 8 }} />Loading...</> : (routeData ? routeData.name : 'Route Details'),
          }
        ] : []),
        {
          title: id === 'new' ? 'New Route' : 'Edit Route',
        }
      ]);
    }
  }, [id, routeData, loading]);

  // Fetch existing route data when component mounts
  useEffect(() => {
    if (id !== 'new' && !dataFetchedRef.current) {
      dataFetchedRef.current = true;

      routesApi.getById(id)
        .then(result => {
          setRouteData(result.data);
          form.setFieldsValue(result.data);
          setLoading(false);
        })
        .catch(error => {
          messageApi.error(`Failed to fetch route data: ${error.message}`);
          console.error('Error:', error);
          setLoading(false);
        });
    }
  }, [id, form, messageApi]);

  // Fetch network interfaces for UDP bind options
  useEffect(() => {
    networkApi.getInterfaces()
      .then(result => {
        setInterfaces(result.interfaces || []);
      })
      .catch(error => {
        console.error('Error fetching network interfaces:', error);
      });
  }, []);

  const availableNodes = [
    { label: 'self', value: 'self' }
  ];

  const handleValuesChange = (changedValues, allValues) => {
    if (changedValues.seamless_sdi_failover === true && allValues.auto_join !== true) {
      form.setFieldValue('auto_join', true);
    }

    // Disabling failover must also clear the seamless SDI flag. The field is
    // hidden (unmounted) but antd preserves its value, so it still ships in the
    // payload and the backend rejects it ("seamless SDI failover requires
    // failover to be enabled").
    if (changedValues.failover_enabled === false) {
      form.setFieldValue('seamless_sdi_failover', false);
    }

    // Auto-fill Local Address when mode is set to listener or rendezvous
    if (changedValues?.schema_options?.mode) {
      const mode = changedValues.schema_options.mode;
      if (mode === 'listener' || mode === 'rendezvous') {
        // Set to 0.0.0.0 to bind to all interfaces (common for listeners)
        form.setFieldsValue({
          schema_options: {
            ...allValues.schema_options,
            localaddress: '0.0.0.0'
          }
        });
      } else if (mode === 'caller') {
        // Clear the address for caller mode (user needs to enter remote address)
        form.setFieldsValue({
          schema_options: {
            ...allValues.schema_options,
            localaddress: ''
          }
        });
      }
    }

    if (onChange) {
      onChange(allValues);
    }
  };

  const handleSave = (exitAfterSave = false) => {
    form.validateFields()
      .then(values => {
        const loadingMessage = messageApi.loading('Saving route...', 0);

        // Determine if we're creating or updating
        const savePromise = id === 'new'
          ? routesApi.create(values)
          : routesApi.update(id, values);

        savePromise
          .then(data => {
            loadingMessage();
            if (id !== 'new' && data?.data?.restarted) {
              messageApi.success('Route saved and restarted successfully');
            } else {
              messageApi.success('Route saved successfully');
            }
            if (data) {
              form.setFieldsValue(data.data);
              if (id === 'new' && data.data.id) {
                if (exitAfterSave) {
                  navigate('/routes');
                } else {
                  navigate(`/routes/${data.data.id}`);
                }
              } else if (exitAfterSave) {
                navigate('/routes');
              }
            }
          })
          .catch(error => {
            loadingMessage();
            messageApi.error(`Failed to save route: ${error.message}`);
            console.error('Error:', error);
          });
      })
      .catch(info => {
        messageApi.error('Please check the form for errors');
        console.log('Validate Failed:', info);
      });
  };

  const handleCancel = () => {
    navigate(id === 'new' ? '/routes' : `/routes/${id}`);
  };

  return (
    <div>
      {contextHolder}

      <Title
        level={3}
        style={{
          margin: '0 0 24px 0',
          fontSize: '1.75rem',
          fontWeight: 600
        }}
      >
        {id === 'new' ? 'Add Source' : 'Edit Source'}
      </Title>

      {id === 'new' && (
        <Card
          style={{ marginBottom: '24px', backgroundColor: '#141414', border: '1px solid #303030' }}
          size="small"
        >
          <Space align="start">
            <InfoCircleOutlined style={{ color: '#1890ff', fontSize: '16px', marginTop: '3px' }} />
            <Typography.Text type="secondary">
              Destination creation will be available after saving this source. Please save the source first to continue setting up your route.
            </Typography.Text>
          </Space>
        </Card>
      )}

      <Form
        form={form}
        layout="vertical"
        initialValues={{
          enabled: true,
          node: 'self',
          exportStats: true,
          schema: 'SRT',
          schema_options: {
            'auto-reconnect': true,
            'keep-listening': false
          },
          failover_enabled: false,
          failover_mode: 'maintain-primary',
          auto_join: true,
          seamless_sdi_failover: false,
          active_source: 'primary',
          secondary_source: { schema: 'SRT', schema_options: {} },
          ...initialValues
        }}
        onValuesChange={handleValuesChange}
      >
        <Space direction="vertical" size="large" style={{ width: '100%' }}>
          <Row gutter={24}>
            <Col style={{ width: '100%', maxWidth: '1200px' }}>
              <Space direction="vertical" size="large" style={{ width: '100%' }}>
                {/* General Settings */}
                <Card title="General Options" size="small" loading={loading}>
                  <Form.Item
                    label="Name"
                    name="name"
                    required
                    tooltip="A unique name for this route"
                  >
                    <Input placeholder="Enter route name" />
                  </Form.Item>

                  <Form.Item
                    label="Enabled"
                    name="enabled"
                    valuePropName="checked"
                    extra="Auto start after server reboot"
                  >
                    <Switch />
                  </Form.Item>

                  <Form.Item
                    label="Export stats"
                    name="exportStats"
                    valuePropName="checked"
                    extra="Export stats to VictoriaMetrics/InfluxDB/Prometheus"
                  >
                    <Switch />
                  </Form.Item>

                  <Form.Item
                    label="GST_DEBUG"
                    name="gstDebug"
                    tooltip="Set GStreamer debug level (e.g., GST_AUTOPLUG:6,GST_ELEMENT_*:4)"
                    extra="Configure GStreamer debug levels for detailed pipeline logging"
                    style={{ maxWidth: '450px' }}
                  >
                    <Input placeholder="Enter GStreamer debug configuration" />
                  </Form.Item>

                  <Form.Item
                    label="Node"
                    name="node"
                    required
                    tooltip="Node where route will launch"
                  >
                    <Select
                      placeholder="Select a node"
                      options={availableNodes}
                      disabled={true}
                      style={{ width: '100%' }}
                    />
                  </Form.Item>

                  {/* Failover — SRT only */}
                  <Form.Item noStyle dependencies={['schema']}>
                    {({ getFieldValue }) =>
                      getFieldValue('schema') === 'SRT' && (
                        <>
                          <Form.Item
                            label="Failover"
                            name="failover_enabled"
                            valuePropName="checked"
                            extra="Automatically switch to secondary SRT source when primary fails"
                          >
                            <Switch />
                          </Form.Item>

                          <Form.Item noStyle dependencies={['failover_enabled']}>
                            {({ getFieldValue: getFF }) =>
                              getFF('failover_enabled') && (
                                <>
                                  <Form.Item
                                    label="Auto-Join"
                                    name="auto_join"
                                    valuePropName="checked"
                                    tooltip="True: both primary and secondary always connected (zero reconnect delay, more bandwidth). False: secondary connects only when it becomes active."
                                  >
                                    <Switch defaultChecked />
                                  </Form.Item>

                                  <Form.Item
                                    label="Seamless SDI Failover"
                                    name="seamless_sdi_failover"
                                    valuePropName="checked"
                                    tooltip="Keep both SRT sources warm, validate their MPEG-TS stream maps, and switch on a target keyframe. Incompatible feeds automatically use restart failover."
                                    extra="Experimental. Requires matching encoder codec, PID, program, audio, and timing configuration. Enabling this also enables Auto-Join."
                                  >
                                    <Switch />
                                  </Form.Item>

                                  <Form.Item
                                    label="Failover Mode"
                                    name="failover_mode"
                                    tooltip={{
                                      title: (
                                        <div style={{ whiteSpace: 'pre-line', padding: '4px' }}>
                                          <strong>• Automatic - Maintain Primary:</strong><br />
                                          Automatic switch from primary to secondary source when the primary source is invalid (and secondary is valid when auto-join enabled).<br />
                                          Automatic switch back when the primary source becomes back valid.<br /><br />
                                          <strong>• Automatic - Maintain Stability:</strong><br />
                                          Automatic switch from primary to secondary source when primary source is invalid (and secondary is valid when auto-join enabled).<br />
                                          Automatic switch back when the secondary source is invalid (and primary is valid when auto-join enabled).<br /><br />
                                          <strong>• Manual Switchback:</strong><br />
                                          Automatic switch from primary to secondary source when the primary source is invalid (and secondary is valid when auto-join enabled).<br />
                                          Manual switch back on user action.<br /><br />
                                          <strong>• Manual Failover:</strong><br />
                                          Manually force the switch from primary to secondary source and vice versa.
                                        </div>
                                      ),
                                      icon: <QuestionCircleOutlined />
                                    }}
                                    rules={[{ required: true, message: 'Please select a failover mode' }]}
                                  >
                                    <Select
                                      options={[
                                        { label: 'Automatic - Maintain Primary', value: 'maintain-primary' },
                                        { label: 'Automatic - Maintain Stability', value: 'maintain-stability' },
                                        { label: 'Manual Switchback', value: 'manual-switchback' },
                                        { label: 'Manual Failover', value: 'manual' },
                                      ]}
                                      style={{ width: '280px' }}
                                    />
                                  </Form.Item>
                                </>
                              )
                            }
                          </Form.Item>
                        </>
                      )
                    }
                  </Form.Item>
                </Card>

                <Card title="Source Options" size="small" loading={loading}>
                  <Form.Item noStyle dependencies={['schema', 'failover_enabled']}>
                    {({ getFieldValue }) => {
                      const currentSchema = getFieldValue('schema');
                      const failoverEnabled = getFieldValue('failover_enabled');

                      if (currentSchema === 'SRT') {
                        const tabItems = [
                          {
                            key: 'primary',
                            label: 'Primary Source',
                            children: <SourceFields prefix={['schema_options']} schemaName="schema" interfaces={interfaces} />
                          },
                        ];
                        if (failoverEnabled) {
                          tabItems.push({
                            key: 'secondary',
                            label: 'Secondary Source',
                            children: <SourceFields prefix={['secondary_source', 'schema_options']} schemaName={['secondary_source', 'schema']} interfaces={interfaces} hideSchema />
                          });
                        }
                        return <Tabs items={tabItems} />;
                      }

                      return <SourceFields prefix={['schema_options']} schemaName="schema" interfaces={interfaces} />;
                    }}
                  </Form.Item>
                </Card>


              </Space>

              {id === 'new' && (
                <Card
                  style={{ marginTop: '24px', backgroundColor: '#141414', border: '1px solid #303030' }}
                  size="small"
                >
                  <Space align="start">
                    <InfoCircleOutlined style={{ color: '#1890ff', fontSize: '16px', marginTop: '3px' }} />
                    <Typography.Text type="secondary">
                      Destination creation will be available after saving this source. Please save the source first to continue setting up your route.
                    </Typography.Text>
                  </Space>
                </Card>
              )}

              <Row justify="end" style={{ marginTop: '24px' }}>
                <Space>
                  <Button
                    icon={<CloseOutlined />}
                    onClick={handleCancel}
                  >
                    Cancel
                  </Button>
                  <Button
                    type="primary"
                    ghost
                    icon={<SaveOutlined />}
                    onClick={() => handleSave(false)}
                  >
                    Save and Continue
                  </Button>
                  <Button
                    type="primary"
                    icon={<SaveOutlined />}
                    onClick={() => handleSave(true)}
                  >
                    Save and Exit
                  </Button>
                </Space>
              </Row>
            </Col>
          </Row>
        </Space>
      </Form>
    </div>
  );
};

RouteSourceEdit.propTypes = {
  initialValues: PropTypes.object,
  onChange: PropTypes.func,
};

export default RouteSourceEdit;
