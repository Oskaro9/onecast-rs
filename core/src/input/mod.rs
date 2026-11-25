use bytes::{BufMut, Bytes, BytesMut};

/// Xbox gamepad button bitmask flags.
pub mod buttons {
    pub const NEXUS: u16 = 1 << 1;
    pub const MENU: u16 = 1 << 2;
    pub const VIEW: u16 = 1 << 3;
    pub const A: u16 = 1 << 4;
    pub const B: u16 = 1 << 5;
    pub const X: u16 = 1 << 6;
    pub const Y: u16 = 1 << 7;
    pub const DPAD_UP: u16 = 1 << 8;
    pub const DPAD_DOWN: u16 = 1 << 9;
    pub const DPAD_LEFT: u16 = 1 << 10;
    pub const DPAD_RIGHT: u16 = 1 << 11;
    pub const LEFT_SHOULDER: u16 = 1 << 12;
    pub const RIGHT_SHOULDER: u16 = 1 << 13;
    pub const LEFT_THUMB: u16 = 1 << 14;
    pub const RIGHT_THUMB: u16 = 1 << 15;
}

/// Snapshot of a physical controller state passed from Swift `GameController`.
#[derive(Debug, Clone, Copy, Default, PartialEq, uniffi::Record)]
pub struct ControllerState {
    pub buttons: u16,
    pub left_trigger: f32,
    pub right_trigger: f32,
    pub left_thumb_x: f32,
    pub left_thumb_y: f32,
    pub right_thumb_x: f32,
    pub right_thumb_y: f32,
}

/// Encodes Xbox Remote Play `input` data channel binary packets.
pub struct InputEncoder {
    sequence: u32,
    buf: BytesMut,
}

impl Default for InputEncoder {
    fn default() -> Self {
        Self::new()
    }
}

impl InputEncoder {
    pub fn new() -> Self {
        Self {
            sequence: 0,
            buf: BytesMut::with_capacity(64),
        }
    }

    /// Encodes the initial `ClientMetadata` report (`0x08`) sent when the `input` channel opens (15 bytes).
    pub fn encode_client_metadata(&mut self, timestamp_ms: f64) -> Bytes {
        self.sequence = self.sequence.wrapping_add(1);
        self.buf.clear();

        // 14-byte header: report_type (u16 LE = 0x08), sequence (u32 LE), timestamp_ms (f64 LE)
        self.buf.put_u16_le(0x08);
        self.buf.put_u32_le(self.sequence);
        self.buf.put_f64_le(timestamp_ms);
        // max_touch_points (u8 = 1)
        self.buf.put_u8(1);

        self.buf.clone().freeze()
    }

    /// Encodes a gamepad report frame (`0x02` = Gamepad) into the 14-byte header + 1-byte count + 23-byte frame layout (38 bytes).
    pub fn encode_gamepad(&mut self, state: &ControllerState, timestamp_ms: f64) -> Bytes {
        self.sequence = self.sequence.wrapping_add(1);
        self.buf.clear();

        // 14-byte packet header:
        // report_type (u16 LE = 0x02), sequence (u32 LE), timestamp_ms (f64 LE)
        self.buf.put_u16_le(0x02);
        self.buf.put_u32_le(self.sequence);
        self.buf.put_f64_le(timestamp_ms);
        // frame_count (u8 = 1)
        self.buf.put_u8(1);

        // 23-byte gamepad frame:
        // index (u8), buttons (u16 LE), sticks (4x i16 LE), triggers (2x u16 LE), physical/virtual physicality (2x u32 LE)
        self.buf.put_u8(0x00);
        self.buf.put_u16_le(state.buttons);
        self.buf.put_i16_le(float_to_i16(state.left_thumb_x));
        self.buf.put_i16_le(float_to_i16(state.left_thumb_y));
        self.buf.put_i16_le(float_to_i16(state.right_thumb_x));
        self.buf.put_i16_le(float_to_i16(state.right_thumb_y));
        self.buf.put_u16_le(float_to_u16(state.left_trigger));
        self.buf.put_u16_le(float_to_u16(state.right_trigger));
        self.buf.put_u32_le(0);
        self.buf.put_u32_le(0);

        self.buf.clone().freeze()
    }
}

#[inline]
fn float_to_i16(v: f32) -> i16 {
    let clamped = v.clamp(-1.0, 1.0);
    (clamped * i16::MAX as f32).round() as i16
}

#[inline]
fn float_to_u16(v: f32) -> u16 {
    let clamped = v.clamp(0.0, 1.0);
    (clamped * u16::MAX as f32).round() as u16
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_gamepad_packet_layout() {
        let mut enc = InputEncoder::new();
        let state = ControllerState {
            buttons: buttons::A | buttons::RIGHT_SHOULDER,
            left_trigger: 0.5,
            right_trigger: 1.0,
            left_thumb_x: -1.0,
            left_thumb_y: 1.0,
            right_thumb_x: 0.0,
            right_thumb_y: 0.0,
        };

        let pkt = enc.encode_gamepad(&state, 123456.0);
        // 14-byte header + 1-byte count + 23-byte gamepad frame = 38 bytes
        assert_eq!(pkt.len(), 38);
        // report_type = 0x02 (u16 LE)
        assert_eq!(&pkt[0..2], &[2, 0]);
        // sequence = 1 (u32 LE)
        assert_eq!(&pkt[2..6], &[1, 0, 0, 0]);
        // frame_count = 1
        assert_eq!(pkt[14], 1);
    }
}
