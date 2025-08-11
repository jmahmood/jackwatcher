use anyhow::Result;
use evdev::{enumerate, Device, SwitchType};
use std::{env, path::PathBuf, process::Command, thread};

const START_CMD: &[&str] = &[
    "/storage/musicctl.sh",
    "start",
];

const STOP_CMD:  &[&str] = &[
	"/storage/musicctl.sh",
    "stop",
];



fn supported_hp(dev: &Device) -> bool {
    dev.supported_switches()
        .map(|s| s.contains(SwitchType::SW_HEADPHONE_INSERT))
        .unwrap_or(false)
}

fn current_hp(dev: &Device) -> Option<bool> {
    match dev.get_switch_state() {
        Ok(state) => Some(state.contains(SwitchType::SW_HEADPHONE_INSERT)),
        Err(_) => None,
    }
}

fn run_cmd(cmd: &[&str]) {
    eprintln!("[exec] {:?} {:?}", cmd[0], &cmd[1..]);
    let _ = Command::new(cmd[0]).args(&cmd[1..]).status();
}

fn list_nodes() -> Result<()> {
    for (path, dev) in enumerate() {
        let name = dev.name().unwrap_or("<unknown>");
        let sup = supported_hp(&dev);
        let init = sup && current_hp(&dev).unwrap_or(false);
        println!("{} {:<30} hp_switch={} initial={}",
                 path.display(), name, sup, if init {1} else {0});
    }
    Ok(())
}

fn watch_all(do_exec: bool, fire_initial: bool) -> Result<()> {
    // Collect devices that expose the headphone switch
    let mut nodes: Vec<(PathBuf, Device)> = enumerate()
        .filter(|(_, d)| supported_hp(d))
        .collect();

    if nodes.is_empty() {
        eprintln!("[warn] No /dev/input/event* exposes SW_HEADPHONE_INSERT.");
        return Ok(());
    }

    eprintln!("[info] Attaching to {} device(s):", nodes.len());
    for (p, d) in nodes.iter() {
        let name = d.name().unwrap_or("<unknown>");
        let init = current_hp(d).unwrap_or(false);
        eprintln!("  - {} ({name}) initial HEADPHONE_INSERT={}", p.display(), if init {1} else {0});
    }

	// Spawn a blocking loop per device (no polling)
    // Evdev is blocking by default.
	for (path, mut dev) in nodes.drain(..) {
	    let name = dev.name().unwrap_or("<unknown>").to_string();

	    // Seed last from current state (edge-trigger)
	    let mut last = current_hp(&dev);

	    if fire_initial {
	        if let Some(true) = last {
	            eprintln!("[event] {} ({}) initial START (fire-initial)", path.display(), name);
	            if do_exec { run_cmd(START_CMD); }
	        }
	    }


	    thread::spawn(move || {
	        loop {
	            match dev.fetch_events() {
	                Ok(events) => {
	                    for ev in events {
	                        if let evdev::InputEventKind::Switch(evdev::SwitchType::SW_HEADPHONE_INSERT) = ev.kind() {
	                            let plugged = ev.value() != 0;
	                            if last.map(|p| p != plugged).unwrap_or(true) {
	                                eprintln!(
	                                    "[event] {} ({}) HEADPHONE_INSERT={} -> {}",
	                                    path.display(), name,
	                                    if plugged {1} else {0},
	                                    if plugged {"START"} else {"STOP"}
	                                );
	                                last = Some(plugged);
	                                if do_exec {
	                                    if plugged { run_cmd(START_CMD); } else { run_cmd(STOP_CMD); }
	                                }
	                            }
	                        }
	                    }
	                }
	                Err(_e) => {
	                    // Rare read error (e.g., device transient). Brief backoff to avoid spin.
	                    std::thread::sleep(std::time::Duration::from_millis(200));
	                }
	            }
	        }
	    });
	}

    // Keep foreground process alive so you can watch logs
    loop { thread::park(); }
}

fn main() -> Result<()> {
    let mut args = env::args().skip(1);
    match args.next().as_deref() {
        Some("--list") => list_nodes(),
        Some("--watch") | None => {
            let mut do_exec = false;
            let mut fire_initial = false;
            for a in args {
                match a.as_str() {
                    "--exec" => do_exec = true,
                    "--fire-initial" => fire_initial = true,
                    _ => {
                        eprintln!("Usage: jack-watcher [--watch] [--exec] [--fire-initial]");
                        eprintln!("       jack-watcher --list");
                        std::process::exit(2);
                    }
                }
            }
            watch_all(do_exec, fire_initial)
        }
        Some(_) => {
            eprintln!("Usage: jack-watcher [--watch] [--exec] [--fire-initial]");
            eprintln!("       jack-watcher --list");
            std::process::exit(2);
        }
    }
}
