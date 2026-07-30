import { Form, Input, Radio, Card, InputNumber, Switch, Select, Typography } from 'antd';
import PropTypes from 'prop-types';
import React from 'react';

const { Text } = Typography;

const SourceFields = ({ prefix, schemaName, interfaces, hideSchema }) => {
  return (
    <>
      {hideSchema ? (
        <Form.Item name={schemaName} hidden>
          <Input />
        </Form.Item>
      ) : (
        <Form.Item
          label="Schema"
          name={schemaName}
          required
        >
          <Radio.Group buttonStyle="solid">
            <Radio.Button value="SRT">SRT</Radio.Button>
            <Radio.Button value="UDP">UDP</Radio.Button>
            <Radio.Button value="RTMP">RTMP</Radio.Button>
          </Radio.Group>
        </Form.Item>
      )}

      {/* SRT specific options */}
      <Form.Item noStyle dependencies={[schemaName]}>
        {({ getFieldValue }) =>
          getFieldValue(schemaName) === 'SRT' && (
            <>
              <Form.Item
                label="Mode"
                name={[...prefix, 'mode']}
                required
                extra="The SRT connection mode. Caller: Actively initiates the connection to a Listener. Listener: Waits for an incoming connection from a Caller. Rendezvous: Both endpoints attempt to connect to each other simultaneously"
              >
                <Radio.Group buttonStyle="solid">
                  <Radio.Button value="caller">Caller</Radio.Button>
                  <Radio.Button value="listener">Listener</Radio.Button>
                  <Radio.Button value="rendezvous">Rendezvous</Radio.Button>
                </Radio.Group>
              </Form.Item>

              <Form.Item
                label="Local Address"
                name={[...prefix, 'localaddress']}
                extra="The address to bind when mode is listener or rendezvous. This property can be set by URI parameters."
              >
                <Input
                  placeholder="Enter address"
                  style={{ width: '100%' }}
                />
              </Form.Item>

              <Form.Item
                style={{ width: '150px' }}
                size="5"
                label="Local Port"
                name={[...prefix, 'localport']}
                required
                tooltip="Port number (1-65535)"
                rules={[
                  {
                    type: 'number',
                    min: 1,
                    max: 65535,
                    message: 'Port must be between 1 and 65535',
                  },
                ]}
              >
                <InputNumber style={{ width: '100%' }} placeholder="Enter port number" />
              </Form.Item>

              <Form.Item
                label="Latency"
                name={[...prefix, 'latency']}
                extra='The maximum accepted transmission latency.'
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
                name={[...prefix, 'streamid']}
                extra="Optional SRT Stream ID. Required by some services (e.g., Vidio/SRS) for stream identification."
              >
                <Input placeholder="e.g., #!::r=srt/1022501010AE4005" />
              </Form.Item>

              <Form.Item
                label="Auto Reconnect"
                name={[...prefix, 'auto-reconnect']}
                valuePropName="checked"
                extra="When enabled, the connection will automatically try to reconnect if disconnected. This applies only in caller mode and will be ignored for authentication failures."
              >
                <Switch />
              </Form.Item>

              <Form.Item
                label="Keep Listening"
                name={[...prefix, 'keep-listening']}
                valuePropName="checked"
                extra="When enabled, the server will continue waiting for clients to reconnect after disconnection. When disabled, the stream will end immediately when a client disconnects. A 'connection-removed' message will be sent on disconnection."
              >
                <Switch />
              </Form.Item>

              <Form.Item
                label="Authentication"
                name={[...prefix, 'authentication']}
                valuePropName="checked"
                extra="Enable SRT authentication"
              >
                <Switch />
              </Form.Item>

              <Form.Item noStyle dependencies={[[...prefix, 'authentication']]}>
                {({ getFieldValue }) =>
                  getFieldValue([...prefix, 'authentication']) && (
                    <>
                      <Form.Item
                        label="Passphrase"
                        name={[...prefix, 'passphrase']}
                        required
                        extra="Encryption passphrase for SRT authentication"
                      >
                        <Input.Password placeholder="Enter passphrase" />
                      </Form.Item>

                      <Form.Item
                        label="Key Length"
                        name={[...prefix, 'pbkeylen']}
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

              {/* Advanced SRT Settings */}
              <Card
                title="Advanced SRT Settings"
                size="small"
                style={{ marginTop: '16px', backgroundColor: '#1a1a1a' }}
                extra={<Text type="secondary" style={{ fontSize: '12px' }}>For problematic sources with packet loss</Text>}
              >
                <Text type="secondary" style={{ marginBottom: '16px', fontSize: '13px', display: 'block' }}>
                  These settings help recover from network jitter and packet loss. Only adjust if experiencing stream quality issues.
                </Text>

                <Form.Item
                  label="Receive Buffer (rcvbuf)"
                  name={[...prefix, 'rcvbuf']}
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
                  label="Loss Max TTL (lossmaxttl)"
                  name={[...prefix, 'lossmaxttl']}
                  tooltip="Tolerance for out-of-order packets"
                  extra="Number of packets to wait before declaring loss. Higher values help with jittery networks. Default: 0 (disabled)"
                >
                  <InputNumber
                    style={{ width: '150px' }}
                    min={0}
                    max={1000}
                    placeholder="e.g., 10"
                  />
                </Form.Item>

                <Form.Item
                  label="Overhead Bandwidth % (oheadbw)"
                  name={[...prefix, 'oheadbw']}
                  tooltip="Extra bandwidth for retransmissions"
                  extra="Percentage of extra bandwidth reserved for packet recovery. Default: 25%"
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
              </Card>
            </>
          )
        }
      </Form.Item>

      {/* UDP specific options */}
      <Form.Item noStyle dependencies={[schemaName]}>
        {({ getFieldValue }) =>
          getFieldValue(schemaName) === 'UDP' && (
            <>
              <Form.Item
                label="Address"
                name={[...prefix, 'address']}
                extra="Address to receive packets for. This is equivalent to the multicast-group property for now."
              >
                <Input
                  placeholder="Default: 0.0.0.0"
                  style={{ width: '100%' }}
                />
              </Form.Item>

              <Form.Item
                style={{ width: '150px' }}
                size="5"
                label="Port"
                name={[...prefix, 'port']}
                required
                tooltip="Port number (1-65535)"
                rules={[
                  {
                    type: 'number',
                    min: 1,
                    max: 65535,
                    message: 'Port must be between 1 and 65535',
                  },
                ]}
              >
                <InputNumber style={{ width: '100%' }} placeholder="Enter port number" />
              </Form.Item>
              <Form.Item
                style={{ width: '150px' }}
                label="Buffer Size"
                name={[...prefix, 'buffer-size']}
                tooltip="UDP buffer size in bytes"
              >
                <InputNumber
                  style={{ width: '100%' }}
                  placeholder="Default: 0 bytes"
                />
              </Form.Item>

              <Form.Item
                style={{ width: '150px' }}
                label="MTU"
                name={[...prefix, 'mtu']}
                tooltip="Maximum expected packet size. This directly defines the allocation size of the receive buffer pool."
              >
                <InputNumber
                  style={{ width: '100%' }}
                  placeholder="Default: 1492"
                />
              </Form.Item>

              <Form.Item
                label="Multicast Interface"
                name={[...prefix, 'multicast-iface']}
                extra="Network interface name for receiving multicast traffic"
              >
                <Select
                  allowClear
                  placeholder="Default"
                  options={[
                    { label: 'Default', value: '' },
                    ...interfaces
                      .filter(iface => iface.up)
                      .map(iface => ({
                        label: `${iface.name} (${iface.address || 'no IP'})`,
                        value: iface.name
                      }))
                  ]}
                />
              </Form.Item>
            </>
          )
        }
      </Form.Item>

      {/* RTMP/HTTP-FLV/HLS Source Options */}
      <Form.Item noStyle dependencies={[schemaName]}>
        {({ getFieldValue }) =>
          getFieldValue(schemaName) === 'RTMP' && (
            <>
              <Form.Item
                label="Stream URL"
                name={[...prefix, 'url']}
                required
                extra="Supports RTMP, HTTP-FLV, and HLS URLs. Examples: rtmp://server/live/key, http://server/stream.flv, http://server/stream.m3u8"
                rules={[{ required: true, message: 'Stream URL is required' }]}
              >
                <Input placeholder="rtmp://server:1935/live/stream_key" />
              </Form.Item>
            </>
          )
        }
      </Form.Item>
    </>
  );
};

SourceFields.propTypes = {
  prefix: PropTypes.arrayOf(PropTypes.string).isRequired,
  schemaName: PropTypes.oneOfType([
    PropTypes.string,
    PropTypes.arrayOf(PropTypes.string),
  ]).isRequired,
  interfaces: PropTypes.array.isRequired,
  hideSchema: PropTypes.bool,
};

SourceFields.defaultProps = {
  hideSchema: false,
};

export default SourceFields;
