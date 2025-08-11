use anyhow::Result;
use evdev::{enumerate, Device, InputEventKind, Key};
use std::{env, path::PathBuf, process::Command, thread};
use std::str::FromStr;

fn supported_buttons(d: &Device, left: Key, right: Key) -> bool {
    d.supported_events().contains(evdev::EventType::KEY)
        && d.supported_keys().map_or(false, |s| s.contains(left) || s.contains(right))
}

fn run_cmd(controller: &str, sub: &str) {
    let _ = Command::new(controller).arg(sub).status();
}

fn main() -> Result<()> {
    // Defaults; override via env if your handheld maps differently
    let left_name  = env::var("JW_BTN_LEFT").unwrap_or_else(|_| "BTN_TL".into());
    let right_name = env::var("JW_BTN_RIGHT").unwrap_or_else(|_| "BTN_TR".into());
    let left  = Key::from_str(&left_name).unwrap_or(Key::BTN_TL);
    let right = Key::from_str(&right_name).unwrap_or(Key::BTN_TR);

    let controller = env::var("JW_CMD").unwrap_or_else(|_| "/storage/bin/musicctl".into());

    let mut nodes: Vec<(PathBuf, Device)> = enumerate()
        .filter(|(_, d)| supported_buttons(d, left, right))
        .collect();

    if nodes.is_empty() {
        eprintln!("[btn-watcher] no key devices with LB/RB found");
        return Ok(());
    }

    for (_path, mut dev) in nodes.drain(..) {
        let ctrl = controller.clone();
        thread::spawn(move || loop {
            match dev.fetch_events() {
                Ok(events) => {
                    for ev in events {
                        if let InputEventKind::Key(k) = ev.kind() {
                            if ev.value() == 1 {
                                if k == left  { run_cmd(&ctrl, "prev"); }
                                if k == right { run_cmd(&ctrl, "next"); }
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
