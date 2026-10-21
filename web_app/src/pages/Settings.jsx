import { useEffect, useState, useRef } from 'react';
import { Typography, Button, Card, Space, message, Tabs, Modal, Table, Tag, Spin, Form, Input, Descriptions, Alert, Tooltip, Progress } from 'antd';
import { HomeOutlined, DownloadOutlined, UploadOutlined, ExclamationCircleOutlined, CheckCircleOutlined, CloseCircleOutlined, WifiOutlined, ReloadOutlined, EditOutlined, UserOutlined, SaveOutlined, DesktopOutlined, VideoCameraOutlined } from '@ant-design/icons';
import { backupApi, networkApi, authApi, systemApi } from '../utils/api';
import { DEVICE_TO_SDI } from '../utils/sdiPorts';
import { logout } from '../utils/auth';

const { Title } = Typography;

const Settings = () => {
  const [activeTab, setActiveTab] = useState('backup');
  const [isDownloading, setIsDownloading] = useState(false);
  const [isRestoring, setIsRestoring] = useState(false);
  const [isDownloadingRoutes, setIsDownloadingRoutes] = useState(false);
  const [isImportingRoutes, setIsImportingRoutes] = useState(false);
  const [interfaces, setInterfaces] = useState([]);
  const [loadingInterfaces, setLoadingInterfaces] = useState(false);
  const [editingInterface, setEditingInterface] = useState(null);
  const [savingInterfaceAlias, setSavingInterfaceAlias] = useState(false);
  const [interfaceAliasForm] = Form.useForm();
  const fileInputRef = useRef(null);
  const routesFileInputRef = useRef(null);
  const [modal, modalContextHolder] = Modal.useModal();
  const [messageApi, contextHolder] = message.useMessage();
  const [systemStatus, setSystemStatus] = useState(null);
  const [loadingSystem, setLoadingSystem] = useState(false);
  const [isDownloadingReport, setIsDownloadingReport] = useState(false);
  const [systemActionBusy, setSystemActionBusy] = useState(null);
  const [uploadingPackage, setUploadingPackage] = useState(false);
  const [uploadProgress, setUploadProgress] = useState(0);
  const [systemConfirm, setSystemConfirm] = useState(null);
  const [typedConfirmation, setTypedConfirmation] = useState('');
  const packageInputRef = useRef(null);

  // Fetch host status when the System tab is active
  useEffect(() => {
    if (activeTab === 'system') {
      fetchSystemStatus();
    }
  }, [activeTab]);

  // While the updater is working, keep the card honest: it writes its progress to /run, and the
  // deploy ends with the service restarting (this page included).
  useEffect(() => {
    const status = systemStatus?.updates?.deploy_status;
    const inProgress = typeof status === 'string' && /^(verifying|deploying)/.test(status);

    if (activeTab !== 'system' || !inProgress) return undefined;

    const timer = setInterval(fetchSystemStatus, 4000);
    return () => clearInterval(timer);
  }, [activeTab, systemStatus?.updates?.deploy_status]);

  const fetchSystemStatus = async () => {
    setLoadingSystem(true);
    try {
      setSystemStatus(await systemApi.status());
    } catch (error) {
      console.error('Error fetching system status:', error);
      messageApi.error({
        content: 'Failed to fetch system status',
        icon: <CloseCircleOutlined />,
        duration: 5
      });
    } finally {
      setLoadingSystem(false);
    }
  };

  // The report is fetched with the session token, so it is saved from a blob rather than
  // opened as a URL: the token never ends up in a query string or a browser history entry.
  const handleSystemReportDownload = async () => {
    setIsDownloadingReport(true);
    try {
      const report = await systemApi.report();
      const blob = new Blob([report], { type: 'text/plain;charset=utf-8' });
      const url = URL.createObjectURL(blob);
      const link = document.createElement('a');
      link.href = url;
      link.download = `blackgate-system-report-${new Date().toISOString().slice(0, 19).replace(/[^0-9]/g, '')}.txt`;
      document.body.appendChild(link);
      link.click();
      document.body.removeChild(link);
      URL.revokeObjectURL(url);
      messageApi.success({
        content: 'System report downloaded',
        icon: <CheckCircleOutlined />,
        duration: 3
      });
    } catch (error) {
      console.error('Error downloading system report:', error);
      messageApi.error({
        content: 'Failed to download system report',
        icon: <CloseCircleOutlined />,
        duration: 5
      });
    } finally {
      setIsDownloadingReport(false);
    }
  };

  // Every privileged action goes through the backend's allowlist, which hands it to the root helper.
  // The helper delays it (3 s restart, 10 s reboot/shutdown, 2 s deploy), so it can still be cancelled.
  const scheduleSystemAction = async (action, argument, verb) => {
    setSystemActionBusy(action);
    try {
      const result = await systemApi.action(action, argument);

      if (result.error) {
        throw new Error(result.error);
      }

      messageApi.success({
        content: `${verb} scheduled`,
        icon: <CheckCircleOutlined />,
        duration: 5
      });
      await fetchSystemStatus();
    } catch (error) {
      messageApi.error({
        content: `${verb} failed: ${error.message}`,
        icon: <CloseCircleOutlined />,
        duration: 8
      });
    } finally {
      setSystemActionBusy(null);
    }
  };

  // Dangerous actions ask the operator to type the action back before the button unlocks.
  const askSystemAction = ({ action, verb, unit, version, typed }) => {
    if (typed) {
      setTypedConfirmation('');
      setSystemConfirm({ action, verb, unit, version, typed });
      return;
    }

    scheduleSystemAction(action, unit || version, verb);
  };

  const confirmSystemAction = () => {
    if (!systemConfirm) return;
    const { action, verb, unit, version } = systemConfirm;
    setSystemConfirm(null);
    setTypedConfirmation('');
    scheduleSystemAction(action, unit || version, verb);
  };

  // Be explicit about the blast radius, especially the part operators get wrong: a restart leaves the
  // routes stopped (a clean shutdown writes `stopped` into Khepri and nothing resumes them).
  const systemConfirmDescription = ({ action, version }) => {
    switch (action) {
      case 'restart_gateway':
        return 'The gateway restarts in 3 seconds. Route configuration is kept, but routes do not resume by themselves after a restart — start them again from Routes.';
      case 'reboot':
        return 'The host reboots in 10 seconds. Every route stops and the gateway stays down until it is back; start the routes again afterwards.';
      case 'shutdown':
        return 'The host powers off in 10 seconds. Nothing brings it back until someone powers it on.';
      case 'deploy':
        return `Deploys release ${version} in 2 seconds. The updater verifies the package signature and the release checksum, swaps the current symlink, restarts the service, and rolls back automatically if the new release fails its health check. Routes stop during the restart.`;
      case 'cancel':
        return 'Stops the scheduled action before it runs.';
      default:
        return '';
    }
  };

  const handlePackageUpload = async (file) => {
    if (!file) return;

    setUploadingPackage(true);
    setUploadProgress(0);

    try {
      const result = await systemApi.uploadPackage(file, setUploadProgress);
      messageApi.success({
        content: `Package ${result.version || file.name} uploaded`,
        icon: <CheckCircleOutlined />,
        duration: 5
      });
      await fetchSystemStatus();
    } catch (error) {
      messageApi.error({
        content: `Upload failed: ${error.message}`,
        icon: <CloseCircleOutlined />,
        duration: 8
      });
    } finally {
      setUploadingPackage(false);
      setUploadProgress(0);
      if (packageInputRef.current) {
        packageInputRef.current.value = '';
      }
    }
  };

  const formatSystemUptime = (seconds) => {
    if (typeof seconds !== 'number') return '-';
    const days = Math.floor(seconds / 86400);
    const hours = Math.floor((seconds % 86400) / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    if (days > 0) return `${days}d ${hours}h ${minutes}m`;
    if (hours > 0) return `${hours}h ${minutes}m`;
    return `${minutes}m`;
  };

  // Set breadcrumb items for the Settings page
  useEffect(() => {
    if (window.setBreadcrumbItems) {
      window.breadcrumbSet = true;
      window.setBreadcrumbItems([
        {
          href: '/',
          title: <HomeOutlined />,
        },
        {
          href: '/settings',
          title: 'Settings',
        }
      ]);
    }
  }, []);

  // Fetch network interfaces when Network tab is active
  useEffect(() => {
    if (activeTab === 'network') {
      fetchInterfaces();
    }
  }, [activeTab]);

  const fetchInterfaces = async () => {
    setLoadingInterfaces(true);
    try {
      const response = await networkApi.getInterfaces();
      setInterfaces(response.interfaces || []);
    } catch (error) {
      console.error('Error fetching network interfaces:', error);
      messageApi.error({
        content: 'Failed to fetch network interfaces',
        icon: <CloseCircleOutlined />,
        duration: 5
      });
    } finally {
      setLoadingInterfaces(false);
    }
  };

  const openInterfaceAliasEditor = (networkInterface) => {
    setEditingInterface(networkInterface);
    interfaceAliasForm.setFieldsValue({ alias: networkInterface.alias || '' });
  };

  const saveInterfaceAlias = async ({ alias }) => {
    if (!editingInterface?.mac) return;
    setSavingInterfaceAlias(true);
    try {
      await networkApi.setInterfaceAlias(editingInterface.mac, alias || '');
      messageApi.success({
        content: alias?.trim() ? 'Interface alias saved' : 'Interface alias removed',
        duration: 3,
      });
      setEditingInterface(null);
      fetchInterfaces();
    } catch (error) {
      messageApi.error({ content: error.message || 'Could not save interface alias', duration: 5 });
    } finally {
      setSavingInterfaceAlias(false);
    }
  };

  const handleBackupDownload = async () => {
    setIsDownloading(true);
    try {
      await backupApi.downloadBackup();
      messageApi.success({
        content: 'Backup download started',
        icon: <DownloadOutlined />,
        duration: 3
      });
    } catch (error) {
      console.error('Error downloading backup:', error);
      messageApi.error({
        content: `Failed to download backup: ${error.message}`,
        icon: <CloseCircleOutlined />,
        duration: 5
      });
    } finally {
      setIsDownloading(false);
    }
  };

  const handleRoutesBackupDownload = async () => {
    setIsDownloadingRoutes(true);
    try {
      await backupApi.download();
      messageApi.success({
        content: 'Routes export started',
        icon: <DownloadOutlined />,
        duration: 3
      });
    } catch (error) {
      console.error('Error exporting routes:', error);
      messageApi.error({
        content: `Failed to export routes: ${error.message}`,
        icon: <CloseCircleOutlined />,
        duration: 5
      });
    } finally {
      setIsDownloadingRoutes(false);
    }
  };

  const handleRoutesImportChange = async (e) => {
    const file = e.target.files[0];
    if (!file) return;

    if (!file.name.endsWith('.json')) {
      messageApi.error({
        content: 'You can only upload .json files!',
        icon: <CloseCircleOutlined />,
        duration: 5
      });
      if (routesFileInputRef.current) {
        routesFileInputRef.current.value = '';
      }
      return;
    }

    modal.confirm({
      title: 'Confirm Import',
      icon: <ExclamationCircleOutlined />,
      content: (
        <>
          <p>Are you sure you want to import routes from this file?</p>
          <p>This will create new routes based on the JSON file.</p>
          <p>Selected file: {file.name}</p>
        </>
      ),
      okText: 'Yes, Import',
      cancelText: 'No, Cancel',
      onOk: async () => {
        setIsImportingRoutes(true);
        try {
          messageApi.loading({
            content: `Importing routes from: ${file.name}...`,
            key: 'importOperation',
            duration: 0
          });

          const result = await backupApi.importRoutes(file);

          // Check for error response
          if (result.error) {
            throw new Error(result.error);
          }

          const imported = result.imported ?? 0;
          const failed = result.failed ?? 0;
          const msg = result.message ?? 'Import completed';

          messageApi.success({
            content: `${msg}: ${imported} imported, ${failed} failed`,
            icon: <CheckCircleOutlined />,
            key: 'importOperation',
            duration: 5
          });
        } catch (error) {
          console.error('Error importing routes:', error);
          messageApi.error({
            content: `Failed to import routes: ${error.message}`,
            icon: <CloseCircleOutlined />,
            key: 'importOperation',
            duration: 5
          });
        } finally {
          setIsImportingRoutes(false);
          if (routesFileInputRef.current) {
            routesFileInputRef.current.value = '';
          }
        }
      },
      onCancel: () => {
        if (routesFileInputRef.current) {
          routesFileInputRef.current.value = '';
        }
      }
    });
  };

  const handleFileChange = async (e) => {
    const file = e.target.files[0];
    if (!file) return;

    if (!file.name.endsWith('.backup')) {
      messageApi.error({
        content: 'You can only upload .backup files!',
        icon: <CloseCircleOutlined />,
        duration: 5
      });
      // Clear the file input
      if (fileInputRef.current) {
        fileInputRef.current.value = '';
      }
      return;
    }

    // Show confirmation dialog using the modal instance
    modal.confirm({
      title: 'Confirm Restore',
      icon: <ExclamationCircleOutlined />,
      content: (
        <>
          <p>Are you sure you want to restore from this backup?</p>
          <p>This will delete all existing data and replace it with the data from the backup file.</p>
          <p>Selected file: {file.name}</p>
        </>
      ),
      okText: 'Yes, Restore',
      cancelText: 'No, Cancel',
      okButtonProps: { danger: true },
      onOk: async () => {
        setIsRestoring(true);
        try {
          console.log('Starting restore process with file:', file.name);

          // Show loading notification
          messageApi.loading({
            content: `Restoring from backup: ${file.name}...`,
            key: 'restoreOperation',
            duration: 0 // 0 means it won't disappear automatically
          });

          const result = await backupApi.restore(file);
          console.log('Restore API response:', result);

          if (result && result.message) {
            messageApi.success({
              content: result.message,
              icon: <CheckCircleOutlined />,
              key: 'restoreOperation', // Use the same key to replace the loading message
              duration: 3
            });
          } else {
            messageApi.success({
              content: `${file.name} backup restored successfully`,
              icon: <CheckCircleOutlined />,
              key: 'restoreOperation',
              duration: 3
            });
          }
        } catch (error) {
          console.error('Error restoring backup:', error);

          let errorMessage = 'Failed to restore backup';
          if (error.response) {
            try {
              const errorData = await error.response.json();
              errorMessage = errorData.error || errorMessage;
            } catch (e) {
              console.error('Error parsing error response:', e);
            }
          } else if (error.message) {
            errorMessage = `${errorMessage}: ${error.message}`;
          }

          messageApi.error({
            content: errorMessage,
            icon: <CloseCircleOutlined />,
            key: 'restoreOperation', // Use the same key to replace the loading message
            duration: 5
          });
        } finally {
          setIsRestoring(false);
          // Clear the file input
          if (fileInputRef.current) {
            fileInputRef.current.value = '';
          }
        }
      },
      onCancel: () => {
        // Clear the file input
        if (fileInputRef.current) {
          fileInputRef.current.value = '';
        }
      }
    });
  };

  // Backup tab content
  const BackupTabContent = () => {
    return (
      <div>
        <Card title="System Backup" style={{ marginBottom: '16px' }}>
          <p>Create a backup of your system configuration and data.</p>
          <Space direction="vertical" style={{ width: '100%' }}>
            <Button
              type="primary"
              icon={<DownloadOutlined />}
              onClick={handleBackupDownload}
              loading={isDownloading}
            >
              Download Backup
            </Button>
            <p style={{ fontSize: '12px', color: 'rgba(255, 255, 255, 0.45)' }}>
              This will create a complete backup of your system configuration.
            </p>
          </Space>
        </Card>

        <Card title="Restore from Backup">
          <p>Restore your system from a previous backup file.</p>
          <Space direction="vertical" style={{ width: '100%' }}>
            <input
              type="file"
              ref={fileInputRef}
              onChange={handleFileChange}
              style={{ display: 'none' }}
              accept=".backup"
              name="backup"
            />
            <Button
              icon={<UploadOutlined />}
              onClick={() => fileInputRef.current.click()}
              loading={isRestoring}
            >
              Select Backup File
            </Button>
            <p style={{ fontSize: '12px', color: 'rgba(255, 255, 255, 0.45)' }}>
              Warning: Restoring from backup will overwrite your current configuration.
            </p>
          </Space>
        </Card>
      </div>
    );
  };

  // Routes tab content
  const RoutesTabContent = () => {
    return (
      <div>
        <Card title="Export Routes" style={{ marginBottom: '16px' }}>
          <p>Export all routes and their destinations as a JSON file.</p>
          <Space direction="vertical" style={{ width: '100%' }}>
            <Button
              type="primary"
              icon={<DownloadOutlined />}
              onClick={handleRoutesBackupDownload}
              loading={isDownloadingRoutes}
            >
              Export Routes as JSON
            </Button>
            <p style={{ fontSize: '12px', color: 'rgba(255, 255, 255, 0.45)' }}>
              This will export a JSON file containing all routes with their destinations.
            </p>
          </Space>
        </Card>

        <Card title="Import Routes">
          <p>Import routes from a previously exported JSON file.</p>
          <Space direction="vertical" style={{ width: '100%' }}>
            <input
              type="file"
              ref={routesFileInputRef}
              onChange={handleRoutesImportChange}
              style={{ display: 'none' }}
              accept=".json"
              name="routes-import"
            />
            <Button
              icon={<UploadOutlined />}
              onClick={() => routesFileInputRef.current.click()}
              loading={isImportingRoutes}
            >
              Select JSON File
            </Button>
            <p style={{ fontSize: '12px', color: 'rgba(255, 255, 255, 0.45)' }}>
              This will create new routes based on the imported JSON file.
            </p>
          </Space>
        </Card>
      </div>
    );
  };

  // Network tab content
  const NetworkTabContent = () => {
    const columns = [
      {
        title: 'Interface',
        dataIndex: 'name',
        key: 'name',
        render: (name, record) => (
          <Space direction="vertical" size={0}>
            <span>{record.alias || name}</span>
            {record.alias && <code style={{ fontSize: '12px' }}>{name}</code>}
          </Space>
        ),
      },
      {
        title: 'Alias',
        dataIndex: 'alias',
        key: 'alias',
        render: (alias) => alias || <span style={{ color: 'rgba(255, 255, 255, 0.45)' }}>Not set</span>,
      },
      {
        title: 'IP Address',
        dataIndex: 'address',
        key: 'address',
        render: (address) => address || '-',
      },
      {
        title: 'Netmask',
        dataIndex: 'netmask',
        key: 'netmask',
        render: (netmask) => netmask || '-',
      },
      {
        title: 'MAC Address',
        dataIndex: 'mac',
        key: 'mac',
        render: (mac) => mac ? <code style={{ fontSize: '12px' }}>{mac}</code> : '-',
      },
      {
        title: 'Status',
        dataIndex: 'up',
        key: 'up',
        render: (up) => (
          <Tag color={up ? 'green' : 'red'}>
            {up ? 'UP' : 'DOWN'}
          </Tag>
        ),
      },
      {
        title: 'Actions',
        key: 'actions',
        render: (_, record) => (
          <Button
            type="text"
            icon={<EditOutlined />}
            disabled={!record.mac}
            onClick={() => openInterfaceAliasEditor(record)}
          >
            Edit Alias
          </Button>
        ),
      },
    ];

    return (
      <div>
        <Card
          title={
            <Space>
              <WifiOutlined />
              <span>Network Interfaces</span>
            </Space>
          }
          extra={
            <Button
              icon={<ReloadOutlined />}
              onClick={fetchInterfaces}
              loading={loadingInterfaces}
            >
              Refresh
            </Button>
          }
        >
          <p style={{ marginBottom: '16px' }}>
            Interfaces detected on this server, with an optional display alias. Aliases are Blackgate
            labels only — the Linux interface name and the traffic on it are not changed — and the route
            forms show them when you pick an interface to bind.
          </p>
          {loadingInterfaces ? (
            <div style={{ textAlign: 'center', padding: '40px' }}>
              <Spin tip="Loading interfaces..." />
            </div>
          ) : (
            <Table
              columns={columns}
              dataSource={interfaces}
              rowKey="name"
              pagination={false}
              size="small"
            />
          )}
        </Card>
        <Modal
          open={Boolean(editingInterface)}
          title={editingInterface ? `Edit alias — ${editingInterface.name}` : 'Edit interface alias'}
          okText="Save Alias"
          confirmLoading={savingInterfaceAlias}
          onCancel={() => {
            if (!savingInterfaceAlias) setEditingInterface(null);
          }}
          onOk={() => interfaceAliasForm.submit()}
          destroyOnClose
        >
          <Form form={interfaceAliasForm} layout="vertical" onFinish={saveInterfaceAlias}>
            <Form.Item
              name="alias"
              label="Display Alias"
              extra="Examples: ISP1, ISP2. Leave blank to use the Linux interface name."
              rules={[
                { max: 32, message: 'Maximum 32 characters' },
                {
                  pattern: /^[A-Za-z0-9][A-Za-z0-9 ._-]*$/,
                  message: 'Use letters, numbers, spaces, dots, dashes, or underscores',
                },
              ]}
            >
              <Input autoFocus autoComplete="off" placeholder="ISP1" />
            </Form.Item>
          </Form>
        </Modal>
      </div>
    );
  };

  // Users tab content
  const UsersTabContent = () => {
    const [form] = Form.useForm();
    const [isUpdating, setIsUpdating] = useState(false);

    const onFinish = async (values) => {
      setIsUpdating(true);
      try {
        const result = await authApi.updateCredentials(
          values.currentPassword,
          values.newUsername,
          values.newPassword
        );

        if (result.error) {
          throw new Error(result.error);
        }

        messageApi.success({
          content: 'Credentials updated successfully. Please log in again.',
          icon: <CheckCircleOutlined />,
          duration: 3
        });

        // Use a short timeout before logging out to let the user see the success message
        setTimeout(() => {
          logout();
        }, 1500);
      } catch (error) {
        console.error('Error updating credentials:', error);
        messageApi.error({
          content: `Failed to update credentials: ${error.message || 'Unknown error'}`,
          icon: <CloseCircleOutlined />,
          duration: 5
        });
      } finally {
        setIsUpdating(false);
      }
    };

    return (
      <div>
        <Card
          title={
            <Space>
              <UserOutlined />
              <span>Admin Credentials</span>
            </Space>
          }
        >
          <p style={{ marginBottom: '24px' }}>
            Update the username and password used to access this dashboard.
          </p>
          <Form
            form={form}
            layout="vertical"
            onFinish={onFinish}
            style={{ maxWidth: 400 }}
          >
            <Form.Item
              name="currentPassword"
              label="Current Password"
              rules={[{ required: true, message: 'Please enter your current password' }]}
            >
              <Input.Password placeholder="Enter current password" />
            </Form.Item>

            <Form.Item
              name="newUsername"
              label="New Username"
              rules={[
                { required: true, message: 'Please enter a new username' },
                { min: 3, message: 'Username must be at least 3 characters' }
              ]}
            >
              <Input placeholder="Enter new username" />
            </Form.Item>

            <Form.Item
              name="newPassword"
              label="New Password"
              rules={[
                { required: true, message: 'Please enter a new password' },
                { min: 6, message: 'Password must be at least 6 characters' }
              ]}
            >
              <Input.Password placeholder="Enter new password" />
            </Form.Item>

            <Form.Item
              name="confirmPassword"
              label="Confirm New Password"
              dependencies={['newPassword']}
              rules={[
                { required: true, message: 'Please confirm your new password' },
                ({ getFieldValue }) => ({
                  validator(_, value) {
                    if (!value || getFieldValue('newPassword') === value) {
                      return Promise.resolve();
                    }
                    return Promise.reject(new Error('The two passwords do not match!'));
                  },
                }),
              ]}
            >
              <Input.Password placeholder="Confirm new password" />
            </Form.Item>

            <Form.Item>
              <Button type="primary" htmlType="submit" icon={<SaveOutlined />} loading={isUpdating} block>
                Update Credentials
              </Button>
            </Form.Item>
          </Form>
        </Card>
      </div>
    );
  };

  // Settings > System: what the host actually is right now. Read-only — the restart/reboot/update
  // actions need the privileged helper and the systemd unit a packaged appliance installs.
  const SystemTabContent = () => {
    const status = systemStatus;

    const sdiColumns = [
      {
        title: 'Route',
        dataIndex: 'route',
        key: 'route',
      },
      {
        title: 'SDI Port',
        dataIndex: 'port',
        key: 'port',
        render: (port) => <Tag color="blue">{port}</Tag>,
      },
      {
        title: 'Device',
        dataIndex: 'device',
        key: 'device',
        render: (device) => <code>{device}</code>,
      },
      {
        title: 'Mode',
        dataIndex: 'mode',
        key: 'mode',
        render: (mode) => mode || '-',
      },
      {
        title: 'Video Frames',
        dataIndex: 'frames',
        key: 'frames',
        render: (frames) => (typeof frames === 'number' ? frames.toLocaleString() : '-'),
      },
      {
        title: 'Dropped',
        dataIndex: 'dropped',
        key: 'dropped',
        render: (dropped) => (
          <Tag color={dropped ? 'orange' : 'green'}>{dropped || 0}</Tag>
        ),
      },
      {
        title: 'Duplicated',
        dataIndex: 'duplicated',
        key: 'duplicated',
        render: (duplicated) => (
          <Tag color={duplicated ? 'orange' : 'green'}>{duplicated || 0}</Tag>
        ),
      },
      {
        title: 'Audio Buffers',
        dataIndex: 'audio',
        key: 'audio',
        render: (audio) => (typeof audio === 'number' ? audio.toLocaleString() : '-'),
      },
    ];

    const sdiRows = status
      ? (status.routes?.items || []).flatMap((route) =>
          (route.sdi || []).map((sdi) => ({
            key: `${route.id}-${sdi.device_number}`,
            route: route.name,
            port: DEVICE_TO_SDI[sdi.device_number]
              ? `SDI ${DEVICE_TO_SDI[sdi.device_number]}`
              : `device ${sdi.device_number}`,
            device: sdi.device_number,
            mode: sdi.detected_mode,
            frames: sdi.video_frames,
            dropped: sdi.dropped_frames,
            duplicated: sdi.duplicated_frames,
            audio: sdi.audio_buffers,
          }))
        )
      : [];

    if (!status) {
      return (
        <div style={{ display: 'flex', justifyContent: 'center', padding: '40px' }}>
          <Spin />
        </div>
      );
    }

    const buffers = status.udp_buffers || {};
    const memory = status.memory || {};
    const disk = status.disk || {};
    const decklink = status.decklink || { device_count: 0, devices: [] };
    const routes = status.routes || { total: 0, started: 0, items: [] };
    const engine = status.engine;
    const service = status.service || {};
    const updates = status.updates || {};
    const actionsInfo = status.actions || {};
    const release = status.release || {};
    const packages = updates.available || [];
    const scheduled = actionsInfo.scheduled || [];

    const packageColumns = [
      {
        title: 'Version',
        dataIndex: 'version',
        key: 'version',
        render: (version) => <code>{version}</code>,
      },
      {
        title: 'Package',
        dataIndex: 'filename',
        key: 'filename',
      },
      {
        title: 'Size',
        dataIndex: 'size_mb',
        key: 'size_mb',
        render: (size) => `${size} MB`,
      },
      {
        title: 'Uploaded',
        dataIndex: 'uploaded_at',
        key: 'uploaded_at',
        render: (at) => (at ? at.replace('T', ' ').slice(0, 19) : '-'),
      },
      {
        title: 'State',
        key: 'state',
        render: (_, row) =>
          row.current ? (
            <Tag color="green">deployed</Tag>
          ) : row.deployed ? (
            <Tag color="blue">unpacked (rollback target)</Tag>
          ) : (
            <Tag>uploaded</Tag>
          ),
      },
      {
        title: 'Action',
        key: 'action',
        render: (_, row) => (
          <Button
            size="small"
            type="primary"
            disabled={!actionsInfo.can_schedule || row.current || systemActionBusy === 'deploy'}
            loading={systemActionBusy === 'deploy'}
            onClick={() =>
              askSystemAction({
                action: 'deploy',
                verb: `Deploy ${row.version}`,
                version: row.version,
                typed: row.version
              })
            }
          >
            {row.deployed ? 'Roll back to this' : 'Deploy'}
          </Button>
        ),
      },
    ];

    return (
      <div>
        <Space direction="vertical" size="large" style={{ width: '100%' }}>
          <Card
            title={
              <Space>
                <DesktopOutlined />
                <span>Gateway Status</span>
              </Space>
            }
            extra={
              <Space>
                <Button icon={<ReloadOutlined />} onClick={fetchSystemStatus} loading={loadingSystem}>
                  Refresh
                </Button>
                <Button
                  icon={<DownloadOutlined />}
                  onClick={handleSystemReportDownload}
                  loading={isDownloadingReport}
                >
                  Download System Report
                </Button>
              </Space>
            }
          >
            {!buffers.meets_documented_minimum && (
              <Alert
                type="warning"
                showIcon
                style={{ marginBottom: 16 }}
                message="UDP socket buffers are below the documented minimum"
                description={`rmem_max=${buffers.rmem_max_mb ?? '-'} MB, wmem_max=${buffers.wmem_max_mb ?? '-'} MB. This project documents at least ${buffers.documented_min_mb ?? 16} MB so a 9-50 Mbps SRT feed is not dropped by the kernel before the gateway sees it. Raise net.core.rmem_max and net.core.wmem_max and reload sysctl.`}
              />
            )}

            <Descriptions column={2} size="small" bordered>
              <Descriptions.Item label="Hostname">{status.hostname}</Descriptions.Item>
              <Descriptions.Item label="Gateway version">{status.version}</Descriptions.Item>
              <Descriptions.Item label="Operating system">{status.os}</Descriptions.Item>
              <Descriptions.Item label="Kernel">{status.kernel}</Descriptions.Item>
              <Descriptions.Item label="Uptime">{formatSystemUptime(status.uptime_seconds)}</Descriptions.Item>
              <Descriptions.Item label="Booted at">{status.booted_at || '-'}</Descriptions.Item>
              <Descriptions.Item label="Memory">
                {typeof memory.total_mb === 'number'
                  ? `${memory.used_mb} MB used / ${memory.total_mb} MB (${memory.used_percent}%)`
                  : '-'}
              </Descriptions.Item>
              <Descriptions.Item label="Disk (/)">
                {typeof disk.total_gb === 'number'
                  ? `${disk.used_gb} GB used / ${disk.total_gb} GB (${disk.used_percent}%)`
                  : '-'}
              </Descriptions.Item>
              <Descriptions.Item label="UDP socket buffers">
                <Space size="small">
                  <span>{`rmem ${buffers.rmem_max_mb ?? '-'} MB · wmem ${buffers.wmem_max_mb ?? '-'} MB`}</span>
                  <Tag color={buffers.meets_documented_minimum ? 'green' : 'orange'}>
                    {buffers.meets_documented_minimum ? 'OK' : 'BELOW MINIMUM'}
                  </Tag>
                </Space>
              </Descriptions.Item>
              <Descriptions.Item label="DeckLink">
                <Space size="small">
                  <Tag color={decklink.device_count > 0 ? 'green' : 'red'}>
                    {decklink.device_count > 0 ? `${decklink.device_count} device(s)` : 'no card'}
                  </Tag>
                  <span style={{ fontSize: '12px' }}>{(decklink.devices || []).join(', ')}</span>
                </Space>
              </Descriptions.Item>
              <Descriptions.Item label="Gateway service">
                <Space size="small">
                  <Tag color={service.active === 'active' ? 'green' : 'default'}>{service.active}</Tag>
                  <span style={{ fontSize: '12px' }}>
                    {service.unit_installed
                      ? 'systemd unit installed'
                      : 'unit not installed (started manually)'}
                  </span>
                </Space>
              </Descriptions.Item>
              <Descriptions.Item label="Engine binary">
                {engine ? (
                  <span style={{ fontSize: '12px' }}>
                    <code>{engine.sha256}</code> · {engine.size_mb} MB · built {engine.mtime}
                  </span>
                ) : (
                  '-'
                )}
              </Descriptions.Item>
            </Descriptions>
          </Card>

          <Card
            title={
              <Space>
                <VideoCameraOutlined />
                <span>SDI Output</span>
              </Space>
            }
            extra={
              <span style={{ fontSize: '12px' }}>
                {`${routes.started} of ${routes.total} routes started`}
              </span>
            }
          >
            {sdiRows.length === 0 ? (
              <span style={{ color: '#8c8c8c' }}>No route is currently sending to an SDI output.</span>
            ) : (
              <Table columns={sdiColumns} dataSource={sdiRows} pagination={false} size="small" />
            )}
          </Card>

          <Card
            title={
              <Space>
                <ExclamationCircleOutlined />
                <span>Maintenance</span>
              </Space>
            }
          >
            {scheduled.length > 0 && (
              <Alert
                type="warning"
                showIcon
                style={{ marginBottom: 16 }}
                message={`Scheduled: ${scheduled.map((item) => item.action).join(', ')}`}
                description={
                  scheduled[0].fires_at
                    ? `Runs at ${new Date(scheduled[0].fires_at).toLocaleTimeString()} — the helper delays every action, so this can still be stopped.`
                    : 'The helper delays every action, so this can still be stopped before it runs.'
                }
                action={
                  <Button
                    size="small"
                    danger
                    loading={systemActionBusy === 'cancel'}
                    onClick={() =>
                      askSystemAction({
                        action: 'cancel',
                        verb: `Cancel ${scheduled[0].action}`,
                        unit: scheduled[0].unit
                      })
                    }
                  >
                    Cancel
                  </Button>
                }
              />
            )}

            {!actionsInfo.can_schedule && (
              <Alert
                type="info"
                showIcon
                style={{ marginBottom: 16 }}
                message="Privileged actions are unavailable on this gateway"
                description="The root helper and its sudoers drop-in are not installed, so nothing here can be scheduled. On the appliance they ship with the image; on a manual install run scripts/install-system-actions.sh as root."
              />
            )}

            <Space wrap>
              <Tooltip
                title={
                  actionsInfo.available?.restart_gateway
                    ? 'Restart blackgate.service (3 s delay, cancellable)'
                    : 'Needs the systemd unit — a hand-started node carries its environment in the shell that launched it'
                }
              >
                <Button
                  icon={<ReloadOutlined />}
                  disabled={!actionsInfo.available?.restart_gateway}
                  loading={systemActionBusy === 'restart_gateway'}
                  onClick={() =>
                    askSystemAction({ action: 'restart_gateway', verb: 'Restart gateway' })
                  }
                >
                  Restart Gateway
                </Button>
              </Tooltip>

              <Tooltip
                title={
                  actionsInfo.available?.reboot
                    ? 'Reboot the host (10 s delay, cancellable)'
                    : 'Needs the root helper + sudoers drop-in'
                }
              >
                <Button
                  danger
                  disabled={!actionsInfo.available?.reboot}
                  loading={systemActionBusy === 'reboot'}
                  onClick={() =>
                    askSystemAction({ action: 'reboot', verb: 'Reboot gateway', typed: 'reboot' })
                  }
                >
                  Reboot Gateway
                </Button>
              </Tooltip>

              <Tooltip
                title={
                  actionsInfo.available?.shutdown
                    ? 'Power the host off (10 s delay, cancellable)'
                    : 'Needs the root helper + sudoers drop-in'
                }
              >
                <Button
                  danger
                  disabled={!actionsInfo.available?.shutdown}
                  loading={systemActionBusy === 'shutdown'}
                  onClick={() =>
                    askSystemAction({
                      action: 'shutdown',
                      verb: 'Shutdown gateway',
                      typed: 'shutdown'
                    })
                  }
                >
                  Shutdown Gateway
                </Button>
              </Tooltip>
            </Space>

            <div style={{ marginTop: 8, fontSize: '12px', color: '#8c8c8c' }}>
              Scheduled through the root helper with a delay, so a mis-click can still be cancelled.
              Every action is recorded in Events.
            </div>
          </Card>

          <Card
            title={
              <Space>
                <UploadOutlined />
                <span>Software Update</span>
              </Space>
            }
            extra={
              <Space>
                <span style={{ fontSize: '12px' }}>
                  {`updater: ${updates.deploy_status || 'idle'}`}
                </span>
                <Button icon={<ReloadOutlined />} onClick={fetchSystemStatus} loading={loadingSystem}>
                  Refresh
                </Button>
              </Space>
            }
          >
            <Descriptions column={2} size="small" bordered style={{ marginBottom: 16 }}>
              <Descriptions.Item label="Release">{release.version || '-'}</Descriptions.Item>
              <Descriptions.Item label="Application version">
                {release.app_version || '-'}
              </Descriptions.Item>
              <Descriptions.Item label="Released on">{release.released_on || '-'}</Descriptions.Item>
              <Descriptions.Item label="Deployment root">{updates.root || '-'}</Descriptions.Item>
            </Descriptions>

            {release.changes?.length > 0 && (
              <div style={{ marginBottom: 16 }}>
                <div style={{ fontWeight: 600, marginBottom: 4 }}>What changed</div>
                <ul style={{ margin: 0, paddingLeft: '20px' }}>
                  {release.changes.map((change, index) => (
                    <li key={index}>{change}</li>
                  ))}
                </ul>
              </div>
            )}

            <Space wrap style={{ marginBottom: 16 }}>
              <input
                ref={packageInputRef}
                type="file"
                accept=".bgupdate"
                style={{ display: 'none' }}
                onChange={(event) => handlePackageUpload(event.target.files?.[0])}
              />
              <Tooltip
                title={
                  actionsInfo.can_schedule
                    ? 'A signed .bgupdate built by scripts/package-signed-update.sh'
                    : 'Needs the root helper + sudoers drop-in to deploy, but uploading is still possible'
                }
              >
                <Button
                  icon={<UploadOutlined />}
                  loading={uploadingPackage}
                  onClick={() => packageInputRef.current?.click()}
                >
                  Upload package (.bgupdate)
                </Button>
              </Tooltip>
              {uploadingPackage && (
                <Progress percent={uploadProgress} size="small" style={{ width: '200px' }} />
              )}
            </Space>

            {packages.length === 0 ? (
              <span style={{ color: '#8c8c8c' }}>
                Nothing uploaded yet. Build a package with scripts/package-signed-update.sh: it is
                signed, and the updater refuses anything whose signature it cannot verify.
              </span>
            ) : (
              <Table columns={packageColumns} dataSource={packages} pagination={false} size="small" />
            )}
          </Card>
        </Space>
      </div>
    );
  };

  const items = [
    {
      key: 'backup',
      label: 'Backup',
      children: <BackupTabContent />,
    },
    {
      key: 'routes',
      label: 'Routes',
      children: <RoutesTabContent />,
    },
    {
      key: 'network',
      label: 'Network',
      children: <NetworkTabContent />,
    },
    {
      key: 'users',
      label: 'Users',
      children: <UsersTabContent />,
    },
    {
      key: 'system',
      label: 'System',
      children: <SystemTabContent />,
    },
  ];

  return (
    <div>
      {contextHolder}
      {modalContextHolder}

      <Modal
        open={Boolean(systemConfirm)}
        title={systemConfirm ? `${systemConfirm.verb}?` : ''}
        okText={systemConfirm ? systemConfirm.verb : 'Confirm'}
        cancelText="Cancel"
        okButtonProps={{
          danger: systemConfirm ? ['reboot', 'shutdown'].includes(systemConfirm.action) : false,
          disabled:
            Boolean(systemConfirm?.typed) && typedConfirmation.trim() !== systemConfirm?.typed
        }}
        onOk={confirmSystemAction}
        onCancel={() => {
          setSystemConfirm(null);
          setTypedConfirmation('');
        }}
      >
        {systemConfirm && (
          <Space direction="vertical" style={{ width: '100%' }}>
            <span>{systemConfirmDescription(systemConfirm)}</span>
            {systemConfirm.typed && (
              <>
                <span>
                  Type <code>{systemConfirm.typed}</code> to confirm:
                </span>
                <Input
                  value={typedConfirmation}
                  onChange={(event) => setTypedConfirmation(event.target.value)}
                  placeholder={systemConfirm.typed}
                  autoFocus
                />
              </>
            )}
          </Space>
        )}
      </Modal>
      <Space direction="vertical" size="large" style={{ width: '100%' }}>

        <Space style={{ width: '100%', justifyContent: 'space-between' }}>
          <Title level={3} style={{ margin: 0, fontSize: '2rem', fontWeight: 600 }}>Settings</Title>
        </Space>

        <Card>
          <Tabs
            activeKey={activeTab}
            onChange={setActiveTab}
            items={items}
            tabPosition="left"
          />
        </Card>
      </Space>
    </div>
  );
};

export default Settings; 