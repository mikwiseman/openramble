//! What this Linux session will and will not let a dictation tool do.
//!
//! X11 lets any program watch the keyboard and type into any window. Wayland,
//! deliberately, does not — and that is not a bug to work around but a security
//! decision. What a dictation tool can do there depends on the compositor, the
//! portals installed, and whether the person has a virtual-input daemon running.
//!
//! The rule this module exists to enforce: **whatever cannot work is said, not
//! silently skipped**. A dictation tool that quietly does nothing is worse than
//! one that admits it cannot type into this window, because the person cannot
//! tell the difference between "broken" and "I did not hold the key properly"
//! and will keep trying.

use std::path::Path;

/// Which display server this session is running.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DisplayServer {
    X11,
    Wayland,
    /// Neither could be determined — a bare TTY, or a session that reports
    /// nothing useful.
    Unknown,
}

/// How the finished text can be delivered on this session.
///
/// Ordered best to worst. Each tier is strictly less pleasant than the one
/// above, and the person is told which one they got whenever it is not the best.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum InjectionTier {
    /// Synthesize the paste directly. What X11 allows and what everything else
    /// is an approximation of.
    Direct,
    /// A virtual input device via ydotool's daemon. Works on any compositor, but
    /// needs the daemon running and permission on `/dev/uinput`.
    VirtualDevice,
    /// The compositor's own virtual-keyboard protocol, through wtype. Fast where
    /// it exists; GNOME does not implement it.
    CompositorProtocol,
    /// Nothing can type for us. The text goes to the clipboard and the person
    /// pastes it themselves.
    ///
    /// Still useful — the words are recognized and one keystroke away — but it
    /// must be stated, or it looks like the dictation failed.
    ClipboardOnly,
}

impl InjectionTier {
    /// What to tell the person. `None` when nothing needs saying.
    pub fn notice(self) -> Option<&'static str> {
        match self {
            InjectionTier::Direct | InjectionTier::VirtualDevice => None,
            InjectionTier::CompositorProtocol => None,
            InjectionTier::ClipboardOnly => Some(
                "This desktop does not allow applications to type into other windows. \
                 Dictated text is placed on the clipboard — press paste to insert it. \
                 Installing ydotool lets OpenRamble insert it for you.",
            ),
        }
    }

    /// Can we put the text in place ourselves?
    pub fn types_for_you(self) -> bool {
        self != InjectionTier::ClipboardOnly
    }
}

/// How the dictation key can be watched.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HotkeyCapability {
    /// Press and release are both visible, so hold-to-talk works.
    HoldToTalk,
    /// Only activation is visible, so dictation must be started and stopped by
    /// two separate presses.
    ///
    /// The GlobalShortcuts portal reports Activated and Deactivated, but some
    /// compositors deliver only the first. Hold-to-talk silently becomes
    /// "recording forever" there, so it is turned into a toggle on purpose.
    ToggleOnly,
    /// The keyboard cannot be watched at all.
    Unavailable,
}

/// What this session supports, decided once at startup.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionCapabilities {
    pub display_server: DisplayServer,
    pub injection: InjectionTier,
    pub hotkey: HotkeyCapability,
}

impl SessionCapabilities {
    /// Everything a person should be told, in plain sentences.
    ///
    /// Empty when the session can do everything.
    pub fn notices(&self) -> Vec<&'static str> {
        let mut notices = Vec::new();
        if let Some(notice) = self.injection.notice() {
            notices.push(notice);
        }
        match self.hotkey {
            HotkeyCapability::ToggleOnly => notices.push(
                "This desktop reports only when the dictation key is pressed, not when it \
                 is released. Press once to start dictating and again to stop.",
            ),
            HotkeyCapability::Unavailable => notices.push(
                "This desktop does not allow OpenRamble to watch the dictation key. \
                 Dictation cannot be started by keyboard here.",
            ),
            HotkeyCapability::HoldToTalk => {}
        }
        notices
    }

    pub fn is_fully_supported(&self) -> bool {
        self.notices().is_empty()
    }
}

/// Read the session type from the environment.
///
/// `XDG_SESSION_TYPE` is the stated answer; `WAYLAND_DISPLAY` is the one that is
/// actually true, because a session can be launched under Wayland while the
/// variable still says x11. When they disagree, believe the socket.
pub fn detect_display_server(
    wayland_display: Option<&str>,
    xdg_session_type: Option<&str>,
    x11_display: Option<&str>,
) -> DisplayServer {
    if wayland_display.is_some_and(|value| !value.is_empty()) {
        return DisplayServer::Wayland;
    }
    match xdg_session_type.map(str::trim) {
        Some("wayland") => DisplayServer::Wayland,
        Some("x11") => DisplayServer::X11,
        _ if x11_display.is_some_and(|value| !value.is_empty()) => DisplayServer::X11,
        _ => DisplayServer::Unknown,
    }
}

/// Which injection tier this session gets.
///
/// Pure, so the whole decision table is testable without a desktop attached.
pub fn choose_injection(
    display_server: DisplayServer,
    ydotool_socket: bool,
    wtype_available: bool,
    compositor: Option<&str>,
) -> InjectionTier {
    match display_server {
        // X11 and an unknown session both allow direct synthesis; on an unknown
        // session that is a guess, but a wrong guess degrades to "nothing was
        // typed", which the person can see, rather than to a silent misbehaviour.
        DisplayServer::X11 | DisplayServer::Unknown => InjectionTier::Direct,
        DisplayServer::Wayland => {
            if ydotool_socket {
                return InjectionTier::VirtualDevice;
            }
            // GNOME's compositor does not implement the virtual-keyboard
            // protocol, so wtype is present but does nothing there. Preferring it
            // would produce the exact silent failure this module exists to avoid.
            let gnome = compositor
                .map(|name| name.to_lowercase().contains("gnome"))
                .unwrap_or(false);
            if wtype_available && !gnome {
                return InjectionTier::CompositorProtocol;
            }
            InjectionTier::ClipboardOnly
        }
    }
}

/// Look at the running system and decide.
pub fn detect() -> SessionCapabilities {
    let env = |name: &str| std::env::var(name).ok();
    let display_server = detect_display_server(
        env("WAYLAND_DISPLAY").as_deref(),
        env("XDG_SESSION_TYPE").as_deref(),
        env("DISPLAY").as_deref(),
    );

    let ydotool_socket = env("YDOTOOL_SOCKET")
        .map(|path| Path::new(&path).exists())
        .unwrap_or_else(|| Path::new("/run/user/1000/.ydotool_socket").exists());
    let wtype_available = which("wtype");
    let compositor = env("XDG_CURRENT_DESKTOP");

    let injection = choose_injection(
        display_server,
        ydotool_socket,
        wtype_available,
        compositor.as_deref(),
    );

    let hotkey = match display_server {
        DisplayServer::X11 | DisplayServer::Unknown => HotkeyCapability::HoldToTalk,
        // Under Wayland the keyboard is only visible through the portal, and
        // whether releases arrive depends on the compositor. Assumed present
        // until the portal says otherwise; the toggle fallback exists for when
        // it does not.
        DisplayServer::Wayland => HotkeyCapability::HoldToTalk,
    };

    SessionCapabilities {
        display_server,
        injection,
        hotkey,
    }
}

/// Is a command on the PATH?
fn which(command: &str) -> bool {
    let Ok(path) = std::env::var("PATH") else {
        return false;
    };
    std::env::split_paths(&path).any(|directory| directory.join(command).exists())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_wayland_socket_outranks_what_the_session_claims() {
        // A session can be launched under Wayland while the variable still says
        // x11. The socket is the one that is actually true.
        assert_eq!(
            detect_display_server(Some("wayland-0"), Some("x11"), Some(":0")),
            DisplayServer::Wayland
        );
        assert_eq!(
            detect_display_server(None, Some("x11"), Some(":0")),
            DisplayServer::X11
        );
        assert_eq!(
            detect_display_server(None, None, Some(":0")),
            DisplayServer::X11
        );
        assert_eq!(
            detect_display_server(None, None, None),
            DisplayServer::Unknown
        );
        // An empty variable is not a session.
        assert_eq!(
            detect_display_server(Some(""), None, None),
            DisplayServer::Unknown
        );
    }

    #[test]
    fn x11_can_type_directly() {
        assert_eq!(
            choose_injection(DisplayServer::X11, false, false, None),
            InjectionTier::Direct
        );
    }

    #[test]
    fn wayland_prefers_a_virtual_device_when_one_is_running() {
        assert_eq!(
            choose_injection(DisplayServer::Wayland, true, true, Some("GNOME")),
            InjectionTier::VirtualDevice
        );
    }

    /// GNOME ships wtype-compatible tooling that does nothing, because its
    /// compositor does not implement the protocol. Preferring it there would
    /// produce exactly the silent failure this module exists to prevent.
    #[test]
    fn wtype_is_not_trusted_on_gnome() {
        assert_eq!(
            choose_injection(DisplayServer::Wayland, false, true, Some("GNOME")),
            InjectionTier::ClipboardOnly
        );
        assert_eq!(
            choose_injection(DisplayServer::Wayland, false, true, Some("ubuntu:GNOME")),
            InjectionTier::ClipboardOnly
        );
        // On a compositor that does implement it, it is the right choice.
        assert_eq!(
            choose_injection(DisplayServer::Wayland, false, true, Some("sway")),
            InjectionTier::CompositorProtocol
        );
    }

    #[test]
    fn wayland_with_nothing_available_falls_back_to_the_clipboard() {
        assert_eq!(
            choose_injection(DisplayServer::Wayland, false, false, Some("GNOME")),
            InjectionTier::ClipboardOnly
        );
    }

    /// The point of the whole module: a degraded session says so.
    #[test]
    fn a_degraded_session_explains_itself() {
        let limited = SessionCapabilities {
            display_server: DisplayServer::Wayland,
            injection: InjectionTier::ClipboardOnly,
            hotkey: HotkeyCapability::HoldToTalk,
        };
        assert!(!limited.is_fully_supported());
        let notices = limited.notices();
        assert_eq!(notices.len(), 1);
        // It says what to do about it, not merely what is wrong.
        assert!(notices[0].contains("clipboard"), "{}", notices[0]);
        assert!(notices[0].contains("ydotool"), "{}", notices[0]);
    }

    #[test]
    fn a_toggle_only_session_explains_the_changed_gesture() {
        let toggle = SessionCapabilities {
            display_server: DisplayServer::Wayland,
            injection: InjectionTier::VirtualDevice,
            hotkey: HotkeyCapability::ToggleOnly,
        };
        let notices = toggle.notices();
        assert_eq!(notices.len(), 1);
        assert!(notices[0].contains("again to stop"), "{}", notices[0]);
    }

    #[test]
    fn a_capable_session_says_nothing_at_all() {
        // A message that appears when nothing is wrong stops being read.
        let full = SessionCapabilities {
            display_server: DisplayServer::X11,
            injection: InjectionTier::Direct,
            hotkey: HotkeyCapability::HoldToTalk,
        };
        assert!(full.is_fully_supported());
        assert!(full.notices().is_empty());
    }

    #[test]
    fn the_tiers_are_ordered_best_first() {
        assert!(InjectionTier::Direct < InjectionTier::ClipboardOnly);
        assert!(InjectionTier::VirtualDevice < InjectionTier::ClipboardOnly);
        assert!(InjectionTier::Direct.types_for_you());
        assert!(!InjectionTier::ClipboardOnly.types_for_you());
    }
}
