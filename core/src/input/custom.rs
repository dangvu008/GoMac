//! Custom Input Method
//!
//! Configurable key mappings that allow users to override
//! default Telex/VNI key assignments from the settings UI.
//!
//! Usage:
//! - `Custom::from_telex()` creates a custom method with Telex defaults
//! - `Custom::from_vni()` creates a custom method with VNI defaults
//! - `set_mark_key(mark_id, keycode)` overrides a specific mark key
//! - Implements `Method` trait so engine uses it transparently

use super::{
    Method, ToneType, BREVE_TARGETS, CIRCUMFLEX_TARGETS, HORN_TARGETS_TELEX, HORN_TARGETS_VNI,
};
use crate::data::keys;

/// Maximum number of tone key entries
const MAX_TONES: usize = 4;

/// Maximum number of Shift+Key → Character mappings
const MAX_SHIFT_KEYS: usize = 32;

/// A single Shift+Key mapping: keycode → Unicode character
#[derive(Clone, Copy)]
struct ShiftKeyEntry {
    key: u16,
    output_char: u32, // Unicode codepoint
}

/// A single tone mapping: keycode → (ToneType, targets)
#[derive(Clone, Copy)]
struct ToneEntry {
    key: u16,
    tone_type: ToneType,
    /// Index into TONE_TARGET_SETS for the target vowels
    target_set: u8,
}

/// Pre-defined target sets (static, no heap allocation)
/// 0 = [A], 1 = [E], 2 = [O], 3 = HORN_TARGETS_TELEX, 4 = CIRCUMFLEX_TARGETS
/// 5 = HORN_TARGETS_VNI, 6 = BREVE_TARGETS
const TARGET_SET_A: u8 = 0;
const TARGET_SET_E: u8 = 1;
const TARGET_SET_O: u8 = 2;
const TARGET_SET_HORN_TELEX: u8 = 3;
const TARGET_SET_CIRCUMFLEX: u8 = 4;
const TARGET_SET_HORN_VNI: u8 = 5;
const TARGET_SET_BREVE: u8 = 6;

fn get_target_set(id: u8) -> &'static [u16] {
    match id {
        TARGET_SET_A => &[keys::A],
        TARGET_SET_E => &[keys::E],
        TARGET_SET_O => &[keys::O],
        TARGET_SET_HORN_TELEX => HORN_TARGETS_TELEX,
        TARGET_SET_CIRCUMFLEX => CIRCUMFLEX_TARGETS,
        TARGET_SET_HORN_VNI => HORN_TARGETS_VNI,
        TARGET_SET_BREVE => BREVE_TARGETS,
        _ => &[],
    }
}

/// Configurable input method with user-overridable key mappings.
///
/// All data is stack-allocated (fixed arrays, no Vec/HashMap).
/// Thread-safe via Mutex wrapper in parent module.
#[derive(Clone)]
pub struct Custom {
    /// Mark keys: index 0-4 → sắc(1), huyền(2), hỏi(3), ngã(4), nặng(5)
    /// Value = keycode that triggers this mark
    mark_keys: [u16; 5],

    /// Tone entries (up to MAX_TONES)
    tone_entries: [Option<ToneEntry>; MAX_TONES],

    /// Stroke key (d → đ)
    stroke_key: u16,

    /// Remove diacritics key (z for Telex, 0 for VNI)
    remove_key: u16,

    /// Shift+Key → Character mappings (up to MAX_SHIFT_KEYS)
    /// Example: Shift+A → Ă (0x0102)
    shift_keys: [Option<ShiftKeyEntry>; MAX_SHIFT_KEYS],
}

impl Custom {
    /// Create custom method with Telex defaults
    pub fn from_telex() -> Self {
        Self {
            mark_keys: [keys::S, keys::F, keys::R, keys::X, keys::J],
            tone_entries: [
                Some(ToneEntry {
                    key: keys::A,
                    tone_type: ToneType::Circumflex,
                    target_set: TARGET_SET_A,
                }),
                Some(ToneEntry {
                    key: keys::E,
                    tone_type: ToneType::Circumflex,
                    target_set: TARGET_SET_E,
                }),
                Some(ToneEntry {
                    key: keys::O,
                    tone_type: ToneType::Circumflex,
                    target_set: TARGET_SET_O,
                }),
                Some(ToneEntry {
                    key: keys::W,
                    tone_type: ToneType::Horn,
                    target_set: TARGET_SET_HORN_TELEX,
                }),
            ],
            stroke_key: keys::D,
            remove_key: keys::Z,
            shift_keys: [None; MAX_SHIFT_KEYS],
        }
    }

    /// Create custom method with VNI defaults
    pub fn from_vni() -> Self {
        Self {
            mark_keys: [keys::N1, keys::N2, keys::N3, keys::N4, keys::N5],
            tone_entries: [
                Some(ToneEntry {
                    key: keys::N6,
                    tone_type: ToneType::Circumflex,
                    target_set: TARGET_SET_CIRCUMFLEX,
                }),
                Some(ToneEntry {
                    key: keys::N7,
                    tone_type: ToneType::Horn,
                    target_set: TARGET_SET_HORN_VNI,
                }),
                Some(ToneEntry {
                    key: keys::N8,
                    tone_type: ToneType::Breve,
                    target_set: TARGET_SET_BREVE,
                }),
                None,
            ],
            stroke_key: keys::N9,
            remove_key: keys::N0,
            shift_keys: [None; MAX_SHIFT_KEYS],
        }
    }

    /// Set a custom mark key
    /// mark_id: 1=sắc, 2=huyền, 3=hỏi, 4=ngã, 5=nặng
    pub fn set_mark_key(&mut self, mark_id: u8, keycode: u16) {
        if (1..=5).contains(&mark_id) {
            self.mark_keys[(mark_id - 1) as usize] = keycode;
        }
    }

    /// Set a custom tone key
    /// tone_type: 0=Circumflex, 1=Horn, 2=Breve
    /// target_set: which vowels this tone applies to
    pub fn set_tone_key(&mut self, slot: usize, keycode: u16, tone_type: u8, target_set: u8) {
        if slot < MAX_TONES {
            let tt = match tone_type {
                0 => ToneType::Circumflex,
                1 => ToneType::Horn,
                2 => ToneType::Breve,
                _ => return,
            };
            self.tone_entries[slot] = Some(ToneEntry {
                key: keycode,
                tone_type: tt,
                target_set,
            });
        }
    }

    /// Set a custom stroke key (d → đ)
    pub fn set_stroke_key(&mut self, keycode: u16) {
        self.stroke_key = keycode;
    }

    /// Set a custom remove key (remove diacritics)
    pub fn set_remove_key(&mut self, keycode: u16) {
        self.remove_key = keycode;
    }

    /// Get current mark key for a given mark_id (1-5)
    pub fn get_mark_key(&self, mark_id: u8) -> Option<u16> {
        if (1..=5).contains(&mark_id) {
            Some(self.mark_keys[(mark_id - 1) as usize])
        } else {
            None
        }
    }

    /// Get current stroke key
    pub fn get_stroke_key(&self) -> u16 {
        self.stroke_key
    }

    /// Get current remove key
    pub fn get_remove_key(&self) -> u16 {
        self.remove_key
    }

    /// Set a Shift+Key → Character mapping
    /// keycode: macOS virtual keycode for the base key (e.g., keys::A)
    /// output_char: Unicode codepoint for the output character (e.g., 'Ă' = 0x0102)
    pub fn set_shift_key(&mut self, keycode: u16, output_char: u32) {
        // Update existing entry if keycode matches
        for e in self.shift_keys.iter_mut().flatten() {
            if e.key == keycode {
                e.output_char = output_char;
                return;
            }
        }
        // Find first empty slot
        for entry in self.shift_keys.iter_mut() {
            if entry.is_none() {
                *entry = Some(ShiftKeyEntry {
                    key: keycode,
                    output_char,
                });
                return;
            }
        }
        // Array full — silently ignore (MAX_SHIFT_KEYS reached)
    }

    /// Remove a Shift+Key mapping
    pub fn remove_shift_key(&mut self, keycode: u16) {
        for entry in self.shift_keys.iter_mut() {
            if entry.as_ref().is_some_and(|e| e.key == keycode) {
                *entry = None;
                return;
            }
        }
    }

    /// Get the Shift+Key output character for a given keycode
    pub fn get_shift_key(&self, keycode: u16) -> Option<char> {
        for entry in self.shift_keys.iter().flatten() {
            if entry.key == keycode {
                return char::from_u32(entry.output_char);
            }
        }
        None
    }

    /// Clear all Shift+Key mappings
    pub fn clear_shift_keys(&mut self) {
        self.shift_keys = [None; MAX_SHIFT_KEYS];
    }
}

impl Method for Custom {
    fn mark(&self, key: u16) -> Option<u8> {
        for (i, &mk) in self.mark_keys.iter().enumerate() {
            if key == mk {
                return Some((i + 1) as u8);
            }
        }
        None
    }

    fn tone(&self, key: u16) -> Option<ToneType> {
        for e in self.tone_entries.iter().flatten() {
            if key == e.key {
                return Some(e.tone_type);
            }
        }
        None
    }

    fn tone_targets(&self, key: u16) -> &'static [u16] {
        for e in self.tone_entries.iter().flatten() {
            if key == e.key {
                return get_target_set(e.target_set);
            }
        }
        &[]
    }

    fn stroke(&self, key: u16) -> bool {
        key == self.stroke_key
    }

    fn remove(&self, key: u16) -> bool {
        key == self.remove_key
    }

    fn shift_key(&self, key: u16) -> Option<char> {
        self.get_shift_key(key)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_telex_defaults() {
        let c = Custom::from_telex();
        assert_eq!(c.mark(keys::S), Some(1)); // sắc
        assert_eq!(c.mark(keys::F), Some(2)); // huyền
        assert_eq!(c.mark(keys::R), Some(3)); // hỏi
        assert_eq!(c.mark(keys::X), Some(4)); // ngã
        assert_eq!(c.mark(keys::J), Some(5)); // nặng
        assert!(c.stroke(keys::D));
        assert!(c.remove(keys::Z));
        assert_eq!(c.tone(keys::A), Some(ToneType::Circumflex));
        assert_eq!(c.tone(keys::W), Some(ToneType::Horn));
    }

    #[test]
    fn test_vni_defaults() {
        let c = Custom::from_vni();
        assert_eq!(c.mark(keys::N1), Some(1));
        assert_eq!(c.mark(keys::N5), Some(5));
        assert!(c.stroke(keys::N9));
        assert!(c.remove(keys::N0));
        assert_eq!(c.tone(keys::N6), Some(ToneType::Circumflex));
        assert_eq!(c.tone(keys::N7), Some(ToneType::Horn));
        assert_eq!(c.tone(keys::N8), Some(ToneType::Breve));
    }

    #[test]
    fn test_custom_mark_override() {
        let mut c = Custom::from_telex();
        // Change sắc from S to Q
        c.set_mark_key(1, keys::Q);
        assert_eq!(c.mark(keys::Q), Some(1)); // Q now triggers sắc
        assert_eq!(c.mark(keys::S), None); // S no longer triggers sắc
    }

    #[test]
    fn test_custom_stroke_override() {
        let mut c = Custom::from_telex();
        c.set_stroke_key(keys::G);
        assert!(c.stroke(keys::G));
        assert!(!c.stroke(keys::D));
    }

    #[test]
    fn test_custom_remove_override() {
        let mut c = Custom::from_telex();
        c.set_remove_key(keys::Q);
        assert!(c.remove(keys::Q));
        assert!(!c.remove(keys::Z));
    }

    #[test]
    fn test_invalid_mark_id() {
        let mut c = Custom::from_telex();
        c.set_mark_key(0, keys::Q); // invalid
        c.set_mark_key(6, keys::Q); // invalid
                                    // Original marks unchanged
        assert_eq!(c.mark(keys::S), Some(1));
    }

    #[test]
    fn test_shift_key_set_and_get() {
        let mut c = Custom::from_telex();
        // Set Shift+A → Ă (U+0102)
        c.set_shift_key(keys::A, 0x0102);
        assert_eq!(c.get_shift_key(keys::A), Some('Ă'));
        assert_eq!(c.get_shift_key(keys::E), None); // not set
    }

    #[test]
    fn test_shift_key_update() {
        let mut c = Custom::from_telex();
        c.set_shift_key(keys::A, 0x0102); // Ă
        c.set_shift_key(keys::A, 0x00C2); // Update to Â
        assert_eq!(c.get_shift_key(keys::A), Some('Â'));
    }

    #[test]
    fn test_shift_key_remove() {
        let mut c = Custom::from_telex();
        c.set_shift_key(keys::A, 0x0102);
        c.remove_shift_key(keys::A);
        assert_eq!(c.get_shift_key(keys::A), None);
    }

    #[test]
    fn test_shift_key_clear() {
        let mut c = Custom::from_telex();
        c.set_shift_key(keys::A, 0x0102);
        c.set_shift_key(keys::E, 0x00CA);
        c.set_shift_key(keys::O, 0x01A0);
        c.clear_shift_keys();
        assert_eq!(c.get_shift_key(keys::A), None);
        assert_eq!(c.get_shift_key(keys::E), None);
        assert_eq!(c.get_shift_key(keys::O), None);
    }

    #[test]
    fn test_shift_key_overflow() {
        let mut c = Custom::from_telex();
        // Fill all 32 slots
        for i in 0..32u16 {
            c.set_shift_key(i, 0x0041 + i as u32); // A, B, C, ...
        }
        // 33rd should silently fail (no crash)
        c.set_shift_key(100, 0x0041);
        // First 32 should still work
        assert_eq!(c.get_shift_key(0), Some('A'));
        assert_eq!(c.get_shift_key(31), Some('`')); // 0x0041 + 31 = 0x0060 = '`'
        assert_eq!(c.get_shift_key(100), None); // not stored (overflow)
    }

    #[test]
    fn test_shift_key_via_method_trait() {
        let mut c = Custom::from_telex();
        c.set_shift_key(keys::A, 0x0102); // Ă
                                          // Access via Method trait
        let m: &dyn Method = &c;
        assert_eq!(m.shift_key(keys::A), Some('Ă'));
        assert_eq!(m.shift_key(keys::E), None);
    }
}
