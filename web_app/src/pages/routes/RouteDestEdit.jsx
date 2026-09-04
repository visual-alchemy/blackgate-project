import {
    Form, Input, Radio,
    Card, Space,
    InputNumber,
    Switch, Select, Button,
    Row, Col, message, Typography
} from 'antd';
import { InfoCircleOutlined, SaveOutlined, CloseOutlined, HomeOutlined, LoadingOutlined } from '@ant-design/icons';
import PropTypes from 'prop-types';
import { useNavigate, useParams } from 'react-router-dom';
import { useEffect, useState, useRef } from 'react';
import { destinationsApi, routesApi, networkApi } from '../../utils/api';
import React from 'react';

const { Title } = Typography;

const RouteDestEdit = ({ initialValues, onChange }) => {
    const [form] = Form.useForm();
    const navigate = useNavigate();
    const { routeId, destId } = useParams();
    const [messageApi, contextHolder] = message.useMessage();
    const [loading, setLoading] = useState(destId !== 'new');
    const dataFetchedRef = useRef(false);
    const [routeData, setRouteData] = useState(null);
    const [destData, setDestData] = useState(null);
    const [routeLoading, setRouteLoading] = useState(true);
    const [interfaces, setInterfaces] = useState([]);
    const [sdiPortUsage, setSdiPortUsage] = useState({});

    // Set breadcrumb items for the RouteDestEdit page
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
                    href: `/routes/${routeId}`,
                    title: routeLoading ? <><LoadingOutlined style={{ marginRight: 8 }} />Loading...</> : (routeData ? routeData.name : 'Route Details'),
                },
                {
                    // Don't make the current page a link
                    title: destId === 'new' ? 'New Destination' : (loading ? <><LoadingOutlined style={{ marginRight: 8 }} />Loading...</> : (destData ? `Edit ${destData.name}` : 'Edit Destination')),
                }
            ]);
        }
    }, [routeId, destId, routeData, destData, loading, routeLoading]);

    // Fetch route data for breadcrumb
    useEffect(() => {
        if (routeId && routeId !== 'new') {
            setRouteLoading(true);
            routesApi.getById(routeId)
                .then(result => {
                    setRouteData(result.data);
                })
                .catch(error => {
                    console.error('Error fetching route data:', error);
                })
                .finally(() => {
                    setRouteLoading(false);
                });
        }
    }, [routeId]);

    // Fetch existing destination data when component mounts
    useEffect(() => {
        if (destId !== 'new' && !dataFetchedRef.current) {
            dataFetchedRef.current = true;

            destinationsApi.getById(routeId, destId)
                .then(result => {
                    setDestData(result.data);
                    form.setFieldsValue(result.data);
                    setLoading(false);
                })
                .catch(error => {
                    messageApi.error(`Failed to fetch destination data: ${error.message}`);
                    console.error('Error:', error);
                    setLoading(false);
                });
        }
    }, [routeId, destId, form, messageApi]);

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

    // Fetch SDI port usage across all routes
    useEffect(() => {
        routesApi.getAll()
            .then(result => {
                const usage = {};
                (result.data || []).forEach(route => {
                    (route.destinations || []).forEach(dest => {
                        if (dest.schema === 'SDI' && dest.schema_options?.device_number !== undefined) {
                            // Skip if this is the current destination being edited
                            if (dest.id === destId) return;
                            usage[dest.schema_options.device_number] = route.name;
                        }
                    });
                });
                setSdiPortUsage(usage);
            })
            .catch(error => {
                console.error('Error fetching SDI port usage:', error);
            });
    }, [destId]);

    const availableNodes = [
        { label: 'self', value: 'self' }
    ];

    const handleValuesChange = (changedValues, allValues) => {
        if (onChange) {
            onChange(allValues);
        }
    };

    const handleSave = (exitAfterSave = false) => {
        form.validateFields()
            .then(values => {
                const loadingMessage = messageApi.loading('Saving destination...', 0);

                // Determine if we're creating or updating
                const savePromise = destId === 'new'
                    ? destinationsApi.create(routeId, values)
                    : destinationsApi.update(routeId, destId, values);

                savePromise
                    .then(data => {
                        loadingMessage();
                        if (destId !== 'new' && data?.data?.restarted) {
                            messageApi.success('Destination saved — route restarted');
                        } else if (destId === 'new' && data?.data?.restarted) {
                            messageApi.success('Destination created — route restarted');
                        } else {
                            messageApi.success('Destination saved successfully');
                        }
                        if (data) {
                            form.setFieldsValue(data.data);
                            if (destId === 'new' && data.data.id) {
                                if (exitAfterSave) {
                                    navigate('/routes');
                                } else {
                                    navigate(`/routes/${routeId}`);
                                }
                            } else if (exitAfterSave) {
                                navigate('/routes');
                            }
                        }
                    })
                    .catch(error => {
                        loadingMessage();
                        messageApi.error(`Failed to save destination: ${error.message}`);
                        console.error('Error:', error);
                    });
            })
            .catch(info => {
                messageApi.error('Please check the form for errors');
                console.log('Validate Failed:', info);
            });
    };

    const handleCancel = () => {
        navigate(`/routes/${routeId}`);
    };

    return (
        <div>
            {contextHolder}
            {/* Page Title */}
            <Title
                level={3}
                style={{
                    margin: '0 0 24px 0',
                    fontSize: '1.75rem',
                    fontWeight: 600
                }}
            >
                {destId === 'new' ? 'Add Destination' : 'Edit Destination'}
            </Title>

            <Form
                form={form}
                layout="vertical"
                initialValues={{
                    enabled: true,
                    node: 'self',
                    schema: 'SRT',
                    autoReconnect: true,
                    srtMode: 'caller',
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
                                        extra="A unique name for this destination"
                                    >
                                        <Input placeholder="Enter destination name" />
                                    </Form.Item>
                                </Card>

                                {/* Destination Configuration */}
                                <Card title="Destination Options" size="small" loading={loading}>
                                    <Form.Item
                                        label="Schema"
                                        name="schema"
                                        required
                                    >
                                        <Radio.Group buttonStyle="solid">
                                            <Radio.Button value="SRT">SRT</Radio.Button>
                                            <Radio.Button value="UDP">UDP</Radio.Button>
                                            <Radio.Button value="SDI">SDI</Radio.Button>
                                        </Radio.Group>
                                    </Form.Item>

                                    {/* SRT Specific Options */}
                                    <Form.Item noStyle dependencies={['schema']}>
                                        {({ getFieldValue }) =>
                                            getFieldValue('schema') === 'SRT' && (
                                                <>
                                                    <Form.Item
                                                        label="Local Address"
                                                        name={['schema_options', 'localaddress']}
                                                        extra="Local address to bind."
                                                    >
                                                        <Input placeholder="Enter local address" />
                                                    </Form.Item>

                                                    <Form.Item
                                                        label="Local Port"
                                                        name={['schema_options', 'localport']}
                                                        required
                                                        extra="Local port to bind."
                                                        rules={[
                                                            {
                                                                type: 'number',
                                                                min: 1,
                                                                max: 65535,
                                                                message: 'Port must be between 1 and 65535',
                                                            },
                                                        ]}
                                                    >
                                                        <InputNumber
                                                            style={{ width: '150px' }}
                                                            placeholder="Enter port number"
                                                        />
                                                    </Form.Item>

                                                    <Form.Item
                                                        label="Mode"
                                                        name={['schema_options', 'mode']}
                                                        required
                                                        extra="Caller: Actively initiates the connection. Listener: Waits for incoming connections. Rendezvous: Both endpoints connect to each other simultaneously."
                                                    >
                                                        <Radio.Group buttonStyle="solid">
                                                            <Radio.Button value="caller">Caller</Radio.Button>
                                                            <Radio.Button value="listener">Listener</Radio.Button>
                                                            <Radio.Button value="rendezvous">Rendezvous</Radio.Button>
                                                        </Radio.Group>
                                                    </Form.Item>

                                                    <Form.Item noStyle dependencies={[['schema_options', 'mode']]}>
                                                        {({ getFieldValue }) => {
                                                            const srtMode = getFieldValue(['schema_options', 'mode']);
                                                            if (srtMode !== 'caller' && srtMode !== 'rendezvous') return null;
                                                            return (
                                                                <Form.Item
                                                                    label="Bind Interface"
                                                                    name={['schema_options', 'bind-address']}
                                                                    extra="Bind the SRT socket to a specific network interface (source IP). Useful for dual-NIC / multi-ISP routing. Leave default to let the OS choose."
                                                                >
                                                                    <Select
                                                                        allowClear
                                                                        placeholder="Default (any interface)"
                                                                        options={[
                                                                            { label: 'Default (any interface)', value: '' },
                                                                            ...interfaces
                                                                                .filter(iface => iface.up && iface.address)
                                                                                .map(iface => ({
                                                                                    label: `${iface.name} (${iface.address})`,
                                                                                    value: iface.address
                                                                                }))
                                                                        ]}
                                                                    />
                                                                </Form.Item>
                                                            );
                                                        }}
                                                    </Form.Item>

                                                    <Form.Item
                                                        label="Latency"
                                                        name={['schema_options', 'latency']}
                                                        extra="The maximum accepted transmission latency in milliseconds"
                                                    >
                                                        <InputNumber
                                                            style={{ width: '150px' }}
                                                            min={20}
                                                            max={8000}
                                                            placeholder="Default: 125ms"
                                                        />
                                                    </Form.Item>

                                                    <Form.Item
                                                        label="Stream ID"
                                                        name={['schema_options', 'streamid']}
                                                        extra="Optional SRT Stream ID. Required by some services (e.g., SRS/Vidio) for stream identification."
                                                    >
                                                        <Input placeholder="e.g., publish:live/1000000001:client_id:abc123" />
                                                    </Form.Item>

                                                    <Form.Item
                                                        label="Authentication"
                                                        name={['schema_options', 'authentication']}
                                                        valuePropName="checked"
                                                        extra="Enable SRT authentication"
                                                    >
                                                        <Switch />
                                                    </Form.Item>

                                                    <Form.Item noStyle dependencies={[['schema_options', 'authentication']]}>
                                                        {({ getFieldValue }) =>
                                                            getFieldValue(['schema_options', 'authentication']) && (
                                                                <>
                                                                    <Form.Item
                                                                        label="Passphrase"
                                                                        name={['schema_options', 'passphrase']}
                                                                        required
                                                                        extra="Encryption passphrase for SRT authentication"
                                                                    >
                                                                        <Input.Password placeholder="Enter passphrase" />
                                                                    </Form.Item>

                                                                    <Form.Item
                                                                        label="Key Length"
                                                                        name={['schema_options', 'pbkeylen']}
                                                                        required
                                                                        extra="Encryption key length for SRT authentication"
                                                                    >
                                                                        <Select
                                                                            placeholder="Select key length"
                                                                            options={[
                                                                                { label: '0 (Default)', value: 0 },
                                                                                { label: '16', value: 16 },
                                                                                { label: '24', value: 24 },
                                                                                { label: '32', value: 32 },
                                                                            ]}
                                                                            style={{ width: '150px' }}
                                                                        />
                                                                    </Form.Item>
                                                                </>
                                                            )
                                                        }
                                                    </Form.Item>

                                                    {/* Advanced SRT Settings for Destination */}
                                                    <Card
                                                        title="Advanced SRT Settings"
                                                        size="small"
                                                        style={{ marginTop: '16px', backgroundColor: '#1a1a1a' }}
                                                        extra={<Typography.Text type="secondary" style={{ fontSize: '12px' }}>For output tuning</Typography.Text>}
                                                    >
                                                        <Typography.Paragraph type="secondary" style={{ marginBottom: '16px', fontSize: '13px' }}>
                                                            These settings help optimize output stream delivery. Only adjust if experiencing issues.
                                                        </Typography.Paragraph>

                                                        <Form.Item
                                                            label="Send Buffer (sndbuf)"
                                                            name={['schema_options', 'sndbuf']}
                                                            tooltip="Size of the send buffer in bytes"
                                                            extra="Larger buffer helps with high bitrate streams. Default: ~8MB (calculated by SRT)"
                                                        >
                                                            <InputNumber
                                                                style={{ width: '200px' }}
                                                                min={0}
                                                                step={1000000}
                                                                placeholder="e.g., 50000000 (50MB)"
                                                                formatter={(value) => value ? `${value} bytes` : ''}
                                                                parser={(value) => value.replace(' bytes', '')}
                                                            />
                                                        </Form.Item>

                                                        <Form.Item
                                                            label="Receive Buffer (rcvbuf)"
                                                            name={['schema_options', 'rcvbuf']}
                                                            tooltip="Size of the receive buffer in bytes"
                                                            extra="Larger buffer helps with high bitrate streams and network jitter. Default: ~8MB (calculated by SRT)"
                                                        >
                                                            <InputNumber
                                                                style={{ width: '200px' }}
                                                                min={0}
                                                                step={1000000}
                                                                placeholder="e.g., 50000000 (50MB)"
                                                                formatter={(value) => value ? `${value} bytes` : ''}
                                                                parser={(value) => value.replace(' bytes', '')}
                                                            />
                                                        </Form.Item>

                                                        <Form.Item
                                                            label="Overhead Bandwidth % (oheadbw)"
                                                            name={['schema_options', 'oheadbw']}
                                                            tooltip="Extra bandwidth for retransmissions"
                                                            extra="Percentage of extra bandwidth for packet recovery. Default: 25%"
                                                        >
                                                            <InputNumber
                                                                style={{ width: '150px' }}
                                                                min={5}
                                                                max={100}
                                                                placeholder="e.g., 50"
                                                                formatter={(value) => value ? `${value}%` : ''}
                                                                parser={(value) => value.replace('%', '')}
                                                            />
                                                        </Form.Item>

                                                        <Form.Item
                                                            label="Max Bandwidth (maxbw)"
                                                            name={['schema_options', 'maxbw']}
                                                            tooltip="Maximum bandwidth in bytes per second"
                                                            extra="Limit maximum sending rate. 0 = unlimited. Default: 0"
                                                        >
                                                            <InputNumber
                                                                style={{ width: '200px' }}
                                                                min={0}
                                                                step={1000000}
                                                                placeholder="e.g., 50000000 (50MB/s)"
                                                            />
                                                        </Form.Item>
                                                    </Card>
                                                </>
                                            )
                                        }
                                    </Form.Item>

                                    {/* UDP specific options */}
                                    <Form.Item noStyle dependencies={['schema']}>
                                        {({ getFieldValue }) =>
                                            getFieldValue('schema') === 'UDP' && (
                                                <>
                                                    <Form.Item
                                                        label="Address"
                                                        required
                                                        name={['schema_options', 'host']}
                                                        extra="The host/IP/Multicast group to send the packets to"
                                                    >
                                                        <Input placeholder="Enter address" />
                                                    </Form.Item>

                                                    <Form.Item
                                                        label="Port"
                                                        name={['schema_options', 'port']}
                                                        required
                                                        extra="The port to send the packets to"
                                                        rules={[
                                                            {
                                                                type: 'number',
                                                                min: 1,
                                                                max: 65535,
                                                                message: 'Port must be between 1 and 65535',
                                                            },
                                                        ]}
                                                    >
                                                        <InputNumber
                                                            style={{ width: '150px' }}
                                                            placeholder="Enter port number"
                                                        />
                                                    </Form.Item>

                                                    <Form.Item
                                                        label="Bind Interface"
                                                        name={['schema_options', 'bind-address']}
                                                        extra="Select network interface to bind outgoing UDP traffic (optional)"
                                                    >
                                                        <Select
                                                            allowClear
                                                            placeholder="Default (any interface)"
                                                            options={[
                                                                { label: 'Default (any interface)', value: '' },
                                                                ...interfaces
                                                                    .filter(iface => iface.up && iface.address)
                                                                    .map(iface => ({
                                                                        label: `${iface.name} (${iface.address})`,
                                                                        value: iface.address
                                                                    }))
                                                            ]}
                                                        />
                                                    </Form.Item>

                                                    <Form.Item
                                                        label="Multicast Interface"
                                                        name={['schema_options', 'multicast-iface']}
                                                        extra="Network interface name for multicast traffic (e.g., eth1)"
                                                    >
                                                        <Select
                                                            allowClear
                                                            placeholder="Default"
                                                            options={[
                                                                { label: 'Default', value: '' },
                                                                ...interfaces
                                                                    .filter(iface => iface.up)
                                                                    .map(iface => ({
                                                                        label: iface.name,
                                                                        value: iface.name
                                                                    }))
                                                            ]}
                                                        />
                                                    </Form.Item>
                                                </>
                                            )
                                        }
                                    </Form.Item>

                                    {/* SDI specific options (DeckLink Duo 2) */}
                                    <Form.Item noStyle dependencies={['schema']}>
                                        {({ getFieldValue }) =>
                                            getFieldValue('schema') === 'SDI' && (
                                                <>
                                                    <Form.Item
                                                        label="SDI Output Port"
                                                        name={['schema_options', 'device_number']}
                                                        required
                                                        extra="DeckLink Duo 2 port number. This card provides 4 SDI channels (0-3)."
                                                    >
                                                        <Select
                                                            placeholder="Select SDI port"
                                                            options={[
                                                                { label: 'SDI 1', value: 0 },
                                                                { label: 'SDI 2', value: 2 },
                                                                { label: 'SDI 3', value: 1 },
                                                                { label: 'SDI 4', value: 3 },
                                                            ].map(opt => ({
                                                                ...opt,
                                                                label: sdiPortUsage[opt.value]
                                                                    ? `${opt.label} (used by ${sdiPortUsage[opt.value]})`
                                                                    : opt.label,
                                                                disabled: !!sdiPortUsage[opt.value],
                                                            }))}
                                                            style={{ width: '280px' }}
                                                        />
                                                    </Form.Item>

                                                    <Form.Item
                                                        label="Video Mode"
                                                        name={['schema_options', 'video_mode']}
                                                        required
                                                        extra="Output video format. Must match source resolution and frame rate."
                                                    >
                                                        <Select
                                                            placeholder="Select video mode"
                                                            options={[
                                                                { label: 'Auto (detect from source)', value: 0 },
                                                                { label: '1080p 25fps (PAL)', value: 9 },
                                                                { label: '1080p 30fps (NTSC)', value: 11 },
                                                                { label: '1080p 50fps', value: 12 },
                                                                { label: '1080p 60fps', value: 13 },
                                                                { label: '1080i 50fps (PAL)', value: 7 },
                                                                { label: '1080i 60fps (NTSC)', value: 8 },
                                                                { label: '720p 50fps', value: 14 },
                                                                { label: '720p 60fps', value: 15 },
                                                                { label: '576i 50fps (PAL SD)', value: 17 },
                                                                { label: '480i 60fps (NTSC SD)', value: 18 },
                                                                { label: '2160p 25fps (4K)', value: 22 },
                                                                { label: '2160p 30fps (4K)', value: 23 },
                                                                { label: '2160p 50fps (4K)', value: 24 },
                                                                { label: '2160p 60fps (4K)', value: 25 },
                                                            ]}
                                                            style={{ width: '250px' }}
                                                        />
                                                    </Form.Item>
                                                </>
                                            )
                                        }
                                    </Form.Item>
                                </Card>
                            </Space>

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

RouteDestEdit.propTypes = {
    initialValues: PropTypes.object,
    onChange: PropTypes.func,
};

export default RouteDestEdit; 