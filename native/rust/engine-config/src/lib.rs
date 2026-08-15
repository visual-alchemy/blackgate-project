// Route configuration parsing — ported from native/src (C cJSON init contract)
//
// Elixir wire format (route_handler.ex send_initial_command):
//   Non-failover: {"route_id":.., "source":{...}, "sinks":[...]}
//   Failover:     {"type":"init", "route_id":.., "primary_source":{...},
//                  "secondary_source":{...}, "auto_join":bool, "sinks":[...]}
//
// Element objects: {"type":"srtsrc","uri":"srt://...?mode=..&latency=..", ...extra numeric props}
//                  {"type":"udpsink","host":"..","port":..}
//                  {"type":"sdisink","device-number":..,"video-mode":"..","width":..,"height":..,
//                   "framerate":"25/1","interlaced":bool}

use serde::Deserialize;
use std::collections::BTreeMap;

#[derive(Debug, Deserialize, Clone, Default, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum SourceProtocol {
    #[default]
    Srt,
    Udp,
}

#[derive(Debug, Deserialize, Clone, Default, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum SrtMode {
    #[default]
    Listener,
    Caller,
    Rendezvous,
}

impl SrtMode {
    pub fn as_str(&self) -> &'static str {
        match self {
            SrtMode::Listener => "listener",
            SrtMode::Caller => "caller",
            SrtMode::Rendezvous => "rendezvous",
        }
    }

    pub fn from_str_opt(s: &str) -> Option<Self> {
        match s {
            "listener" => Some(SrtMode::Listener),
            "caller" => Some(SrtMode::Caller),
            "rendezvous" => Some(SrtMode::Rendezvous),
            _ => None,
        }
    }
}

/// Property value passthrough — C set_element_properties applies every JSON
/// key (except "type") onto the element: bool→bool, number→int, string→string.
#[derive(Debug, Clone, PartialEq)]
pub enum PropValue {
    Bool(bool),
    Int(i64),
    Double(f64),
    Str(String),
}

impl PropValue {
    pub fn from_json(v: &serde_json::Value) -> Option<Self> {
        match v {
            serde_json::Value::Bool(b) => Some(PropValue::Bool(*b)),
            serde_json::Value::Number(n) => {
                if let Some(i) = n.as_i64() {
                    Some(PropValue::Int(i))
                } else {
                    n.as_f64().map(PropValue::Double)
                }
            }
            serde_json::Value::String(s) => Some(PropValue::Str(s.clone())),
            _ => None,
        }
    }
}

/// Parsed source config — from the GStreamer element URI + extra properties.
#[derive(Debug, Clone)]
pub struct SourceConfig {
    pub element_type: String, // "srtsrc" | "udpsrc"
    pub protocol: SourceProtocol,
    pub host: String,
    pub port: u16,
    pub latency_ms: u32,
    pub mode: SrtMode,
    pub passphrase: Option<String>,
    pub streamid: Option<String>,
    /// Remaining JSON props applied verbatim onto the element (C parity).
    pub extra_props: BTreeMap<String, PropValue>,
}

#[derive(Debug, Deserialize, Clone, Default, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum SinkProtocol {
    #[default]
    Srt,
    Udp,
    Sdi,
}

/// SDI sink config — mirrors the C JSON keys in add_sink_to_pipeline(sdisink).
#[derive(Debug, Clone)]
pub struct SdiConfig {
    pub device_number: i32,     // "device-number", default 0
    pub video_mode: String,     // "video-mode", default "1080p25"
    pub interlaced: bool,       // "interlaced", default false
    pub width: i32,             // default 1920
    pub height: i32,            // default 1080
    pub framerate: String,      // default "25/1"
}

impl Default for SdiConfig {
    fn default() -> Self {
        Self {
            device_number: 0,
            video_mode: "1080p25".to_string(),
            interlaced: false,
            width: 1920,
            height: 1080,
            framerate: "25/1".to_string(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct SinkConfig {
    pub element_type: String, // "srtsink" | "udpsink" | "sdisink"
    pub protocol: SinkProtocol,
    pub uri: Option<String>,
    pub host: Option<String>,
    pub port: Option<u16>,
    pub latency_ms: u32,
    pub mode: Option<SrtMode>,
    pub passphrase: Option<String>,
    pub streamid: Option<String>,
    pub sdi: Option<SdiConfig>,
    /// Remaining JSON props applied verbatim onto the element (C parity).
    pub extra_props: BTreeMap<String, PropValue>,
}

#[derive(Debug, Clone)]
pub struct SecondaryConfig {
    pub source: SourceConfig,
    pub auto_join: bool,
}

/// Full route config — MULTIPLE sinks (C parity: sinks array fan-out).
#[derive(Debug, Clone)]
pub struct RouteConfig {
    pub route_id: String,
    pub source: SourceConfig,
    pub sinks: Vec<SinkConfig>,
    pub secondary: Option<SecondaryConfig>,
    pub auto_join: bool,
}

impl RouteConfig {
    pub fn has_sdi_sink(&self) -> bool {
        self.sinks.iter().any(|s| s.protocol == SinkProtocol::Sdi)
    }
}

// ── Elixir wire-format structs ───────────────────────────────────────────

#[derive(Debug, Deserialize)]
struct ElixirInit {
    #[serde(default)]
    route_id: Option<String>,
    #[serde(alias = "primary_source")]
    source: Option<serde_json::Value>,
    #[serde(alias = "secondary_source")]
    secondary_source: Option<serde_json::Value>,
    #[serde(default = "default_true")]
    auto_join: bool,
    #[serde(default)]
    sinks: Option<Vec<serde_json::Value>>,
}

fn default_true() -> bool {
    true
}

// ── URI helpers ──────────────────────────────────────────────────────────

fn parse_uri_host_port(uri: &str) -> Result<(String, u16), String> {
    let without_scheme = uri
        .split("://")
        .nth(1)
        .ok_or_else(|| format!("no scheme in uri: {}", uri))?;
    let host_port = without_scheme.split('?').next().unwrap_or(without_scheme);
    // IPv6 bracket form: [::1]:7000 — split after ']'
    let (host, port_str) = if let Some(rest) = host_port.strip_prefix('[') {
        let close = rest
            .find(']')
            .ok_or_else(|| format!("bad ipv6 uri: {}", uri))?;
        let h = &rest[..close];
        let p = rest[close + 1..].strip_prefix(':').ok_or_else(|| format!("no port in uri: {}", uri))?;
        (h.to_string(), p.to_string())
    } else {
        let mut parts = host_port.rsplitn(2, ':');
        let port_str = parts
            .next()
            .ok_or_else(|| format!("no port in uri: {}", uri))?;
        (parts.next().unwrap_or("0.0.0.0").to_string(), port_str.to_string())
    };
    let port: u16 = port_str
        .parse()
        .map_err(|_| format!("bad port in uri: {}", uri))?;
    Ok((host, port))
}

/// Percent-decode a query parameter value (C URI parser handles %-encoding;
/// Elixir double-decodes with URI.decode so passphrases may contain %3A etc).
fn percent_decode(v: &str) -> String {
    let bytes = v.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() + 1 && i + 2 <= bytes.len() - 1 + 1 {
            let hex = &v[i + 1..(i + 3).min(v.len())];
            if hex.len() == 2 {
                if let Ok(b) = u8::from_str_radix(hex, 16) {
                    out.push(b);
                    i += 3;
                    continue;
                }
            }
            out.push(bytes[i]);
            i += 1;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn extract_query_param(uri: &str, key: &str) -> Option<String> {
    let query = uri.split('?').nth(1)?;
    for pair in query.split('&') {
        let mut kv = pair.splitn(2, '=');
        let k = kv.next()?;
        if k == key {
            return Some(percent_decode(kv.next().unwrap_or("")));
        }
    }
    None
}

// ── Element parsers (C: make_source / add_sink_to_pipeline JSON contract) ─

const SOURCE_SKIP_KEYS: &[&str] = &["type", "uri", "mode", "passphrase", "streamid", "latency"];
const SINK_SKIP_KEYS: &[&str] = &[
    "type", "uri", "mode", "passphrase", "streamid", "latency", "host", "port", "address",
    "device-number", "video-mode", "interlaced", "width", "height", "framerate",
];

fn extra_props(obj: &serde_json::Value, skip: &[&str]) -> BTreeMap<String, PropValue> {
    let mut out = BTreeMap::new();
    if let serde_json::Value::Object(map) = obj {
        for (k, v) in map {
            if skip.contains(&k.as_str()) {
                continue;
            }
            if let Some(pv) = PropValue::from_json(v) {
                out.insert(k.clone(), pv);
            }
        }
    }
    out
}

fn parse_elixir_source(el: &serde_json::Value) -> Result<SourceConfig, String> {
    let obj = el
        .as_object()
        .ok_or_else(|| "source must be an object".to_string())?;
    let element_type = obj
        .get("type")
        .and_then(|v| v.as_str())
        .ok_or("Invalid source config: missing or invalid 'type'")?
        .to_string();

    let uri = obj.get("uri").and_then(|v| v.as_str());
    let (host, port) = match uri {
        Some(u) => parse_uri_host_port(u)?,
        None => (
            obj.get("address")
                .and_then(|v| v.as_str())
                .unwrap_or("0.0.0.0")
                .to_string(),
            obj.get("port")
                .and_then(|v| v.as_u64())
                .and_then(|p| u16::try_from(p).ok())
                .ok_or("udpsrc: missing port")?,
        ),
    };

    let protocol = if element_type.contains("srt") {
        SourceProtocol::Srt
    } else {
        SourceProtocol::Udp
    };

    let mode_str = obj
        .get("mode")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .or_else(|| uri.and_then(|u| extract_query_param(u, "mode")));
    let mode = match mode_str.as_deref() {
        Some("caller") => SrtMode::Caller,
        Some("rendezvous") => SrtMode::Rendezvous,
        _ => SrtMode::Listener,
    };

    let latency = obj
        .get("latency")
        .and_then(|v| v.as_u64())
        .map(|v| v as u32)
        .or_else(|| {
            uri.and_then(|u| extract_query_param(u, "latency"))
                .and_then(|v| v.parse::<u32>().ok())
        });

    Ok(SourceConfig {
        element_type: element_type.clone(),
        protocol,
        host,
        port,
        latency_ms: latency.unwrap_or(120),
        mode,
        passphrase: obj
            .get("passphrase")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .or_else(|| uri.and_then(|u| extract_query_param(u, "passphrase"))),
        streamid: obj
            .get("streamid")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .or_else(|| uri.and_then(|u| extract_query_param(u, "streamid"))),
        extra_props: extra_props(el, SOURCE_SKIP_KEYS),
    })
}

fn parse_elixir_sink(el: &serde_json::Value) -> Result<SinkConfig, String> {
    let obj = el
        .as_object()
        .ok_or_else(|| "sink must be an object".to_string())?;
    let element_type = obj
        .get("type")
        .and_then(|v| v.as_str())
        .ok_or("Invalid sink format: missing or invalid 'type'")?
        .to_string();

    let uri = obj.get("uri").and_then(|v| v.as_str()).map(|s| s.to_string());

    let protocol = if element_type.contains("sdi") {
        SinkProtocol::Sdi
    } else if element_type.contains("udp") {
        SinkProtocol::Udp
    } else {
        SinkProtocol::Srt
    };

    let (host, port) = match uri.as_deref() {
        Some(u) => {
            let (h, p) = parse_uri_host_port(u)?;
            (Some(h), Some(p))
        }
        None => (
            obj.get("host")
                .or_else(|| obj.get("address"))
                .and_then(|v| v.as_str())
                .map(|s| s.to_string()),
            obj.get("port")
                .and_then(|v| v.as_u64())
                .and_then(|p| u16::try_from(p).ok()),
        ),
    };

    let mode_str = obj
        .get("mode")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .or_else(|| uri.as_deref().and_then(|u| extract_query_param(u, "mode")));
    let mode = mode_str.as_deref().and_then(SrtMode::from_str_opt);

    let latency = obj
        .get("latency")
        .and_then(|v| v.as_u64())
        .map(|v| v as u32)
        .or_else(|| {
            uri.as_deref()
                .and_then(|u| extract_query_param(u, "latency"))
                .and_then(|v| v.parse::<u32>().ok())
        });

    let sdi = if protocol == SinkProtocol::Sdi {
        Some(SdiConfig {
            device_number: obj
                .get("device-number")
                .and_then(|v| v.as_i64())
                .map(|v| v as i32)
                .unwrap_or(0),
            video_mode: obj
                .get("video-mode")
                .and_then(|v| v.as_str())
                .unwrap_or("1080p25")
                .to_string(),
            interlaced: obj
                .get("interlaced")
                .and_then(|v| v.as_bool())
                .unwrap_or(false),
            width: obj
                .get("width")
                .and_then(|v| v.as_i64())
                .map(|v| v as i32)
                .unwrap_or(1920),
            height: obj
                .get("height")
                .and_then(|v| v.as_i64())
                .map(|v| v as i32)
                .unwrap_or(1080),
            framerate: obj
                .get("framerate")
                .and_then(|v| v.as_str())
                .unwrap_or("25/1")
                .to_string(),
        })
    } else {
        None
    };

    let passphrase = obj
        .get("passphrase")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .or_else(|| uri.as_deref().and_then(|u| extract_query_param(u, "passphrase")));
    let streamid = obj
        .get("streamid")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .or_else(|| uri.as_deref().and_then(|u| extract_query_param(u, "streamid")));

    Ok(SinkConfig {
        element_type,
        protocol,
        uri,
        host,
        port,
        latency_ms: latency.unwrap_or(120),
        mode,
        passphrase,
        streamid,
        sdi,
        extra_props: extra_props(el, SINK_SKIP_KEYS),
    })
}

// ── Simple (test) format ─────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
struct SimpleInit {
    route_id: String,
    source: serde_json::Value,
    #[serde(default)]
    sinks: Option<Vec<serde_json::Value>>,
    #[serde(default)]
    sink: Option<serde_json::Value>,
    secondary: Option<serde_json::Value>,
    #[serde(default = "default_true")]
    auto_join: bool,
}

impl RouteConfig {
    /// Parse the Elixir init JSON (both failover and non-failover shapes).
    pub fn from_elixir_json(json: &str) -> Result<Self, String> {
        let init: ElixirInit =
            serde_json::from_str(json).map_err(|e| format!("invalid init JSON: {}", e))?;

        let source_val = init
            .source
            .as_ref()
            .ok_or("missing primary_source/source in init JSON")?;
        let source = parse_elixir_source(source_val)?;

        // C requires the sinks array to exist; empty array is allowed
        // (pipeline then has no sink branches; tee stays allow-not-linked).
        let sinks_val = init
            .sinks
            .as_ref()
            .ok_or("Invalid JSON format: missing source object or 'sinks' array")?;
        let mut sinks = Vec::with_capacity(sinks_val.len());
        for s in sinks_val {
            sinks.push(parse_elixir_sink(s)?);
        }

        let secondary = init
            .secondary_source
            .as_ref()
            .map(|sec| -> Result<SecondaryConfig, String> {
                Ok(SecondaryConfig {
                    source: parse_elixir_source(sec)?,
                    auto_join: init.auto_join,
                })
            })
            .transpose()?;

        let route_id = init.route_id.unwrap_or_else(|| "unknown".to_string());
        Ok(RouteConfig {
            route_id,
            source,
            sinks,
            secondary,
            auto_join: init.auto_join,
        })
    }

    /// Parse the simple test format (source + sink(s) in typed shape).
    pub fn from_simple_json(json: &str) -> Result<Self, String> {
        let init: SimpleInit =
            serde_json::from_str(json).map_err(|e| format!("invalid simple JSON: {}", e))?;
        let source = parse_elixir_source(&init.source)?;

        let mut sinks = Vec::new();
        if let Some(list) = &init.sinks {
            for s in list {
                sinks.push(parse_elixir_sink(s)?);
            }
        }
        if let Some(single) = &init.sink {
            sinks.push(parse_elixir_sink(single)?);
        }

        let secondary = init
            .secondary
            .as_ref()
            .map(|sec| -> Result<SecondaryConfig, String> {
                let auto_join = sec
                    .get("auto_join")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(init.auto_join);
                let src = sec
                    .get("source")
                    .cloned()
                    .ok_or("secondary missing source")?;
                Ok(SecondaryConfig {
                    source: parse_elixir_source(&src)?,
                    auto_join,
                })
            })
            .transpose()?;

        Ok(Self {
            route_id: init.route_id,
            source,
            sinks,
            secondary,
            auto_join: init.auto_join,
        })
    }

    /// Auto-detect format and parse.
    pub fn from_json(json: &str) -> Result<Self, String> {
        if json.contains("primary_source") || json.contains("secondary_source") || json.contains("\"sinks\"") {
            Self::from_elixir_json(json)
        } else {
            Self::from_simple_json(json)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ELIXIR_MULTI: &str = r#"{
        "type": "init",
        "route_id": "route-1",
        "primary_source": {"type": "srtsrc", "uri": "srt://0.0.0.0:7001?mode=listener&latency=2000"},
        "secondary_source": {"type": "srtsrc", "uri": "srt://0.0.0.0:7002?mode=listener"},
        "auto_join": true,
        "sinks": [
            {"type": "srtsink", "uri": "srt://10.0.0.5:7005?mode=caller&latency=3000", "rcvbuf": 16000000},
            {"type": "udpsink", "host": "239.1.1.1", "port": 5000, "ttl-multicast": 3},
            {"type": "sdisink", "device-number": 1, "video-mode": "1080i50", "width": 1920, "height": 1080, "framerate": "25/1", "interlaced": true}
        ]
    }"#;

    #[test]
    fn parses_all_sinks_not_just_first() {
        let cfg = RouteConfig::from_json(ELIXIR_MULTI).unwrap();
        assert_eq!(cfg.sinks.len(), 3);
        assert_eq!(cfg.sinks[0].protocol, SinkProtocol::Srt);
        assert_eq!(cfg.sinks[1].protocol, SinkProtocol::Udp);
        assert_eq!(cfg.sinks[1].host.as_deref(), Some("239.1.1.1"));
        assert_eq!(cfg.sinks[1].port, Some(5000));
        assert_eq!(cfg.sinks[2].protocol, SinkProtocol::Sdi);
        let sdi = cfg.sinks[2].sdi.as_ref().unwrap();
        assert_eq!(sdi.device_number, 1);
        assert_eq!(sdi.video_mode, "1080i50");
        assert!(sdi.interlaced);
    }

    #[test]
    fn sdi_detection_drives_do_timestamp() {
        let cfg = RouteConfig::from_json(ELIXIR_MULTI).unwrap();
        assert!(cfg.has_sdi_sink());
        let no_sdi = RouteConfig::from_json(
            r#"{"route_id":"r","source":{"type":"srtsrc","uri":"srt://0.0.0.0:7001"},"sinks":[{"type":"srtsink","uri":"srt://10.0.0.5:7005"}]}"#,
        )
        .unwrap();
        assert!(!no_sdi.has_sdi_sink());
    }

    #[test]
    fn auto_join_defaults_true() {
        // Elixir: Map.get(route, "auto_join", true) — absence means TRUE
        let cfg = RouteConfig::from_json(
            r#"{"route_id":"r","source":{"type":"srtsrc","uri":"srt://0.0.0.0:7001"},"secondary_source":{"type":"srtsrc","uri":"srt://0.0.0.0:7002"},"sinks":[{"type":"srtsink","uri":"srt://10.0.0.5:7005"}]}"#,
        )
        .unwrap();
        assert_eq!(cfg.auto_join, true);
        let sec = cfg.secondary.unwrap();
        assert!(sec.auto_join);

        let off = RouteConfig::from_json(
            r#"{"route_id":"r","source":{"type":"srtsrc","uri":"srt://0.0.0.0:7001"},"secondary_source":{"type":"srtsrc","uri":"srt://0.0.0.0:7002"},"auto_join":false,"sinks":[]}"#,
        )
        .unwrap();
        assert_eq!(off.auto_join, false);
    }

    #[test]
    fn sdi_defaults_match_c() {
        let cfg = RouteConfig::from_json(
            r#"{"route_id":"r","source":{"type":"srtsrc","uri":"srt://0.0.0.0:7001"},"sinks":[{"type":"sdisink"}]}"#,
        )
        .unwrap();
        let sdi = cfg.sinks[0].sdi.as_ref().unwrap();
        assert_eq!(sdi.device_number, 0);
        assert_eq!(sdi.video_mode, "1080p25");
        assert_eq!(sdi.width, 1920);
        assert_eq!(sdi.height, 1080);
        assert_eq!(sdi.framerate, "25/1");
        assert!(!sdi.interlaced);
    }

    #[test]
    fn extra_props_captured_for_element_passthrough() {
        let cfg = RouteConfig::from_json(ELIXIR_MULTI).unwrap();
        let s0 = &cfg.sinks[0];
        assert_eq!(
            s0.extra_props.get("rcvbuf"),
            Some(&PropValue::Int(16000000))
        );
        let s1 = &cfg.sinks[1];
        assert_eq!(
            s1.extra_props.get("ttl-multicast"),
            Some(&PropValue::Int(3))
        );
        // parsed keys must NOT leak into extra_props
        assert!(s0.extra_props.get("type").is_none());
        assert!(s0.extra_props.get("uri").is_none());
        assert!(s0.extra_props.get("latency").is_none());
    }

    #[test]
    fn source_extra_numeric_props_passthrough() {
        let cfg = RouteConfig::from_json(
            r#"{"route_id":"r","source":{"type":"srtsrc","uri":"srt://0.0.0.0:7001?mode=listener","oheadbw":50,"auto-reconnect":true,"keep-listening":false},"sinks":[]}"#,
        )
        .unwrap();
        assert_eq!(cfg.source.extra_props.get("oheadbw"), Some(&PropValue::Int(50)));
        assert_eq!(
            cfg.source.extra_props.get("auto-reconnect"),
            Some(&PropValue::Bool(true))
        );
        assert_eq!(
            cfg.source.extra_props.get("keep-listening"),
            Some(&PropValue::Bool(false))
        );
    }

    #[test]
    fn percent_decodes_passphrase_in_uri() {
        let cfg = RouteConfig::from_json(
            r#"{"route_id":"r","source":{"type":"srtsrc","uri":"srt://0.0.0.0:7001?passphrase=abc%3Adef%2Fghi"},"sinks":[]}"#,
        )
        .unwrap();
        assert_eq!(cfg.source.passphrase.as_deref(), Some("abc:def/ghi"));
    }

    #[test]
    fn empty_sinks_allowed_no_dummy() {
        let cfg = RouteConfig::from_json(
            r#"{"route_id":"r","source":{"type":"srtsrc","uri":"srt://0.0.0.0:7001"},"sinks":[]}"#,
        )
        .unwrap();
        assert!(cfg.sinks.is_empty());
    }

    #[test]
    fn non_failover_shape_has_no_type_key() {
        // Elixir non-failover payload: {"route_id","source","sinks"} — no "type":"init"
        let cfg = RouteConfig::from_json(
            r#"{"route_id":"r9","source":{"type":"srtsrc","uri":"srt://0.0.0.0:7010"},"sinks":[{"type":"srtsink","uri":"srt://127.0.0.1:7011?mode=listener"}]}"#,
        )
        .unwrap();
        assert_eq!(cfg.route_id, "r9");
        assert!(cfg.secondary.is_none());
        assert_eq!(cfg.sinks.len(), 1);
        assert_eq!(cfg.sinks[0].mode, Some(SrtMode::Listener));
    }
}
