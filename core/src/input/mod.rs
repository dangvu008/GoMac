//! Input Methods
//!
//! Defines key mappings for Vietnamese input methods.
//! Engine handles all pattern matching based on buffer scan.
//! Supports custom key overrides via the `custom` module.

pub mod custom;
pub mod telex;
pub mod vni;

pub use custom::Custom;
pub use telex::Telex;
pub use vni::Vni;

use crate::data::chars::tone;
use crate::data::keys;
use std::sync::Mutex;

/// Shared tone target constants
pub const CIRCUMFLEX_TARGETS: &[u16] = &[keys::A, keys::E, keys::O];
pub const HORN_TARGETS_TELEX: &[u16] = &[keys::A, keys::O, keys::U];
pub const HORN_TARGETS_VNI: &[u16] = &[keys::O, keys::U];
pub const BREVE_TARGETS: &[u16] = &[keys::A];

/// Tone modifier type
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ToneType {
    /// Circumflex: â, ê, ô
    Circumflex,
    /// Horn: ơ, ư (and ă for Telex)
    Horn,
    /// Breve: ă (VNI only)
    Breve,
}

impl ToneType {
    pub fn value(&self) -> u8 {
        match self {
            ToneType::Circumflex => tone::CIRCUMFLEX,
            ToneType::Horn => tone::HORN,
            ToneType::Breve => tone::HORN, // ă uses same internal value
        }
    }
}

/// Input method trait - defines key mappings only
pub trait Method {
    /// Check if key is a mark modifier
    /// Returns: 1=sắc, 2=huyền, 3=hỏi, 4=ngã, 5=nặng
    fn mark(&self, key: u16) -> Option<u8>;

    /// Check if key is a tone modifier
    /// Returns tone type if this key can modify vowels
    fn tone(&self, key: u16) -> Option<ToneType>;

    /// Get valid targets for tone key
    /// Returns list of vowel keys this tone can apply to
    fn tone_targets(&self, key: u16) -> &'static [u16];

    /// Check if key is stroke modifier (d → đ)
    fn stroke(&self, key: u16) -> bool;

    /// Check if key removes diacritics
    fn remove(&self, key: u16) -> bool;

    /// Get Shift+Key output character (for custom double-key mappings)
    /// Returns None by default — only Custom can have shift_key mappings.
    fn shift_key(&self, _key: u16) -> Option<char> {
        None
    }
}

/// Static method instances (zero-sized types, no heap allocation)
static TELEX: Telex = Telex;
static VNI: Vni = Vni;

/// Custom method instances (Mutex-wrapped for thread-safe runtime configuration)
/// When a custom method is set, `get()` returns it instead of the static default.
static CUSTOM_TELEX: Mutex<Option<Custom>> = Mutex::new(None);
static CUSTOM_VNI: Mutex<Option<Custom>> = Mutex::new(None);

/// Get method by id (returns static reference, no allocation)
/// If custom overrides are set, returns the custom instance.
///
/// SAFETY: Custom instances use Mutex for thread safety. The returned
/// reference is valid for the lifetime of the program (static).
/// When custom is active, we leak a Box to create a 'static reference.
/// This is intentional — custom configs are set rarely and persist for app lifetime.
pub fn get(id: u8) -> &'static dyn Method {
    match id {
        1 => {
            let guard = CUSTOM_VNI.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(ref custom) = *guard {
                // Leak a copy to get 'static lifetime (set rarely, persists for app life)
                let boxed: Box<dyn Method> = Box::new(custom.clone());
                Box::leak(boxed)
            } else {
                &VNI
            }
        }
        _ => {
            let guard = CUSTOM_TELEX.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(ref custom) = *guard {
                let boxed: Box<dyn Method> = Box::new(custom.clone());
                Box::leak(boxed)
            } else {
                &TELEX
            }
        }
    }
}

/// Set a custom method configuration for the given method id
/// method: 0 = Telex, 1 = VNI
pub fn set_custom_method(method: u8, custom: Custom) {
    match method {
        1 => {
            let mut guard = CUSTOM_VNI.lock().unwrap_or_else(|e| e.into_inner());
            *guard = Some(custom);
        }
        _ => {
            let mut guard = CUSTOM_TELEX.lock().unwrap_or_else(|e| e.into_inner());
            *guard = Some(custom);
        }
    }
}

/// Reset custom method to default (removes override)
/// method: 0 = Telex, 1 = VNI
pub fn reset_custom_method(method: u8) {
    match method {
        1 => {
            let mut guard = CUSTOM_VNI.lock().unwrap_or_else(|e| e.into_inner());
            *guard = None;
        }
        _ => {
            let mut guard = CUSTOM_TELEX.lock().unwrap_or_else(|e| e.into_inner());
            *guard = None;
        }
    }
}

/// Get mutable access to the custom method for the given method id.
/// If no custom method exists, creates one from defaults.
/// Returns true if a custom method was already active.
pub fn with_custom_method<F>(method: u8, f: F)
where
    F: FnOnce(&mut Custom),
{
    match method {
        1 => {
            let mut guard = CUSTOM_VNI.lock().unwrap_or_else(|e| e.into_inner());
            if guard.is_none() {
                *guard = Some(Custom::from_vni());
            }
            if let Some(ref mut custom) = *guard {
                f(custom);
            }
        }
        _ => {
            let mut guard = CUSTOM_TELEX.lock().unwrap_or_else(|e| e.into_inner());
            if guard.is_none() {
                *guard = Some(Custom::from_telex());
            }
            if let Some(ref mut custom) = *guard {
                f(custom);
            }
        }
    }
}
