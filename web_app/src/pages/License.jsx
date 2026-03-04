import { useState, useEffect } from 'react';
import { Card, Typography, Space, Input, Button, message, Tag, Statistic, Row, Col, Alert, Divider, Modal } from 'antd';
import {
    SafetyCertificateOutlined,
    KeyOutlined,
    ClockCircleOutlined,
    TeamOutlined,
    CheckCircleOutlined,
    ExclamationCircleOutlined,
    CloseCircleOutlined,
    DeleteOutlined,
} from '@ant-design/icons';
import { licenseApi } from '../utils/api';

const { Title, Text, Paragraph } = Typography;
const { TextArea } = Input;

const License = () => {
    const [license, setLicense] = useState(null);
    const [loading, setLoading] = useState(true);
    const [activating, setActivating] = useState(false);
    const [licenseKey, setLicenseKey] = useState('');
    const [modal, modalContextHolder] = Modal.useModal();

    const fetchLicense = async () => {
        try {
            const response = await licenseApi.getStatus();
            setLicense(response.data);
        } catch (error) {
            console.error('Failed to fetch license:', error);
        } finally {
            setLoading(false);
        }
    };

    useEffect(() => {
        fetchLicense();
    }, []);

    const handleActivate = async () => {
        if (!licenseKey.trim()) {
            message.warning('Please enter a license key');
            return;
        }

        setActivating(true);
        try {
            const response = await licenseApi.activate(licenseKey.trim());
            if (response.error) {
                let errorTitle = 'Activation Failed';
                let errorMessage = response.error;

                // Provide a more professional, user-friendly message for the locked device scenario
                if (response.error.toLowerCase().includes('locked')) {
                    errorTitle = 'License Already Used';
                    errorMessage = 'This license key is already bound to another device. Licenses can only be used on a single machine at a time. Please purchase a new license key or contact support to request a device reset.';
                }

                modal.error({
                    title: errorTitle,
                    content: errorMessage,
                    okText: 'Understood',
                });
            } else {
                message.success('License activated successfully!');
                setLicenseKey('');
                fetchLicense();
            }
        } catch (error) {
            modal.error({
                title: 'Connection Error',
                content: 'Failed to communicate with the license server. Please ensure you have an active internet connection and try again.',
                okText: 'Close',
            });
        } finally {
            setActivating(false);
        }
    };

    const handleDeactivate = () => {
        modal.confirm({
            title: 'Deactivate License',
            content: 'Are you sure you want to deactivate your license? This will revert to trial mode.',
            okText: 'Deactivate',
            okType: 'danger',
            cancelText: 'Cancel',
            onOk: async () => {
                try {
                    await licenseApi.deactivate();
                    message.success('License deactivated');
                    fetchLicense();
                } catch (error) {
                    message.error('Failed to deactivate license');
                }
            },
        });
    };

    const getStatusTag = () => {
        if (!license) return null;

        if (license.expired) {
            return <Tag icon={<CloseCircleOutlined />} color="error">Expired</Tag>;
        }

        if (license.status === 'licensed') {
            return <Tag icon={<CheckCircleOutlined />} color="success">Licensed</Tag>;
        }

        if (license.status === 'trial') {
            return <Tag icon={<ClockCircleOutlined />} color="warning">Trial</Tag>;
        }

        return <Tag icon={<ExclamationCircleOutlined />} color="default">Unlicensed</Tag>;
    };

    const getPlanLabel = (plan) => {
        const labels = {
            trial: 'Trial',
            starter: 'Starter',
            pro: 'Professional',
            enterprise: 'Enterprise',
        };
        return labels[plan] || plan;
    };

    if (loading) {
        return <Card loading={true} />;
    }

    return (
        <Space direction="vertical" size="large" style={{ width: '100%' }}>
            {modalContextHolder}
            <Title level={3} style={{ margin: 0 }}>
                <SafetyCertificateOutlined style={{ marginRight: 8 }} />
                License
            </Title>

            {/* License Status Card */}
            <Card>
                <Space direction="vertical" size="middle" style={{ width: '100%' }}>
                    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                        <Space>
                            <Title level={4} style={{ margin: 0 }}>License Status</Title>
                            {getStatusTag()}
                        </Space>
                        {license?.status === 'licensed' && (
                            <Button
                                danger
                                icon={<DeleteOutlined />}
                                onClick={handleDeactivate}
                                size="small"
                            >
                                Deactivate
                            </Button>
                        )}
                    </div>

                    {license?.expired && (
                        <Alert
                            message={license.status === 'trial' ? 'Trial Period Expired' : 'License Expired'}
                            description={
                                license.status === 'trial'
                                    ? 'Your 30-day trial has ended. Please activate a license key to continue using Blackgate.'
                                    : 'Your license has expired. Please renew your license to start new routes.'
                            }
                            type="error"
                            showIcon
                        />
                    )}

                    {license?.status === 'trial' && !license.expired && (
                        <Alert
                            message={`Trial Mode — ${license.days_remaining} days remaining`}
                            description={`You can run up to ${license.max_routes} routes during the trial. Activate a license key for more routes.`}
                            type="warning"
                            showIcon
                        />
                    )}

                    <Row gutter={[16, 16]}>
                        <Col xs={12} sm={8} md={6}>
                            <Statistic
                                title="Plan"
                                value={getPlanLabel(license?.plan)}
                                prefix={<SafetyCertificateOutlined />}
                            />
                        </Col>
                        <Col xs={12} sm={8} md={6}>
                            <Statistic
                                title="Client"
                                value={license?.client || '—'}
                                prefix={<TeamOutlined />}
                            />
                        </Col>
                        <Col xs={12} sm={8} md={6}>
                            <Statistic
                                title="Max Routes"
                                value={license?.max_routes >= 999999 ? 'Unlimited' : (license?.max_routes || 0)}
                            />
                        </Col>
                        <Col xs={12} sm={8} md={6}>
                            <Statistic
                                title="Days Remaining"
                                value={license?.days_remaining ?? 0}
                                prefix={<ClockCircleOutlined />}
                                valueStyle={{
                                    color: license?.expired ? '#ff4d4f'
                                        : license?.days_remaining <= 7 ? '#faad14'
                                            : '#52c41a'
                                }}
                            />
                        </Col>
                        <Col xs={12} sm={8} md={6}>
                            <Statistic title="Issued" value={license?.issued_at || '—'} />
                        </Col>
                        <Col xs={12} sm={8} md={6}>
                            <Statistic title="Expires" value={license?.expires_at || '—'} />
                        </Col>
                    </Row>
                </Space>
            </Card>

            {/* Activate License Card */}
            <Card
                title={
                    <Space>
                        <KeyOutlined />
                        <span>Activate License Key</span>
                    </Space>
                }
            >
                <Space direction="vertical" size="middle" style={{ width: '100%' }}>
                    <Paragraph type="secondary">
                        Paste your license key below to activate or upgrade your Blackgate installation.
                    </Paragraph>
                    <TextArea
                        value={licenseKey}
                        onChange={(e) => setLicenseKey(e.target.value)}
                        placeholder="BG-PRO-eyJjbGllbnQiOi..."
                        rows={3}
                        style={{
                            fontFamily: 'monospace',
                            fontSize: '13px',
                        }}
                    />
                    <Button
                        type="primary"
                        icon={<CheckCircleOutlined />}
                        onClick={handleActivate}
                        loading={activating}
                        disabled={!licenseKey.trim()}
                        size="large"
                    >
                        Activate License
                    </Button>
                </Space>
            </Card>
        </Space>
    );
};

export default License;
