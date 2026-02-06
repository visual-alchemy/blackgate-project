import { useEffect, useState, useCallback } from 'react';
import { Card, Statistic, Row, Col, Table, Typography, Tag, Spin, Empty } from 'antd';
import {
    ArrowUpOutlined,
    ArrowDownOutlined,
    WifiOutlined,
    ClockCircleOutlined,
    SyncOutlined,
    VideoCameraOutlined,
    FieldTimeOutlined
} from '@ant-design/icons'
import { routesApi } from '../utils/api';

const { Text } = Typography;

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

/**
 * Format Mbps with proper precision
 */
const formatMbps = (mbps) => {
    if (mbps === undefined || mbps === null || mbps === 0) return '0 Mbps';
    return mbps.toFixed(2) + ' Mbps';
};

/**
 * Calculate packet loss percentage
 */
const calculatePacketLoss = (received, lost) => {
    if (!received || received === 0) return '0';
    return ((lost / (received + lost)) * 100).toFixed(2);
};

/**
 * Format resolution (width x height)
 */
const formatResolution = (width, height) => {
    if (!width || !height) return 'N/A';
    return `${width}×${height}`;
};

/**
 * Format framerate (fps_num / fps_den)
 * Shows ~ prefix when framerate is inferred (not detected from stream)
 */
const formatFramerate = (num, den, isInferred = false) => {
    if (!num || !den || den === 0) return 'N/A';
    const fps = num / den;
    const prefix = isInferred ? '~' : '';
    // Round to 2 decimal places, but show as integer if it's a whole number
    if (Number.isInteger(fps)) return `${prefix}${fps} fps`;
    return `${prefix}${fps.toFixed(2)} fps`;
};

/**
 * Format scan type (P for progressive, I for interlaced)
 */
const formatScanType = (interlaceMode) => {
    if (!interlaceMode || interlaceMode === 'progressive') {
        return { label: 'P', full: 'Progressive', color: 'green' };
    } else if (interlaceMode === 'interleaved' || interlaceMode === 'mixed') {
        return { label: 'I', full: 'Interlaced', color: 'orange' };
    }
    return { label: '?', full: interlaceMode, color: 'default' };
};

const RouteStats = ({ routeId, isRunning }) => {
    const [stats, setStats] = useState(null);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState(null);
    const [lastUpdated, setLastUpdated] = useState(null);

    const fetchStats = useCallback(async () => {
        if (!routeId || !isRunning) {
            setStats(null);
            setLoading(false);
            return;
        }

        try {
            const result = await routesApi.getStats(routeId);
            if (result.data) {
                setStats(result.data);
                setLastUpdated(new Date());
                setError(null);
            } else {
                setStats(null);
            }
        } catch (err) {
            console.error('Failed to fetch stats:', err);
            setError(err.message);
        } finally {
            setLoading(false);
        }
    }, [routeId, isRunning]);

    // Initial fetch and polling
    useEffect(() => {
        if (!isRunning) {
            setStats(null);
            setLoading(false);
            return;
        }

        fetchStats();
        const interval = setInterval(fetchStats, 1500); // Poll every 1.5 seconds

        return () => clearInterval(interval);
    }, [fetchStats, isRunning]);

    if (!isRunning) {
        return null;
    }

    // Get stats - use top-level stats (works for both caller and listener modes)
    // Fall back to first caller if top-level stats are not available
    const caller = stats?.callers?.[0] || {};
    const connectedCallers = stats?.['connected-callers'] || 0;
    const totalBytes = stats?.['total-bytes-received'] || 0;

    // Use top-level stats first (available in caller mode), fallback to caller array (listener mode)
    const bitrate = stats?.['receive-rate-mbps'] ?? caller['receive-rate-mbps'] ?? 0;
    const rtt = stats?.['rtt-ms'] ?? caller['rtt-ms'] ?? 0;
    const packetsReceived = stats?.['packets-received'] ?? caller['packets-received'] ?? 0;
    const packetsLost = stats?.['packets-received-lost'] ?? caller['packets-received-lost'] ?? 0;
    const packetsDropped = stats?.['packets-received-dropped'] ?? caller['packets-received-dropped'] ?? 0;
    const bandwidth = stats?.['bandwidth-mbps'] ?? caller['bandwidth-mbps'] ?? 0;
    const packetLoss = calculatePacketLoss(packetsReceived, packetsLost);

    // Video metadata from caps
    const videoWidth = stats?.['video-width'] ?? null;
    const videoHeight = stats?.['video-height'] ?? null;
    const fpsNum = stats?.['video-framerate-num'] ?? null;
    const fpsDen = stats?.['video-framerate-den'] ?? null;
    const fpsInferred = stats?.['video-framerate-inferred'] ?? false;
    const interlaceMode = stats?.['video-interlace-mode'] ?? null;
    const scanType = formatScanType(interlaceMode);

    // Connected callers table columns
    const callerColumns = [
        {
            title: 'Address',
            dataIndex: 'caller-address',
            key: 'address',
            render: (addr) => <Tag color="blue">{addr || 'Unknown'}</Tag>,
        },
        {
            title: 'Latency',
            dataIndex: 'negotiated-latency-ms',
            key: 'latency',
            render: (val) => `${val || 0} ms`,
        },
        {
            title: 'Bitrate',
            dataIndex: 'receive-rate-mbps',
            key: 'bitrate',
            render: (val) => formatMbps(val),
        },
        {
            title: 'RTT',
            dataIndex: 'rtt-ms',
            key: 'rtt',
            render: (val) => `${val?.toFixed ? val.toFixed(2) : val || 0} ms`,
        },
        {
            title: 'Packet Loss',
            key: 'loss',
            render: (_, record) => {
                const loss = calculatePacketLoss(
                    record['packets-received'],
                    record['packets-received-lost']
                );
                return (
                    <Tag color={parseFloat(loss) > 5 ? 'red' : parseFloat(loss) > 1 ? 'orange' : 'green'}>
                        {loss}%
                    </Tag>
                );
            },
        },
        {
            title: 'Bytes Received',
            dataIndex: 'bytes-received',
            key: 'bytes',
            render: (val) => formatBytes(val),
        },
    ];

    const statisticStyle = {
        fontSize: 14,
    };

    return (
        <Card
            title={
                <span>
                    Source Statistics
                    {loading && <SyncOutlined spin style={{ marginLeft: 8 }} />}
                </span>
            }
            extra={
                lastUpdated && (
                    <Text type="secondary" style={{ fontSize: 12 }}>
                        Last updated: {lastUpdated.toLocaleTimeString()}
                    </Text>
                )
            }
            style={{ marginBottom: 24 }}
        >
            {loading && !stats ? (
                <div style={{ textAlign: 'center', padding: 24 }}>
                    <Spin tip="Loading statistics..." />
                </div>
            ) : error ? (
                <Empty description={`Error loading stats: ${error}`} />
            ) : !stats ? (
                <Empty description="No statistics available. Start streaming to see stats." />
            ) : (
                <>
                    {/* Summary Statistics */}
                    <Row gutter={[16, 16]} style={{ marginBottom: 16 }}>
                        <Col xs={12} sm={8} md={6} lg={4}>
                            <Statistic
                                title="Bitrate"
                                value={formatMbps(bitrate)}
                                prefix={<ArrowDownOutlined style={{ color: '#52c41a' }} />}
                                valueStyle={{ color: '#52c41a', ...statisticStyle }}
                            />
                        </Col>
                        <Col xs={12} sm={8} md={6} lg={4}>
                            <Statistic
                                title="RTT"
                                value={`${typeof rtt === 'number' ? rtt.toFixed(2) : rtt} ms`}
                                prefix={<ClockCircleOutlined style={{ color: '#1890ff' }} />}
                                valueStyle={{ color: '#1890ff', ...statisticStyle }}
                            />
                        </Col>
                        <Col xs={12} sm={8} md={6} lg={4}>
                            <Statistic
                                title="Packet Loss"
                                value={`${packetLoss}%`}
                                prefix={<ArrowUpOutlined style={{ color: parseFloat(packetLoss) > 1 ? '#ff4d4f' : '#52c41a' }} />}
                                valueStyle={{ color: parseFloat(packetLoss) > 1 ? '#ff4d4f' : '#52c41a', ...statisticStyle }}
                            />
                        </Col>
                        <Col xs={12} sm={8} md={6} lg={4}>
                            <Statistic
                                title="Total Bytes"
                                value={formatBytes(totalBytes)}
                                valueStyle={{ color: '#722ed1', ...statisticStyle }}
                            />
                        </Col>
                        <Col xs={12} sm={8} md={6} lg={4}>
                            <Statistic
                                title="Connected Callers"
                                value={connectedCallers}
                                prefix={<WifiOutlined style={{ color: '#faad14' }} />}
                                valueStyle={{ color: '#faad14', ...statisticStyle }}
                            />
                        </Col>
                        <Col xs={12} sm={8} md={6} lg={4}>
                            <Statistic
                                title="Bandwidth"
                                value={`${typeof bandwidth === 'number' ? bandwidth.toFixed(1) : bandwidth} Mbps`}
                                valueStyle={{ color: '#13c2c2', ...statisticStyle }}
                            />
                        </Col>
                        <Col xs={12} sm={8} md={6} lg={4}>
                            <Statistic
                                title="Dropped"
                                value={packetsDropped}
                                valueStyle={{ color: packetsDropped > 0 ? '#ff4d4f' : '#52c41a', ...statisticStyle }}
                            />
                        </Col>
                        <Col xs={12} sm={8} md={6} lg={4}>
                            <Statistic
                                title="Resolution"
                                value={formatResolution(videoWidth, videoHeight)}
                                prefix={<VideoCameraOutlined style={{ color: '#722ed1' }} />}
                                valueStyle={{ color: '#722ed1', ...statisticStyle }}
                            />
                        </Col>
                        <Col xs={12} sm={8} md={6} lg={4}>
                            <Statistic
                                title="Framerate"
                                value={formatFramerate(fpsNum, fpsDen, fpsInferred)}
                                prefix={<FieldTimeOutlined style={{ color: '#eb2f96' }} />}
                                valueStyle={{ color: '#eb2f96', ...statisticStyle }}
                            />
                        </Col>
                        <Col xs={12} sm={8} md={6} lg={4}>
                            <Statistic
                                title="Scan"
                                value={scanType.label}
                                formatter={(val) => <Tag color={scanType.color}>{val}</Tag>}
                                valueStyle={statisticStyle}
                            />
                        </Col>
                    </Row>

                    {/* Connected Callers Table */}
                    {stats.callers && stats.callers.length > 0 && (
                        <>
                            <Typography.Title level={5} style={{ marginTop: 16, marginBottom: 8 }}>
                                Connected Callers ({connectedCallers})
                            </Typography.Title>
                            <Table
                                dataSource={stats.callers}
                                columns={callerColumns}
                                pagination={false}
                                size="small"
                                rowKey={(record, index) => record['caller-address'] || index}
                            />
                        </>
                    )}
                </>
            )}
        </Card>
    );
};

export default RouteStats;
