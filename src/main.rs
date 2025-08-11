use anyhow::Result;
use evdev::{enumerate, Device, SwitchType};
use std::{env, path::PathBuf, process::Command, thread};

fn supported_hp(dev: &Device) -> bool {
    dev.supported_switches()
        .map(|s| s.contains(SwitchType::SW_HEADPHONE_INSERT))
        .unwrap_or(false)
}

fn current_hp(dev: &Device) -> Option<bool> {
    dev.get_switch_state()
        .ok()
        .map(|s| s.contains(SwitchType::SW_HEADPHONE_INSERT))
}

#[derive(Clone)]
struct Cfg {
    controller: String, // e.g. "/storage/bin/musicctl"
    do_exec: bool,
    fire_initial: bool,
}

fn resolve_cfg(args: impl Iterator<Item=String>) -> (Option<String>, Cfg) {
    // parse: --list | --watch [--exec] [--fire-initial] [--cmd <path>]
    let mut mode_list = false;
    let mut do_exec = false;
    let mut fire_initial = false;
    let mut cmd_cli: Option<String> = None;

    let mut it = args.peekable();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--list" => mode_list = true,
            "--watch" => {} // default
            "--exec" => do_exec = true,
            "--fire-initial" => fire_initial = true,
            "--cmd" => {
                cmd_cli = it.next();
                if cmd_cli.is_none() {
                    eprintln!("--cmd requires a path"); std::process::exit(2);
                }
            }
            _ => {
                eprintln!("Usage: jack-watcher [--watch] [--exec] [--fire-initial] [--cmd <controller_path>]");
                eprintln!("       jack-watcher --list");
                std::process::exit(2);
            }
        }
    }

    let controller = cmd_cli
        .or_else(|| env::var("JW_CMD").ok())
        .unwrap_or_else(|| "/storage/musicctl.sh".to_string());

    let cfg = Cfg { controller, do_exec, fire_initial };
    (mode_list.then_some("--list".to_string()), cfg)
}

fn run_controller(controller: &str, action: &str) {
    eprintln!("[exec] {} {}", controller, action);
    let _ = Command::new(controller).arg(action).status();
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

fn watch_all(cfg: Cfg) -> Result<()> {
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

    // Blocking loop per device
    for (path, mut dev) in nodes.drain(..) {
        let name = dev.name().unwrap_or("<unknown>").to_string();
        let controller = cfg.controller.clone();
        let do_exec = cfg.do_exec;
        let mut last = current_hp(&dev);

        if cfg.fire_initial {
            if let Some(true) = last {
                eprintln!("[event] {} ({}) initial START (fire-initial)", path.display(), name);
                if do_exec { run_controller(&controller, "start"); }
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
                                        if plugged { run_controller(&controller, "start"); }
                                        else       { run_controller(&controller, "stop");  }
                                    }
                                }
                            }
                        }
                    }
                    Err(_e) => {
                        // Rare transient; brief backoff to avoid a tight loop
                        std::thread::sleep(std::time::Duration::from_millis(200));
                    }
                }
            }
        });
    }

    // Keep foreground process alive
    loop { thread::park(); }
}

fn main() -> Result<()> {
    let (mode, cfg) = resolve_cfg(env::args().skip(1));
    if mode.is_some() { return list_nodes(); }
    watch_all(cfg)
}
