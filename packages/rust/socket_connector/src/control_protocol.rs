use std::str::FromStr;

#[repr(C)]
enum ControlMessage {
    Connect(String, String),
}

#[repr(C)]
struct ControlMessageParseError {
    reason: String,
}

impl FromStr for ControlMessage {
    type Err = ControlMessageParseError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.split_once(":") {
            Some(parts) => {
                let (cmd, body) = parts;
                match cmd {
                    "connect" => match body.split_once(":") {
                        None => Err(ControlMessageParseError {
                            reason: "No ':' delimiter found".to_string(),
                        }),
                        Some(parts) => {
                            let (key, iv) = parts;
                            Ok(ControlMessage::Connect(key.to_string(), iv.to_string()))
                        }
                    },
                    x => Err(ControlMessageParseError {
                        reason: format!("Unknown command: {}", x),
                    }),
                }
            }
            None => Err(ControlMessageParseError {
                reason: "No ':' delimiter found".to_string(),
            }),
        }
    }
}

impl ToString for ControlMessage {
    fn to_string(&self) -> String {
        match self {
            ControlMessage::Connect(key, iv) => format!("connect:{}:{}", key, iv),
        }
    }
}
