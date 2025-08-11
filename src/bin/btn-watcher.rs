// src/bin/btn-watcher.rs
use anyhow::Result;
use evdev::{enumerate, Device, InputEventKind, Key};
use std::{env, path::PathBuf, process::Command, thread};
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

    // Seek steps (seconds)
    let small = env::var("JW_SEEK_SMALL").ok().and_then(|s| s.parse::<i64>().ok()).unwrap_or(5);
    let big   = env::var("JW_SEEK_BIG").ok().and_then(|s| s.parse::<i64>().ok()).unwrap_or(30);

    let controller = env::var("JW_CMD").unwrap_or_else(|_| "/storage/bin/musicctl".into());

    // Pick devices that have keys we care about
    let mut nodes: Vec<(PathBuf, Device)> = enumerate()
        .filter(|(_, d)| {
            let has_key = d.supported_events().contains(evdev::EventType::KEY);
            let set = d.supported_keys();
            has_key && set.map_or(false, |s|
                s.contains(lb) || s.contains(rb) ||
                s.contains(dleft) || s.contains(dright) || s.contains(dup) || s.contains(ddown))
        })
        .collect();

    if nodes.is_empty() {
        eprintln!("[btn-watcher] no suitable key devices found");
        return Ok(());
    }

    for (_path, mut dev) in nodes.drain(..) {
        let ctrl = controller.clone();
        thread::spawn(move || loop {
            match dev.fetch_events() {
                Ok(events) => {
                    for ev in events {
                        if let InputEventKind::Key(k) = ev.kind() {
                            // value: 1=press, 2=auto-repeat, 0=release
                            if ev.value() == 1 {
                                if k == lb { run_cmd(&ctrl, "prev", None); }
                                if k == rb { run_cmd(&ctrl, "next", None); }
                                if k == dleft  { run_cmd(&ctrl, "seek", Some(&format!("-{small}"))); }
                                if k == dright { run_cmd(&ctrl, "seek", Some(&format!("+{small}"))); }
                                if k == ddown  { run_cmd(&ctrl, "seek", Some(&format!("-{big}"))); }
                                if k == dup    { run_cmd(&ctrl, "seek", Some(&format!("+{big}"))); }
                            } else if ev.value() == 2 {
                                // Smooth scrubbing while held
                                if k == dleft  { run_cmd(&ctrl, "seek", Some(&format!("-{small}"))); }
                                if k == dright { run_cmd(&ctrl, "seek", Some(&format!("+{small}"))); }
                                if k == ddown  { run_cmd(&ctrl, "seek", Some(&format!("-{big}"))); }
                                if k == dup    { run_cmd(&ctrl, "seek", Some(&format!("+{big}"))); }
                            }
                        }
                    }
                }
                Err(_) => thread::sleep(std::time::Duration::from_millis(200)),
            }
        });
    }

    loop { thread::park(); }
}
