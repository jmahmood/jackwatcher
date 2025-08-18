// src/bin/btn-watcher.rs
use anyhow::Result;
use evdev::{enumerate, Device, InputEventKind, Key};
use std::{collections::HashSet, env, path::PathBuf, process::Command, thread};
use std::str::FromStr;

fn run_cmd(controller: &str, sub: &str, arg: Option<&str>) {
    let mut cmd = Command::new(controller);
    cmd.arg(sub);
    if let Some(a) = arg { cmd.arg(a); }
    let _ = cmd.status();
}

fn main() -> Result<()> {
    // Buttons (override with JW_BTN_LEFT/JW_BTN_RIGHT if your mapping differs)
    let lb_name = env::var("JW_BTN_LEFT").unwrap_or_else(|_| "BTN_TL".into());
    let rb_name = env::var("JW_BTN_RIGHT").unwrap_or_else(|_| "BTN_TR".into());
    let lb  = Key::from_str(&lb_name).unwrap_or(Key::BTN_TL);
    let rb  = Key::from_str(&rb_name).unwrap_or(Key::BTN_TR);

    // D-pad codes (override if needed)
    let dleft  = Key::BTN_DPAD_LEFT;
    let dright = Key::BTN_DPAD_RIGHT;
    let dup    = Key::BTN_DPAD_UP;
    let ddown  = Key::BTN_DPAD_DOWN;

    // Menu key (defaults to BTN_MODE, which is EV code 316)
    let menu_name = env::var("JW_BTN_MENU").unwrap_or_else(|_| "BTN_MODE".into());
    let menu = Key::from_str(&menu_name).unwrap_or(Key::BTN_MODE);

    // Seek steps (seconds)
    let small = env::var("JW_SEEK_SMALL").ok().and_then(|s| s.parse::<i64>().ok()).unwrap_or(5);
    let big   = env::var("JW_SEEK_BIG").ok().and_then(|s| s.parse::<i64>().ok()).unwrap_or(30);

    let controller = env::var("JW_CMD").unwrap_or_else(|_| "/storage/bin/musicctl".into());

    // Pick devices that have keys we care about (include menu key)
    let mut nodes: Vec<(PathBuf, Device)> = enumerate()
        .filter(|(_, d)| {
            let has_key = d.supported_events().contains(evdev::EventType::KEY);
            let set = d.supported_keys();
            has_key && set.map_or(false, |s|
                s.contains(lb) || s.contains(rb) ||
                s.contains(dleft) || s.contains(dright) || s.contains(dup) || s.contains(ddown) ||
                s.contains(menu))
        })
        .collect();

    if nodes.is_empty() {
        eprintln!("[btn-watcher] no suitable key devices found");
        return Ok(());
    }

    for (_path, mut dev) in nodes.drain(..) {
        let ctrl = controller.clone();

        // Track which keys are currently held on THIS device
        thread::spawn(move || {
            let mut held: HashSet<Key> = HashSet::new();

            // Helper: only act if Menu is currently held and the key is one of the mapped actions
            let do_action = |k: Key, ctrl: &str| {
                // No action bound to Menu itself
                if k == lb      { run_cmd(ctrl, "prev", None); }
                else if k == rb { run_cmd(ctrl, "next", None); }
                else if k == dleft  { run_cmd(ctrl, "seek", Some(&format!("-{small}"))); }
                else if k == dright { run_cmd(ctrl, "seek", Some(&format!("+{small}"))); }
                else if k == ddown  { run_cmd(ctrl, "seek", Some(&format!("-{big}"))); }
                else if k == dup    { run_cmd(ctrl, "seek", Some(&format!("+{big}"))); }
            };

            loop {
                match dev.fetch_events() {
                    Ok(events) => {
                        for ev in events {
                            if let InputEventKind::Key(k) = ev.kind() {
                                match ev.value() {
                                    1 => {
                                        // press
                                        held.insert(k);
                                        if held.contains(&menu) {
                                            // Only fire for non-menu keys while menu is held
                                            if k != menu { do_action(k, &ctrl) }
                                        }
                                    }
                                    2 => {
                                        // auto-repeat (held)
                                        if held.contains(&menu) && k != menu {
                                            do_action(k, &ctrl);
                                        }
                                    }
                                    0 => {
                                        // release
                                        held.remove(&k);
                                    }
                                    _ => {}
                                }
                            }
                        }
                    }
                    Err(_) => thread::sleep(std::time::Duration::from_millis(200)),
                }
            }
        });
    }

    loop { thread::park(); }
}
