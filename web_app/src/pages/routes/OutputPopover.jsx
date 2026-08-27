import { useState, useEffect } from 'react';
import { Popover, InputNumber, Input, Button, Space, Typography, Tag, Divider, message, Tooltip } from 'antd';
import { EditOutlined, PlusOutlined, DeleteOutlined, SettingOutlined } from '@ant-design/icons';
import { destinationsApi, routesApi } from '../../utils/api';
import { useNavigate } from 'react-router-dom';

const { Text } = Typography;

const OutputPopover = ({ route, onUpdate }) => {
  const [open, setOpen] = useState(false);
  const [saving, setSaving] = useState(false);
  const navigate = useNavigate();

  const destinations = route.destinations || [];

  const handleQuickUpdate = async (destId, field, value) => {
    setSaving(true);
    try {
      const dest = destinations.find(d => d.id === destId);
      if (!dest) return;

      let updatedData;
      if (field === 'localport') {
        updatedData = {
          ...dest,
          schema_options: { ...dest.schema_options, localport: value }
        };
      } else if (field === 'udp_host_port') {
        const [host, port] = value.split(':');
        updatedData = {
          ...dest,
          schema_options: { ...dest.schema_options, host: host, port: parseInt(port) }
        };
      }

      if (updatedData) {
        await destinationsApi.update(route.id, destId, updatedData);
        message.success('Destination updated');
        if (onUpdate) onUpdate();
      }
    } catch (error) {
      message.error(`Failed to update: ${error.message}`);
    } finally {
      setSaving(false);
    }
  };

  const handleDelete = async (destId, destName) => {
    try {
      await destinationsApi.delete(route.id, destId);
      message.success(`Deleted "${destName}"`);
      if (onUpdate) onUpdate();
    } catch (error) {
      message.error(`Failed to delete: ${error.message}`);
    }
  };

  const renderDestinationRow = (dest) => {
    switch (dest.schema) {
      case 'SRT': {
        const port = dest.schema_options?.localport || '';
        return (
          <div key={dest.id} style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 8 }}>
            <Tag color="blue" style={{ margin: 0 }}>SRT</Tag>
            <InputNumber
              size="small"
              value={port}
              style={{ width: 90 }}
              min={1}
              max={65535}
              disabled={saving}
              onPressEnter={(e) => handleQuickUpdate(dest.id, 'localport', e.target.value)}
              onBlur={(e) => {
                const newVal = parseInt(e.target.value);
                if (newVal && newVal !== port) {
                  handleQuickUpdate(dest.id, 'localport', newVal);
                }
              }}
            />
            <Text type="secondary" style={{ fontSize: 12 }}>
              {dest.schema_options?.mode || 'listener'}
            </Text>
            <Tooltip title="Full edit">
              <Button
                type="text"
                size="small"
                icon={<SettingOutlined />}
                onClick={() => {
                  setOpen(false);
                  navigate(`/routes/${route.id}/destinations/${dest.id}/edit`);
                }}
              />
            </Tooltip>
            <Tooltip title="Delete">
              <Button
                type="text"
                size="small"
                danger
                icon={<DeleteOutlined />}
                onClick={() => handleDelete(dest.id, dest.name)}
              />
            </Tooltip>
          </div>
        );
      }

      case 'UDP': {
        const host = dest.schema_options?.host || dest.schema_options?.address || '';
        const port = dest.schema_options?.port || '';
        return (
          <div key={dest.id} style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 8 }}>
            <Tag color="orange" style={{ margin: 0 }}>UDP</Tag>
            <Input
              size="small"
              defaultValue={`${host}:${port}`}
              style={{ width: 160 }}
              disabled={saving}
              onPressEnter={(e) => handleQuickUpdate(dest.id, 'udp_host_port', e.target.value)}
              onBlur={(e) => {
                const original = `${host}:${port}`;
                if (e.target.value !== original) {
                  handleQuickUpdate(dest.id, 'udp_host_port', e.target.value);
                }
              }}
            />
            <Tooltip title="Full edit">
              <Button
                type="text"
                size="small"
                icon={<SettingOutlined />}
                onClick={() => {
                  setOpen(false);
                  navigate(`/routes/${route.id}/destinations/${dest.id}/edit`);
                }}
              />
            </Tooltip>
            <Tooltip title="Delete">
              <Button
                type="text"
                size="small"
                danger
                icon={<DeleteOutlined />}
                onClick={() => handleDelete(dest.id, dest.name)}
              />
            </Tooltip>
          </div>
        );
      }

      default:
        return (
          <div key={dest.id} style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 8 }}>
            <Tag style={{ margin: 0 }}>{dest.schema || '?'}</Tag>
            <Text type="secondary">{dest.name}</Text>
            <Tooltip title="Full edit">
              <Button
                type="text"
                size="small"
                icon={<SettingOutlined />}
                onClick={() => {
                  setOpen(false);
                  navigate(`/routes/${route.id}/destinations/${dest.id}/edit`);
                }}
              />
            </Tooltip>
          </div>
        );
    }
  };

  const formatDestLabel = (dest) => {
    switch (dest.schema) {
      case 'SRT':
        return `SRT:${dest.schema_options?.localport || '?'}`;
      case 'UDP':
        return `UDP:${dest.schema_options?.host || dest.schema_options?.address || '?'}:${dest.schema_options?.port || '?'}`;
      default:
        return dest.schema || '?';
    }
  };

  const triggerLabel = () => {
    if (destinations.length === 0) return <span style={{ color: '#666' }}>—</span>;
    if (destinations.length <= 2) {
      return destinations.map(formatDestLabel).join(' · ');
    }
    return `${formatDestLabel(destinations[0])} (+${destinations.length - 1})`;
  };

  const popoverContent = (
    <div style={{ minWidth: 280 }}>
      {destinations.length === 0 ? (
        <Text type="secondary">No destinations configured</Text>
      ) : (
        destinations.map(renderDestinationRow)
      )}
      <Divider style={{ margin: '8px 0' }} />
      <Button
        type="dashed"
        size="small"
        icon={<PlusOutlined />}
        block
        onClick={() => {
          setOpen(false);
          navigate(`/routes/${route.id}/destinations/new/edit`);
        }}
      >
        Add Destination
      </Button>
    </div>
  );

  return (
    <Popover
      content={popoverContent}
      title={<Text strong>{route.name} — Destinations</Text>}
      trigger="click"
      open={open}
      onOpenChange={setOpen}
      placement="bottomLeft"
    >
      <span style={{ cursor: 'pointer', borderBottom: '1px dashed #666', paddingBottom: 1 }}>
        {triggerLabel()}
      </span>
    </Popover>
  );
};

export default OutputPopover;
