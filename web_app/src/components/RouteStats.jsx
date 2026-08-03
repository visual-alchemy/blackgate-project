import { useState } from 'react';
import { Card, Statistic, Row, Col, Table, Typography, Tag, Empty, Alert, Space } from 'antd';
import {
    ArrowUpOutlined,
    ArrowDownOutlined,
    WifiOutlined,
    ClockCircleOutlined,
    SyncOutlined,
    VideoCameraOutlined,
    FieldTimeOutlined
} from '@ant-design/icons';
import { useRouteStats } from '../hooks/useRouteStats';
import HealthBadge from './HealthBadge';

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

const SingleSourceMetrics = ({ sourceTitle, stats, tagColor = 'blue', isActive = true }) => {
    if (!stats) {
        return (
            <Card
                size="small"
                title={
                    <Space>
                        <Tag color={tagColor}>{sourceTitle}</Tag>
                        <Tag color={isActive ? 'green' : 'default'}>{isActive ? 'ACTIVE (LIVE)' : 'STANDBY'}</Tag>
                    </Space>
                }
                style={{ marginBottom: 16 }}
            >
                <Empty image={Empty.PRESENTED_IMAGE_SIMPLE} description={`No live statistics reported for ${sourceTitle}`} />
            </Card>
        );
    }

    const caller = stats?.callers?.[0] || {};
    const connectedCallers = stats?.['connected-callers'] || 0;
    const totalBytes = stats?.['total-bytes-received'] || 0;

    const bitrate = stats?.['receive-rate-mbps'] ?? caller['receive-rate-mbps'] ?? 0;
    const rtt = stats?.['rtt-ms'] ?? caller['rtt-ms'] ?? 0;
    const packetsReceived = stats?.['packets-received'] ?? caller['packets-received'] ?? 0;
    const packetsLost = stats?.['packets-received-lost'] ?? caller['packets-received-lost'] ?? 0;
    const packetsDropped = stats?.['packets-received-dropped'] ?? caller['packets-received-dropped'] ?? 0;
    const bandwidth = stats?.['bandwidth-mbps'] ?? caller['bandwidth-mbps'] ?? 0;
    const packetLoss = calculatePacketLoss(packetsReceived, packetsLost);

    const videoWidth = stats?.['video-width'] ?? null;
    const videoHeight = stats?.['video-height'] ?? null;
    const fpsNum = stats?.['video-framerate-num'] ?? null;
    const fpsDen = stats?.['video-framerate-den'] ?? null;
    const fpsInferred = stats?.['video-framerate-inferred'] ?? false;
    const interlaceMode = stats?.['video-interlace-mode'] ?? null;
    const scanType = formatScanType(interlaceMode);

    const statisticStyle = { fontSize: 14 };

    return (
        <Card
            size="small"
            title={
                <Space>
                    <Tag color={tagColor}>{sourceTitle}</Tag>
                    <Tag color={isActive ? 'green' : 'default'}>{isActive ? 'ACTIVE (LIVE)' : 'STANDBY'}</Tag>
                </Space>
            }
            style={{ marginBottom: 16 }}
        >
            <Row gutter={[16, 16]}>
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
        </Card>
    );
};

const RouteStats = ({ routeId, isRunning, failoverEnabled = false, activeSource = 'primary' }) => {
    // Live stats via WebSocket & polling
    const { stats, secondaryStats, health } = useRouteStats(routeId, isRunning);

    if (!isRunning) {
        return null;
    }

    const hasDualStats = failoverEnabled || secondaryStats !== null;

    return (
        <Card
            title={
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                    <span>
                        Source Statistics
                        {!stats && !secondaryStats && <SyncOutlined spin style={{ marginLeft: 8 }} />}
                    </span>
                    {health && <HealthBadge health={health} />}
                </div>
            }
            style={{ marginBottom: 24 }}
        >
            {!stats && !secondaryStats ? (
                <Empty description="No statistics available. Start streaming to see stats." />
            ) : (
                <>
                    {health === 'source_corrupted' && (
                        <Alert
                            message="Source Stream Corrupted"
                            description={`The video decoder is reporting H.264 slice decoding warnings (${stats?.last_warning_message || 'corrupt slices'}).`}
                            type="warning"
                            showIcon
                            style={{ marginBottom: 16 }}
                        />
                    )}

                    {health === 'blackgate_config_issue' && (
                        <Alert
                            message="Appliance Configuration Issue"
                            description="The video decoder is reporting H.264 slice decoding warnings and local loopback packet loss is active."
                            type="error"
                            showIcon
                            style={{ marginBottom: 16 }}
                        />
                    )}

                    {hasDualStats ? (
                        <div>
                            <SingleSourceMetrics
                                sourceTitle="Primary Source"
                                stats={stats}
                                tagColor="blue"
                                isActive={activeSource === 'primary'}
                            />
                            <SingleSourceMetrics
                                sourceTitle="Secondary Source"
                                stats={secondaryStats}
                                tagColor="orange"
                                isActive={activeSource === 'secondary'}
                            />
                        </div>
                    ) : (
                        <SingleSourceMetrics
                            sourceTitle="Primary Source"
                            stats={stats}
                            tagColor="blue"
                            isActive={true}
                        />
                    )}
                </>
            )}
        </Card>
    );
};

export default RouteStats;
