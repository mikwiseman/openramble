//! The window the take block is drawn in.
//!
//! A small window with no frame, above everything, that never takes focus:
//! the paste needs the application the person was typing in to stay in front,
//! so a block that became the active window would make every dictation land
//! nowhere. It is sized by what it holds, as the block on the Mac is.
//!
//! The material is the platform's own: an opaque block the page draws with a
//! solid fill. Nothing here imitates Liquid Glass.

use crate::take::Block;
use tauri::{Emitter, Manager};

/// The window's label, and the name its capability file grants events to.
pub const LABEL: &str = "take";

/// What the page listens for.
pub const EVENT: &str = "take-block";

/// Which corner of the screen the block is held to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Anchor {
    /// Above the tray: Windows. The block grows upward.
    BottomRight,
    /// Under the top bar: Linux, and a Mac running this app. It grows down.
    TopRight,
}

impl Anchor {
    pub fn for_this_platform() -> Self {
        if cfg!(windows) {
            Anchor::BottomRight
        } else {
            Anchor::TopRight
        }
    }
}

/// The part of a screen windows may use, in physical pixels.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WorkArea {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}

/// Where the window's top-left corner goes.
///
/// Flush with the corner of the work area: the page keeps its own margin
/// around the block, so the block itself sits clear of the taskbar and of the
/// screen edge. A window larger than the screen is held to the top-left of
/// the work area rather than pushed off it.
pub fn origin(work: WorkArea, width: u32, height: u32, anchor: Anchor) -> (i32, i32) {
    let fit = |start: i32, room: u32, size: u32| {
        start.saturating_add(i32::try_from(room.saturating_sub(size)).unwrap_or(i32::MAX))
    };
    let x = fit(work.x, work.width, width);
    let y = match anchor {
        Anchor::BottomRight => fit(work.y, work.height, height),
        Anchor::TopRight => work.y,
    };
    (x, y)
}

/// Build the window, hidden.
///
/// At startup rather than at the first take: a web view takes a moment to
/// start, and the block is meant to be there on the frame after the key.
pub fn create(app: &tauri::AppHandle) -> tauri::Result<()> {
    tauri::WebviewWindowBuilder::new(app, LABEL, tauri::WebviewUrl::App("take.html".into()))
        .title("OpenRamble")
        .decorations(false)
        .transparent(true)
        .shadow(false)
        // Nobody resizes the block by hand: it has no frame to drag. GTK
        // sizes a fixed window by its content and ignores a requested size,
        // so on Linux it stays resizable for `fit` to work.
        .resizable(cfg!(target_os = "linux"))
        .skip_taskbar(true)
        .always_on_top(true)
        .visible_on_all_workspaces(true)
        // Both: never focused when shown, and never by a click on it either.
        .focused(false)
        .focusable(false)
        .visible(false)
        .build()?;
    Ok(())
}

/// Hand the page what to draw.
///
/// The window is not shown here. The page draws first and reports the size
/// the block came to, and `fit` shows it then, so the block never appears at
/// the size or with the words of the one before it.
pub fn draw(app: &tauri::AppHandle, block: &Block) {
    let Some(window) = app.get_webview_window(LABEL) else {
        return;
    };
    if *block == Block::Hidden {
        let _ = window.hide();
        return;
    }
    // The pointer passes through a block with nothing to click, so it never
    // takes a click meant for the application underneath.
    let _ = window.set_ignore_cursor_events(!block.takes_clicks());
    // Dictated words stay out of screenshots and screen shares.
    let _ = window.set_content_protected(block.shows_words());
    let _ = window.emit_to(LABEL, EVENT, block);
}

/// Size the window to the block the page drew, put it in its corner, show it.
///
/// `width` and `height` are the page's own pixels.
pub fn fit(app: &tauri::AppHandle, width: f64, height: f64) {
    let Some(window) = app.get_webview_window(LABEL) else {
        return;
    };
    if !(width.is_finite() && height.is_finite() && width >= 1.0 && height >= 1.0) {
        return;
    }
    let _ = window.set_size(tauri::LogicalSize::new(width, height));

    let monitor = window
        .primary_monitor()
        .ok()
        .flatten()
        .or_else(|| window.current_monitor().ok().flatten());
    if let Some(monitor) = monitor {
        let area = monitor.work_area();
        let scale = monitor.scale_factor();
        let (x, y) = origin(
            WorkArea {
                x: area.position.x,
                y: area.position.y,
                width: area.size.width,
                height: area.size.height,
            },
            physical(width, scale),
            physical(height, scale),
            Anchor::for_this_platform(),
        );
        let _ = window.set_position(tauri::PhysicalPosition::new(x, y));
    }
    let _ = window.show();
}

/// Page pixels to screen pixels, rounded up so the block is never clipped.
fn physical(length: f64, scale: f64) -> u32 {
    // Bounded on both sides before the cast, so it cannot wrap.
    (length * scale).ceil().clamp(1.0, f64::from(u32::MAX)) as u32
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A 1920 by 1080 screen with a 48 pixel taskbar along the bottom.
    const WINDOWS: WorkArea = WorkArea {
        x: 0,
        y: 0,
        width: 1920,
        height: 1032,
    };

    /// The same screen with a 32 pixel bar along the top.
    const LINUX: WorkArea = WorkArea {
        x: 0,
        y: 32,
        width: 1920,
        height: 1048,
    };

    #[test]
    fn on_windows_the_block_sits_above_the_tray_at_the_right_edge() {
        assert_eq!(
            origin(WINDOWS, 232, 76, Anchor::BottomRight),
            (1920 - 232, 1032 - 76)
        );
    }

    /// Words that wait make the block taller. It grows away from the taskbar,
    /// so its bottom edge stays where the person first saw it.
    #[test]
    fn a_taller_block_grows_upward_from_the_taskbar() {
        let (_, short) = origin(WINDOWS, 440, 76, Anchor::BottomRight);
        let (_, tall) = origin(WINDOWS, 440, 230, Anchor::BottomRight);
        assert_eq!(short + 76, tall + 230);
    }

    #[test]
    fn on_linux_the_block_hangs_under_the_top_bar_and_grows_down() {
        assert_eq!(origin(LINUX, 232, 76, Anchor::TopRight), (1920 - 232, 32));
        assert_eq!(origin(LINUX, 440, 230, Anchor::TopRight), (1920 - 440, 32));
    }

    /// A second screen to the left of the first has negative coordinates.
    #[test]
    fn a_screen_left_of_the_main_one_keeps_the_block_on_it() {
        let left = WorkArea {
            x: -2560,
            y: 0,
            width: 2560,
            height: 1400,
        };
        assert_eq!(
            origin(left, 232, 76, Anchor::BottomRight),
            (-232, 1400 - 76)
        );
    }

    #[test]
    fn a_block_larger_than_the_screen_is_not_pushed_off_it() {
        let small = WorkArea {
            x: 0,
            y: 0,
            width: 200,
            height: 60,
        };
        assert_eq!(origin(small, 440, 230, Anchor::BottomRight), (0, 0));
    }

    #[test]
    fn page_pixels_round_up_to_whole_screen_pixels() {
        assert_eq!(physical(232.0, 1.0), 232);
        assert_eq!(physical(232.0, 1.5), 348);
        assert_eq!(physical(76.5, 1.25), 96);
        assert_eq!(physical(0.2, 1.0), 1);
    }
}
