import { useEffect, useState, useCallback } from 'react';
import { Card, Table, Typography, Tag, Space, Spin, Empty, Collapse, Badge, Tooltip } from 'antd';
import {
    ArrowUpOutlined,
    UserOutlined,
    TeamOutlined,
    SyncOutlined,
    WifiOutlined
} from '@ant-design/icons';
import { routesApi } from '../utils/api';

const { Text, Title } = Typography;

/**
 * Format Mbps with proper precision
 */
const formatMbps = (mbps) => {
    if (mbps === undefined || mbps === null || mbps === 0) return '0 Mbps';
    return mbps.toFixed(2) + ' Mbps';
};

/**
 * Format bytes to human readable format
 */
const formatBytes = (bytes) => {
    if (bytes === 0 || bytes === undefined || bytes === null) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
};

const DestinationStats = ({ routeId, isRunning, destinations = [] }) => {
    const [stats, setStats] = useState([]);
    const [loading, setLoading] = useState(true);
    const [lastUpdated, setLastUpdated] = useState(null);

    const fetchStats = useCallback(async () => {
        if (!routeId || !isRunning) {
            setStats([]);
            setLoading(false);
            return;
        }

        try {
            const result = await routesApi.getDestinationStats(routeId);
            if (result.data) {
                setStats(result.data);
                setLastUpdated(new Date());
            }
        } catch (err) {
            console.error('Failed to fetch destination stats:', err);
        } finally {
            setLoading(false);
        }
    }, [routeId, isRunning]);

    useEffect(() => {
        if (!isRunning) {
            setStats([]);
            setLoading(false);
            return;
        }

        fetchStats();
        const interval = setInterval(fetchStats, 1500);
        return () => clearInterval(interval);
    }, [fetchStats, isRunning]);

    if (!isRunning) {
        return null;
    }

    // Filter to only show SRT destinations (they're the only ones with stats)
    // Type can be 'srt' or 'srtsink' depending on source
    const srtDestinations = destinations.filter(d =>
        d.type === 'srt' || d.type === 'srtsink'
    );

    if (srtDestinations.length === 0) {
        return null;
    }

    // Columns for connected callers table
    const callerColumns = [
        {
            title: 'Client Address',
            dataIndex: 'caller-address',
            key: 'address',
            render: (addr) => <Text code>{addr || 'Unknown'}</Text>
        },
        {
            title: 'Bitrate',
            dataIndex: 'send-rate-mbps',
            key: 'bitrate',
            render: (val) => formatMbps(val),
        },
        {
            title: 'RTT',
            dataIndex: 'rtt-ms',
            key: 'rtt',
            render: (val) => <span>{(val || 0).toFixed(1)} ms</span>,
        },
        {
            title: 'Packets Sent',
            dataIndex: 'packets-sent',
            key: 'packets',
            render: (val) => (val || 0).toLocaleString(),
        },
    ];

    // Create collapsible panels for each SRT destination
    const panelItems = srtDestinations.map((dest, index) => {
        const destStats = stats.find(s => s.sink_index === index)?.stats || {};
        const connectedCallers = destStats['connected-callers'] || 0;
        const callers = destStats['callers'] || [];
        const sendRate = destStats['send-rate-mbps'] || 0;
        const rtt = destStats['rtt-ms'] || 0;
        const bytesSent = destStats['bytes-sent-total'] || 0;

        const destLabel = dest.localaddress
            ? `${dest.localaddress}:${dest.localport}`
            : `Port ${dest.localport}`;

        const modeTag = dest.mode === 'listener' ? (
            <Tag color="blue">Listener</Tag>
        ) : (
            <Tag color="green">Caller</Tag>
        );

        return {
            key: `dest-${index}`,
            label: (
                <Space>
                    <WifiOutlined />
                    <span>Destination {index + 1}: <Text strong>{destLabel}</Text></span>
                    {modeTag}
                    {dest.mode === 'listener' && (
                        <Badge
                            count={connectedCallers}
                            showZero
                            style={{ backgroundColor: connectedCallers > 0 ? '#52c41a' : '#d9d9d9' }}
                        />
                    )}
                </Space>
            ),
            children: (
                <div>
                    {/* Stats Summary */}
                    <Space size="large" style={{ marginBottom: 16 }}>
                        <Tooltip title="Current send rate">
                            <Space>
                                <ArrowUpOutlined style={{ color: '#52c41a' }} />
                                <Text strong>{formatMbps(sendRate)}</Text>
                            </Space>
                        </Tooltip>
                        <Tooltip title="Round-trip time">
                            <Space>
                                <SyncOutlined />
                                <Text>{rtt.toFixed(1)} ms</Text>
                            </Space>
                        </Tooltip>
                        <Tooltip title="Total bytes sent">
                            <Space>
                                <ArrowUpOutlined />
                                <Text>{formatBytes(bytesSent)}</Text>
                            </Space>
                        </Tooltip>
                        {dest.mode === 'listener' && (
                            <Tooltip title="Connected clients">
                                <Space>
                                    <TeamOutlined />
                                    <Text>{connectedCallers} client{connectedCallers !== 1 ? 's' : ''}</Text>
                                </Space>
                            </Tooltip>
                        )}
                    </Space>

                    {/* Connected Callers Table (for listener mode) */}
                    {dest.mode === 'listener' && callers.length > 0 && (
                        <Card size="small" title="Connected Clients" style={{ marginTop: 8 }}>
                            <Table
                                columns={callerColumns}
                                dataSource={callers.map((c, i) => ({ ...c, key: i }))}
                                size="small"
                                pagination={false}
                            />
                        </Card>
                    )}

                    {dest.mode === 'listener' && callers.length === 0 && (
                        <Empty
                            image={Empty.PRESENTED_IMAGE_SIMPLE}
                            description="No clients connected"
                            style={{ margin: '16px 0' }}
                        />
                    )}
                </div>
            ),
        };
    });

    return (
        <Card
            title={
                <Space>
                    <ArrowUpOutlined />
                    <span>Destination Statistics</span>
                    {loading && <Spin size="small" />}
                </Space>
            }
            size="small"
            style={{ marginTop: 16 }}
            extra={
                lastUpdated && (
                    <Text type="secondary" style={{ fontSize: 12 }}>
                        Updated: {lastUpdated.toLocaleTimeString()}
                    </Text>
                )
            }
        >
            {stats.length === 0 && !loading ? (
                <Empty description="No destination stats available" />
            ) : (
                <Collapse
                    items={panelItems}
                    defaultActiveKey={['dest-0']}
                    bordered={false}
                />
            )}
        </Card>
    );
};

export default DestinationStats;
