//! Bounded, volatile synthetic history and version1 protocol. No OS capture, persistence,
//! paths, SQL, network, key access, or production IPC endpoint exists in this slice.
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::io::{self, Read, Write};
use uuid::Uuid;

pub const MAX_FRAME: usize = 256 * 1024;
pub const MAX_TEXT: usize = 8192;
pub const MAX_QUERY: usize = 512;
pub const MAX_RESULTS: usize = 20;
pub const MAX_ITEMS: usize = 200;
pub const MAX_PINS: usize = 50;
pub const PREFIX: &str = "[CLIPHOARD_SYNTHETIC_V1] ";

/// A four-byte little-endian byte length, checked before allocating its UTF8 JSON body.
/// Clean EOF is distinct from any truncated header/body; oversized frames are not drained.
pub fn read_frame(reader: &mut impl Read) -> io::Result<Option<Vec<u8>>> {
    let mut header = [0_u8; 4];
    match reader.read(&mut header[..1])? {
        0 => return Ok(None),
        1 => (),
        _ => unreachable!(),
    }
    reader.read_exact(&mut header[1..])?;
    let count = u32::from_le_bytes(header) as usize;
    if count == 0 || count > MAX_FRAME {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid_frame_length",
        ));
    }
    let mut data = vec![0; count];
    reader.read_exact(&mut data)?;
    Ok(Some(data))
}
pub fn write_frame(writer: &mut impl Write, data: &[u8]) -> io::Result<()> {
    if data.is_empty() || data.len() > MAX_FRAME {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid_frame_length",
        ));
    }
    writer.write_all(&(data.len() as u32).to_le_bytes())?;
    writer.write_all(data)?;
    writer.flush()
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    version: u32,
    id: u32,
    command: Command,
}
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "camelCase", deny_unknown_fields)]
enum Command {
    Hello,
    CaptureSyntheticText {
        text: String,
    },
    List {
        limit: usize,
    },
    Search {
        query: String,
        limit: usize,
    },
    Select {
        #[serde(rename = "itemId")]
        item_id: Uuid,
    },
    Pin {
        #[serde(rename = "itemId")]
        item_id: Uuid,
        pinned: bool,
    },
    ClearSynthetic,
    Lock,
    Status,
}
#[derive(Clone, Serialize)]
pub struct Item {
    id: Uuid,
    text: String,
    pinned: bool,
}
pub struct Engine {
    items: Vec<Item>,
    capacity: usize,
    locked: bool,
}
impl Engine {
    pub fn new(capacity: usize) -> Result<Self, &'static str> {
        if capacity == 0 || capacity > MAX_ITEMS {
            return Err("invalid_capacity");
        }
        Ok(Self {
            items: Vec::new(),
            capacity,
            locked: false,
        })
    }
    /// No input bytes or parser diagnostics are echoed into errors.
    pub fn handle_bytes(&mut self, bytes: &[u8]) -> Value {
        if bytes.len() > MAX_FRAME {
            return error(0, "bad_request");
        }
        // serde's internally tagged unit variants can otherwise ignore extra fields.
        // Validate the exact operation key set before typed deserialization.
        let value: Value = match serde_json::from_slice(bytes) {
            Ok(value) => value,
            Err(_) => return error(0, "bad_request"),
        };
        let Some(command) = value.get("command").and_then(Value::as_object) else {
            return error(0, "bad_request");
        };
        let allowed: &[&str] = match command.get("op").and_then(Value::as_str) {
            Some("hello" | "status" | "lock" | "clearSynthetic") => &["op"],
            Some("captureSyntheticText") => &["op", "text"],
            Some("list") => &["op", "limit"],
            Some("search") => &["op", "query", "limit"],
            Some("select") => &["op", "itemId"],
            Some("pin") => &["op", "itemId", "pinned"],
            _ => return error(0, "bad_request"),
        };
        if command.keys().any(|key| !allowed.contains(&key.as_str())) {
            return error(0, "bad_request");
        }
        let request: Request = match serde_json::from_slice(bytes) {
            Ok(value) => value,
            Err(_) => return error(0, "bad_request"),
        };
        if request.version != 1 {
            return error(request.id, "unsupported_version");
        }
        match self.execute(request.command) {
            Ok(result) => json!({"version":1,"id":request.id,"ok":true,"result":result}),
            Err(code) => error(request.id, code),
        }
    }
    fn execute(&mut self, command: Command) -> Result<Value, &'static str> {
        if self.locked && !matches!(command, Command::Hello | Command::Status | Command::Lock) {
            return Err("locked");
        }
        match command {
            Command::Hello => Ok(
                json!({"protocol":1,"mode":"synthetic-only","maxFrame":MAX_FRAME,
                "maxText":MAX_TEXT,"maxQuery":MAX_QUERY,"maxResults":MAX_RESULTS,"productionIpc":"disabled_native_qualification_pending"}),
            ),
            Command::Status => Ok(
                json!({"locked":self.locked,"count":self.items.len(),"capacity":self.capacity,"persistent":false}),
            ),
            Command::CaptureSyntheticText { text } => {
                if !text.starts_with(PREFIX) {
                    return Err("fixture_required");
                }
                if text.len() <= PREFIX.len() || text.len() > MAX_TEXT || text.contains('\0') {
                    return Err("invalid_text");
                }
                let item = if let Some(index) = self.items.iter().position(|item| item.text == text)
                {
                    self.items.remove(index)
                } else {
                    if self.items.len() == self.capacity {
                        let Some(index) = self.items.iter().rposition(|item| !item.pinned) else {
                            return Err("history_full");
                        };
                        self.items.remove(index);
                    }
                    Item {
                        id: Uuid::new_v4(),
                        text,
                        pinned: false,
                    }
                };
                self.items.insert(0, item.clone());
                Ok(json!({"item":item}))
            }
            Command::List { limit } => self.results("", limit),
            Command::Search { query, limit } => {
                if query.len() > MAX_QUERY || query.contains('\0') {
                    return Err("invalid_query");
                }
                self.results(&query, limit)
            }
            Command::Select { item_id } => {
                let index = self
                    .items
                    .iter()
                    .position(|item| item.id == item_id)
                    .ok_or("not_found")?;
                let item = self.items.remove(index);
                let result = json!({"itemId":item.id,"text":item.text,"synthetic":true});
                self.items.insert(0, item);
                Ok(result)
            }
            Command::Pin { item_id, pinned } => {
                if pinned
                    && self.items.iter().filter(|item| item.pinned).count() >= MAX_PINS
                    && !self
                        .items
                        .iter()
                        .any(|item| item.id == item_id && item.pinned)
                {
                    return Err("pin_limit");
                }
                let item = self
                    .items
                    .iter_mut()
                    .find(|item| item.id == item_id)
                    .ok_or("not_found")?;
                item.pinned = pinned;
                Ok(json!({"item":item}))
            }
            Command::ClearSynthetic => {
                let count = self.items.len();
                self.items.clear();
                Ok(json!({"removed":count}))
            }
            Command::Lock => {
                // Volatile history is discarded, including pins. This is logical lock/purge,
                // not a claim of cryptographic zeroization of all allocator copies.
                self.items.clear();
                self.locked = true;
                Ok(json!({"locked":true,"count":0}))
            }
        }
    }
    fn results(&self, query: &str, limit: usize) -> Result<Value, &'static str> {
        if limit == 0 || limit > MAX_RESULTS {
            return Err("invalid_limit");
        }
        let query = query.to_lowercase();
        let mut items: Vec<&Item> = Vec::new();
        for item in self
            .items
            .iter()
            .filter(|item| item.text.to_lowercase().contains(&query))
            .take(limit)
        {
            items.push(item);
            // Account for JSON escaping and the largest request-id envelope, not
            // just UTF8 text bytes. A result limit is a maximum, not a page size.
            let envelope = json!({"version":1,"id":u32::MAX,"ok":true,"result":{"items":items}});
            if serde_json::to_vec(&envelope)
                .map_err(|_| "response_encoding")?
                .len()
                > MAX_FRAME
            {
                items.pop();
                break;
            }
        }
        Ok(json!({"items":items}))
    }
}
fn error(id: u32, code: &str) -> Value {
    json!({"version":1,"id":id,"ok":false,"error":code})
}
