use anyhow::Result;
use serde_json::Value;
use std::{
    collections::HashMap,
    fs::{self, File},
    io::{BufRead, BufReader, Write},
    os::unix::net::UnixStream,
    path::Path,
    time::{Duration, Instant},
};

macro_rules! vlog {
    ($on:expr, $($t:tt)*) => { if $on { eprintln!($($t)*); } }
}

fn load_db(path: &str) -> HashMap<String, f64> {
    fs::read_to_string(path).ok()
        .map(|s| s.lines().filter_map(|l| {
            let mut sp = l.splitn(2, '\t');
            let k = sp.next()?;
            let v = sp.next()?.parse::<f64>().ok()?;
            Some((k.to_string(), v))
        }).collect())
        .unwrap_or_default()
}

fn save_db(path: &str, map: &HashMap<String, f64>) {
    if let Some(parent) = Path::new(path).parent() { let _ = fs::create_dir_all(parent); }
    if let Ok(mut f) = File::create(path) {
        for (k, v) in map { let _ = writeln!(f, "{}\t{:.3}", k, v); }
    }
}

fn write_last(path: &str, pos: f64, last_path: &str) {
    if let Some(parent) = Path::new(last_path).parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Ok(mut f) = File::create(last_path) {
        let _ = writeln!(f, "{}\t{:.3}", path, pos);
    }
}

fn end_reason_is_eof(v: &Value) -> bool {
    if let Some(n) = v.get("reason").and_then(|d| d.as_i64()) { return n == 0; }
    if let Some(s) = v.get("reason").and_then(|d| d.as_str()) { return s.eq_ignore_ascii_case("eof"); }
    false
}

fn send_json(sock: &mut UnixStream, js: &str, dbg: bool) {
    vlog!(dbg, "[mpvlog] -> {}", js);
    let _ = writeln!(sock, "{}", js);
}

fn main() -> Result<()> {
    let debug = std::env::var("JW_DEBUG").is_ok();
    let last  = std::env::var("JW_LAST_FILE").unwrap_or("/storage/jackwatcher/last.txt".into());
    let sockp = std::env::var("MPV_SOCKET").unwrap_or("/run/musicctl.sock".into());
    let db    = std::env::var("JW_RESUME_DB").unwrap_or("/storage/jackwatcher/resume.db".into());

    vlog!(debug, "[mpvlog] starting: sock={} db={} last={}", &sockp, &db, &last);

    let mut resume = load_db(&db);
    resume.retain(|k, _| Path::new(k).is_file());

    let mut s = UnixStream::connect(&sockp)?;
    let mut r = BufReader::new(s.try_clone()?);

    // Observe time-pos and path
    send_json(&mut s, r#"{"command":["observe_property",1,"time-pos"]}"#, debug);
    send_json(&mut s, r#"{"command":["observe_property",2,"path"]}"#, debug);
    // Also ask once for current path (in case we attached mid-play)
    send_json(&mut s, r#"{"request_id":42,"command":["get_property","path"]}"#, debug);

    let mut cur_path: Option<String> = None;
    let mut cur_pos: f64 = 0.0;
    let mut last_flush = Instant::now();

    let mut line = String::new();
    loop {
        line.clear();
        if r.read_line(&mut line)? == 0 { break; }
        let parsed: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(_) => continue,
        };

        if let Some(event) = parsed.get("event").and_then(|e| e.as_str()) {
            match event {
                "file-loaded" => {
                    // Query path explicitly after load
                    send_json(&mut s, r#"{"request_id":1,"command":["get_property","path"]}"#, debug);
                }
                "end-file" => {
                    let finished = end_reason_is_eof(&parsed);
                    if let Some(ref k) = cur_path {
                        if finished { resume.remove(k); } else { resume.insert(k.clone(), cur_pos); }
                        save_db(&db, &resume);
                        write_last(k, cur_pos, &last);
                        vlog!(debug, "[mpvlog] end-file: finished={} saved {} @ {:.3}", finished, k, cur_pos);
                    }
                    cur_path = None;
                    cur_pos = 0.0;
                }
                "property-change" => {
                    if parsed.get("name").and_then(|n| n.as_str()) == Some("path") {
                        if let Some(p) = parsed.get("data").and_then(|d| d.as_str()) {
                            cur_path = Some(p.to_string());
                            vlog!(debug, "[mpvlog] path={}", p);
                        }
                    } else if parsed.get("name").and_then(|n| n.as_str()) == Some("time-pos") {
                        if let Some(pos) = parsed.get("data").and_then(|d| d.as_f64()) {
                            cur_pos = pos;
                            if last_flush.elapsed() >= Duration::from_secs(5) {
                                if let Some(ref k) = cur_path {
                                    resume.insert(k.clone(), cur_pos);
                                    save_db(&db, &resume);
                                    write_last(k, cur_pos, &last);
                                    vlog!(debug, "[mpvlog] flush {} @ {:.3}", k, cur_pos);
                                    last_flush = Instant::now();
                                }
                            }
                        }
                    }
                }
                _ => {}
            }
        } else if parsed.get("request_id").and_then(|x| x.as_i64()) == Some(42) {
            // reply to initial get_property path
            if let Some(p) = parsed.get("data").and_then(|d| d.as_str()) {
                cur_path = Some(p.to_string());
                vlog!(debug, "[mpvlog] boot path={}", p);
            }
        } else if parsed.get("request_id").and_then(|x| x.as_i64()) == Some(1) {
            // reply to on-load get_property path
            if let Some(p) = parsed.get("data").and_then(|d| d.as_str()) {
                cur_path = Some(p.to_string());
                vlog!(debug, "[mpvlog] load path={}", p);
            }
        }
    }
    Ok(())
}
