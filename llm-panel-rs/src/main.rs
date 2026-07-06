// ───────────────────────────────────────────────────────────────────────
//  llm-panel — local LLM control GUI (Rust / FLTK, low memory footprint)
// ───────────────────────────────────────────────────────────────────────
//  Per-side (GPU :5000 / CPU :5001) controls with status LEDs, live
//  CPU/RAM/VRAM gauges, and a collapsible output console.
//  All logic delegated to the ./llm CLI (single source of truth).
//  Borderless window: drag anywhere to move, [X] to close.
// ───────────────────────────────────────────────────────────────────────
use fltk::{
    app,
    button::Button,
    dialog,
    draw,
    enums::{Align, Color, Event, Font, FrameType},
    frame::Frame,
    menu::Choice,
    misc::Progress,
    prelude::*,
    text::{TextBuffer, TextDisplay},
    window::Window,
};
use serde_json::Value;
use std::cell::RefCell;
use std::process::Command;
use std::rc::Rc;
use std::thread;
use std::time::Duration;

// Resolve the `llm` CLI path: $LLM_CLI, else $HOME/0_AI/local-llm/llm.
// Override $LLM_CLI to run the panel from any layout (portability).
fn llm() -> &'static str {
    static LLM_CLI: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    LLM_CLI
        .get_or_init(|| {
            std::env::var("LLM_CLI").unwrap_or_else(|_| {
                format!("{}/0_AI/local-llm/llm", std::env::var("HOME").unwrap_or_default())
            })
        })
        .as_str()
}
const PROFILES: [&str; 3] = ["a-moe", "a-moe-q8", "b-light"];

const W: i32 = 560;
const H_BASE: i32 = 656; // height without output console (incl. VRAM history graph)
const H_FULL: i32 = 856; // height with output console

// colors (Catppuccin Mocha)
const C_BG: u32 = 0x1e1e2e;
const C_CARD: u32 = 0x313244;
const C_FG: u32 = 0xcdd6f4;
const C_SUB: u32 = 0x9399b2;
const C_OK: u32 = 0xa6e3a1;
const C_DOWN: u32 = 0xf38ba8;
const C_ACC: u32 = 0x89b4fa;
const C_WARN: u32 = 0xf9e2af;
const C_KO: u32 = 0xf5c2e7; // pink — Korean (KO) chip
const C_GRAY: u32 = 0x6c7086;
const C_CONSOLE: u32 = 0x11111b;

#[derive(Clone, Default)]
struct Status {
    gpu_model: Option<String>,
    gpu_pid: Option<i64>,
    cpu_model: Option<String>,
    cpu_pid: Option<i64>,
    hyb_model: Option<String>,
    hyb_pid: Option<i64>,
    ko_model: Option<String>,
    ko_pid: Option<i64>,
    cpu_pct: f64,
    ram_used: f64,
    ram_total: f64,
    ram_avail: f64,
    ram_pct: f64,
    has_gpu: bool,
    vram_used: f64,
    vram_total: f64,
    vram_util: f64,
    vram_temp: f64,
}

#[derive(Clone)]
enum Msg {
    Status(Status),
    Log(String),
}

fn fnum(v: &Value, key: &str) -> f64 {
    v.get(key).and_then(|x| x.as_f64()).unwrap_or(0.0)
}

fn parse_status(v: &Value) -> Status {
    let mut s = Status::default();
    if let Some(ep) = v.get("gpu_ep") {
        s.gpu_model = ep.get("model").and_then(|m| m.as_str()).map(|x| x.to_string());
        s.gpu_pid = ep.get("pid").and_then(|p| p.as_i64());
    }
    if let Some(ep) = v.get("cpu_ep") {
        s.cpu_model = ep.get("model").and_then(|m| m.as_str()).map(|x| x.to_string());
        s.cpu_pid = ep.get("pid").and_then(|p| p.as_i64());
    }
    if let Some(ep) = v.get("hyb_ep") {
        s.hyb_model = ep.get("model").and_then(|m| m.as_str()).map(|x| x.to_string());
        s.hyb_pid = ep.get("pid").and_then(|p| p.as_i64());
    }
    if let Some(ep) = v.get("ko_ep") {
        s.ko_model = ep.get("model").and_then(|m| m.as_str()).map(|x| x.to_string());
        s.ko_pid = ep.get("pid").and_then(|p| p.as_i64());
    }
    s.cpu_pct = v.get("cpu_pct").and_then(|x| x.as_f64()).unwrap_or(0.0);
    if let Some(r) = v.get("ram").filter(|r| !r.is_null()) {
        s.ram_used = fnum(r, "used");
        s.ram_total = fnum(r, "total");
        s.ram_avail = fnum(r, "avail");
        s.ram_pct = fnum(r, "percent");
    }
    if let Some(g) = v.get("gpu").filter(|g| !g.is_null()) {
        s.has_gpu = true;
        s.vram_used = fnum(g, "vram_used_mb");
        s.vram_total = fnum(g, "vram_total_mb");
        s.vram_util = fnum(g, "util");
        s.vram_temp = fnum(g, "temp");
    }
    s
}

fn run_async(s: app::Sender<Msg>, args: Vec<String>) {
    thread::spawn(move || {
        s.send(Msg::Log(format!("$ llm {}", args.join(" "))));
        match Command::new(llm()).args(&args).output() {
            Ok(o) => {
                let mut t = String::from_utf8_lossy(&o.stdout).to_string();
                t.push_str(&String::from_utf8_lossy(&o.stderr));
                if !t.trim().is_empty() {
                    s.send(Msg::Log(t));
                }
            }
            Err(e) => s.send(Msg::Log(format!("[err] failed to run llm: {e}"))),
        }
    });
}

fn open_terminal(args: &[&str]) -> bool {
    let inner = format!("{} {}", llm(), args.join(" "));
    let keep = format!("{inner}; exec bash");
    let xt = format!("bash -lc '{keep}'");
    let attempts: [(&str, Vec<&str>); 3] = [
        ("gnome-terminal", vec!["--", "bash", "-lc", &keep]),
        ("konsole", vec!["-e", "bash", "-lc", &keep]),
        ("xterm", vec!["-e", &xt]),
    ];
    for (bin, a) in attempts {
        if Command::new(bin).args(a).spawn().is_ok() {
            return true;
        }
    }
    false
}

// Force HYB to be the only active model, then open Open WebUI in a Chrome window.
// `llm up hyb` stops gpu/cpu/ko (mutual exclusion) and loads gpt-oss-120B if it
// isn't already up — the model that drives the multi-agent Planner pipe. Runs
// off-thread so the UI never blocks (cold start of hyb can take ~1-2 min; the
// HYB title chip lights up when ready). Prefers Chrome app window, then Chromium,
// then falls back to `llm webui open` (xdg-open).
fn open_webui_chrome(s: app::Sender<Msg>) {
    const URL: &str = "http://127.0.0.1:3000";
    thread::spawn(move || {
        s.send(Msg::Log(
            "$ llm up hyb  (HYB only: stopping others, loading gpt-oss-120B if down — up to ~2 min)".into(),
        ));
        if let Ok(o) = Command::new(llm()).args(["up", "hyb"]).output() {
            let t = String::from_utf8_lossy(&o.stdout);
            if let Some(last) = t.lines().rev().find(|l| !l.trim().is_empty()) {
                s.send(Msg::Log(last.trim().to_string()));
            }
        }
        s.send(Msg::Log("$ llm webui up".into()));
        let _ = Command::new(llm()).args(["webui", "up"]).output();
        for bin in ["google-chrome", "google-chrome-stable", "chromium", "chromium-browser"] {
            if Command::new(bin).arg(format!("--app={URL}")).spawn().is_ok() {
                s.send(Msg::Log(format!("opened {URL} in {bin} (app window)")));
                return;
            }
        }
        // fallback: llm webui open (xdg-open / default browser)
        if Command::new(llm()).args(["webui", "open"]).spawn().is_ok() {
            s.send(Msg::Log(format!("Chrome not found — opened {URL} via default browser")));
            return;
        }
        s.send(Msg::Log("[err] could not open a browser for Open WebUI".into()));
    });
}

fn gb(mb: f64) -> f64 {
    mb / 1024.0
}

fn main() {
    let app = app::App::default().with_scheme(app::Scheme::Gtk);
    app::background(0x1e, 0x1e, 0x2e);
    app::foreground(0xcd, 0xd6, 0xf4);
    // shrink whole UI to ~2/3; fonts are set larger below to compensate (≈120%).
    app::set_screen_scale(0, 0.66);
    app::keyboard_screen_scaling(false);
    app::set_visible_focus(false); // remove the dotted focus rectangle around buttons

    let mut wind = Window::default().with_size(W, H_BASE).with_label("Local LLM Panel");
    wind.set_color(Color::from_u32(C_BG));
    wind.set_border(false); // clean: no title bar

    let (s, r) = app::channel::<Msg>();
    let shared: Rc<RefCell<Status>> = Rc::new(RefCell::new(Status::default()));
    // current non-minimized content height (H_BASE or H_FULL when output shown).
    let content_h: Rc<RefCell<i32>> = Rc::new(RefCell::new(H_BASE));

    // ── title strip (drag area) + close ──────────────────────────────
    // live title strip (also the content shown when minimized):
    //   "Local LLM" + 3 colored server chips (GPU/CPU/HYB) + CPU%/RAM, each own color/bold.
    {
        let mut nm = Frame::new(12, 4, 76, 20, "Local LLM");
        nm.set_label_color(Color::from_u32(C_SUB));
        nm.set_label_font(Font::HelveticaBold);
        nm.set_label_size(13);
        nm.set_align(Align::Left | Align::Inside);
    }
    let mut chip_gpu = title_chip(90, "GPU");
    let mut chip_cpu = title_chip(128, "CPU");
    let mut chip_hyb = title_chip(166, "HYB");
    let mut chip_ko = title_chip(204, "KO");
    let mut lbl_cpu = title_val(244, 90);
    let mut lbl_ram = title_val(336, 116);
    // title-bar Chat button (left of minimize) — quick chat with the active server,
    // works even when minimized.
    {
        let sh = shared.clone();
        let mut c = Button::new(W - 104, 4, 38, 20, "Chat");
        c.set_frame(FrameType::FlatBox);
        c.set_color(Color::from_u32(C_CARD));
        c.set_label_color(Color::from_u32(C_ACC));
        c.set_label_font(Font::HelveticaBold);
        c.set_label_size(13);
        c.set_callback(move |_| {
            let tgt = {
                let st = sh.borrow();
                if st.gpu_model.is_some() { "--gpu" }
                else if st.hyb_model.is_some() { "--hyb" }
                else if st.ko_model.is_some() { "--ko" }
                else { "--cpu" }
            };
            open_terminal(&["chat", tgt]);
        });
    }
    // minimize: collapse the window to a single title-bar line; click again to restore.
    {
        let mut wind = wind.clone();
        let content_h = content_h.clone();
        let mut minimized = false;
        let mut m = Button::new(W - 62, 4, 24, 20, "_");
        m.set_frame(FrameType::FlatBox);
        m.set_color(Color::from_u32(C_CARD));
        m.set_label_color(Color::from_u32(C_FG));
        m.set_label_font(Font::HelveticaBold);
        m.set_label_size(15);
        m.set_callback(move |b| {
            minimized = !minimized;
            if minimized {
                wind.set_size(W, 28);
                b.set_label("[]");
            } else {
                wind.set_size(W, *content_h.borrow());
                b.set_label("_");
            }
        });
    }
    {
        let mut x = Button::new(W - 34, 4, 24, 20, "X");
        x.set_frame(FrameType::FlatBox);
        x.set_color(Color::from_u32(C_CARD));
        x.set_label_color(Color::from_u32(C_DOWN));
        x.set_label_font(Font::HelveticaBold);
        x.set_label_size(15);
        x.set_callback(|_| app::quit());
    }

    // ── per-side cards ───────────────────────────────────────────────
    let (mut gpu_led, mut gpu_dot, mut gpu_model) =
        side_card(12, 32, "GPU  -  EXL3 (TabbyAPI)", "gpu", s, shared.clone());
    let (mut cpu_led, mut cpu_dot, mut cpu_model) =
        side_card(284, 32, "CPU  -  llama.cpp", "cpu", s, shared.clone());
    // exclusive GPU models row: HYB (gpt-oss) + KO (Kanana, Korean)
    let (mut hyb_led, mut hyb_dot, mut hyb_model) =
        side_card(12, 186, "HYB  -  gpt-oss 120B", "hyb", s, shared.clone());
    let (mut ko_led, mut ko_dot, mut ko_model) =
        side_card(284, 186, "KO  -  Kanana-2 (KR)", "ko", s, shared.clone());

    // ── global controls ──────────────────────────────────────────────
    section_label(12, 342, "Both");
    let mut y = 364;
    btn(12, y, 130, "Start Both", C_OK, {
        let s = s; move |_| run_async(s, vec!["up".into(), "both".into()])
    });
    btn(150, y, 130, "Stop All", C_DOWN, {
        let s = s; move |_| run_async(s, vec!["down".into(), "all".into()])
    });
    btn(288, y, 110, "Restart", C_ACC, {
        let s = s; move |_| run_async(s, vec!["restart".into(), "both".into()])
    });
    // Open WebUI in a Chrome app window (first row, right slot — aligned above "Show Output").
    btn(398, y, 150, "Open WebUI", C_ACC, {
        let s = s; move |_| open_webui_chrome(s)
    });

    y += 38;
    let mut prof = Choice::new(12, y, 110, 30, None);
    for p in PROFILES {
        prof.add_choice(p);
    }
    prof.set_value(0);
    prof.set_color(Color::from_u32(C_CARD));
    prof.set_text_color(Color::from_u32(C_FG));
    prof.set_text_size(14);
    {
        let s = s;
        let prof = prof.clone();
        btn(128, y, 84, "Switch", C_ACC, move |_| {
            let p = prof.choice().unwrap_or_else(|| "a-moe".into());
            run_async(s, vec!["switch".into(), p]);
        });
    }
    {
        let s = s;
        let sh = shared.clone();
        btn(218, y, 84, "Ask", C_ACC, move |_| {
            if let Some(q) = dialog::input_default("Prompt:", "") {
                if q.trim().is_empty() {
                    return;
                }
                let tgt = {
                    let st = sh.borrow();
                    if st.gpu_model.is_some() { "--gpu" }
                    else if st.hyb_model.is_some() { "--hyb" }
                    else if st.ko_model.is_some() { "--ko" }
                    else { "--cpu" }
                };
                run_async(s, vec!["ask".into(), q, tgt.into()]);
            }
        });
    }
    {
        let sh = shared.clone();
        btn(308, y, 84, "Chat", C_CARD, move |_| {
            let tgt = {
                let st = sh.borrow();
                if st.gpu_model.is_some() { "--gpu" }
                else if st.hyb_model.is_some() { "--hyb" }
                else if st.ko_model.is_some() { "--ko" }
                else { "--cpu" }
            };
            open_terminal(&["chat", tgt]);
        });
    }

    // ── system resources ─────────────────────────────────────────────
    section_label(12, y + 36, "System");
    let gy = y + 58;
    let mut p_cpu = gauge(12, gy, "CPU");
    let mut p_ram = gauge(12, gy + 28, "RAM");
    let mut p_vram = gauge(12, gy + 56, "VRAM");

    // ── VRAM usage graph (bottom) — live time-series of VRAM used ─────
    section_label(12, gy + 88, "VRAM history");
    let vram_hist: Rc<RefCell<VramHist>> = Rc::new(RefCell::new(VramHist::new(120)));
    let mut vram_plot = vram_graph(12, gy + 110, W - 24, 74, vram_hist.clone());

    // ── output console (hidden by default) ───────────────────────────
    let mut out_label = Frame::new(12, H_BASE + 6, 200, 18, "Output");
    out_label.set_label_color(Color::from_u32(C_ACC));
    out_label.set_label_font(Font::HelveticaBold);
    out_label.set_label_size(14);
    out_label.set_align(Align::Left | Align::Inside);
    out_label.hide();
    let mut buf = TextBuffer::default();
    let mut disp = TextDisplay::new(12, H_BASE + 28, W - 24, H_FULL - (H_BASE + 38), None);
    disp.set_buffer(buf.clone());
    disp.set_color(Color::from_u32(C_CONSOLE));
    disp.set_text_color(Color::from_u32(C_FG));
    disp.set_text_font(Font::Courier);
    disp.set_text_size(13);
    disp.hide();
    buf.set_text("Ready.\n");

    // output toggle button (created last so it can capture the widgets)
    {
        let mut wind = wind.clone();
        let mut out_label = out_label.clone();
        let mut disp = disp.clone();
        let content_h = content_h.clone();
        let mut shown = false;
        let mut b = Button::new(398, y, 150, 30, "Show Output");
        b.set_frame(FrameType::FlatBox);
        b.set_color(Color::from_u32(C_CARD));
        b.set_label_color(Color::from_u32(C_FG));
        b.set_label_font(Font::HelveticaBold);
        b.set_label_size(14);
        b.set_callback(move |b| {
            shown = !shown;
            if shown {
                out_label.show();
                disp.show();
                *content_h.borrow_mut() = H_FULL;
                wind.set_size(W, H_FULL);
                b.set_label("Hide Output");
            } else {
                out_label.hide();
                disp.hide();
                *content_h.borrow_mut() = H_BASE;
                wind.set_size(W, H_BASE);
                b.set_label("Show Output");
            }
        });
    }

    wind.end();

    // borderless: drag anywhere on background to move the window
    {
        let mut ox = 0;
        let mut oy = 0;
        wind.handle(move |w, ev| match ev {
            Event::Push => {
                ox = app::event_x();
                oy = app::event_y();
                true
            }
            Event::Drag => {
                w.set_pos(app::event_x_root() - ox, app::event_y_root() - oy);
                true
            }
            _ => false,
        });
    }

    wind.show();

    // ── status polling thread (1.5s) ─────────────────────────────────
    {
        let s = s;
        thread::spawn(move || loop {
            if let Ok(o) = Command::new(llm()).arg("json-status").output() {
                let txt = String::from_utf8_lossy(&o.stdout);
                if let Some(line) = txt.lines().last() {
                    if let Ok(v) = serde_json::from_str::<Value>(line) {
                        s.send(Msg::Status(parse_status(&v)));
                    }
                }
            }
            thread::sleep(Duration::from_millis(1500));
        });
    }

    // ── main loop ────────────────────────────────────────────────────
    while app.wait() {
        if let Some(msg) = r.recv() {
            match msg {
                Msg::Log(t) => {
                    buf.append(t.trim_end());
                    buf.append("\n");
                    let lines = buf.count_lines(0, buf.length());
                    disp.scroll(lines, 0);
                }
                Msg::Status(st) => {
                    update_ep(&mut gpu_led, &mut gpu_dot, &mut gpu_model, &st.gpu_model, st.gpu_pid);
                    update_ep(&mut cpu_led, &mut cpu_dot, &mut cpu_model, &st.cpu_model, st.cpu_pid);
                    update_ep(&mut hyb_led, &mut hyb_dot, &mut hyb_model, &st.hyb_model, st.hyb_pid);
                    update_ep(&mut ko_led, &mut ko_dot, &mut ko_model, &st.ko_model, st.ko_pid);
                    // live title strip: distinct-color chips for running servers + CPU/RAM
                    set_chip(&mut chip_gpu, st.gpu_model.is_some(), C_OK);
                    set_chip(&mut chip_cpu, st.cpu_model.is_some(), C_WARN);
                    set_chip(&mut chip_hyb, st.hyb_model.is_some(), C_ACC);
                    set_chip(&mut chip_ko, st.ko_model.is_some(), C_KO);
                    lbl_cpu.set_label(&format!("CPU {:.0}%", st.cpu_pct));
                    lbl_cpu.set_label_color(Color::from_u32(load_color(st.cpu_pct)));
                    if st.ram_total > 0.0 {
                        lbl_ram.set_label(&format!(
                            "RAM {:.0}/{:.0}G",
                            st.ram_used / 1_073_741_824.0,
                            st.ram_total / 1_073_741_824.0
                        ));
                        lbl_ram.set_label_color(Color::from_u32(load_color(st.ram_pct)));
                    }
                    set_gauge(&mut p_cpu, st.cpu_pct, &format!("CPU  {:.0}%", st.cpu_pct));
                    if st.ram_total > 0.0 {
                        let used = st.ram_used / 1_073_741_824.0;
                        let total = st.ram_total / 1_073_741_824.0;
                        let avail = st.ram_avail / 1_073_741_824.0;
                        set_gauge(
                            &mut p_ram,
                            st.ram_pct,
                            &format!("RAM  {used:.1}/{total:.0}GB | free {avail:.1}GB"),
                        );
                    }
                    if st.has_gpu && st.vram_total > 0.0 {
                        let pct = st.vram_used / st.vram_total * 100.0;
                        let free = gb(st.vram_total - st.vram_used);
                        set_gauge(
                            &mut p_vram,
                            pct,
                            &format!(
                                "VRAM  {:.1}/{:.0}GB | free {:.1}GB | {:.0}% | {:.0}C",
                                gb(st.vram_used),
                                gb(st.vram_total),
                                free,
                                st.vram_util,
                                st.vram_temp
                            ),
                        );
                        vram_hist.borrow_mut().push(st.vram_used, st.vram_total);
                        vram_plot.redraw();
                    }
                    *shared.borrow_mut() = st;
                }
            }
        }
    }
}

// ── per-side card: header + status LED + model + Start/Stop/Bench/Log ─
fn side_card(
    x: i32,
    y: i32,
    title: &str,
    side: &'static str,
    s: app::Sender<Msg>,
    _shared: Rc<RefCell<Status>>,
) -> (Frame, Frame, Frame) {
    let w = 264;
    let mut bg = Frame::new(x, y, w, 150, None);
    bg.set_frame(FrameType::FlatBox);
    bg.set_color(Color::from_u32(C_CARD));

    let mut name = Frame::new(x + 10, y + 6, w - 20, 22, None);
    name.set_label(title);
    name.set_label_color(Color::from_u32(C_FG));
    name.set_label_font(Font::HelveticaBold);
    name.set_label_size(15);
    name.set_align(Align::Left | Align::Inside);

    // status LED (colored box — font-independent indicator)
    let mut led = Frame::new(x + 12, y + 36, 16, 16, None);
    led.set_frame(FrameType::FlatBox);
    led.set_color(Color::from_u32(C_GRAY));

    let mut dot = Frame::new(x + 36, y + 33, w - 46, 20, None);
    dot.set_label("checking");
    dot.set_label_color(Color::from_u32(C_SUB));
    dot.set_label_size(14);
    dot.set_align(Align::Left | Align::Inside);

    let mut model = Frame::new(x + 12, y + 56, w - 24, 18, None);
    model.set_label("model: -");
    model.set_label_color(Color::from_u32(C_SUB));
    model.set_label_size(12);
    model.set_label_font(Font::Courier);
    model.set_align(Align::Left | Align::Inside);

    let bw = 114;
    btn(x + 12, y + 82, bw, "Start", C_OK, {
        let s = s; let side = side; move |_| run_async(s, vec!["up".into(), side.into()])
    });
    btn(x + 12 + bw + 12, y + 82, bw, "Stop", C_DOWN, {
        let s = s; let side = side; move |_| run_async(s, vec!["down".into(), side.into()])
    });
    btn(x + 12, y + 116, bw, "Bench", C_CARD, {
        let side = side; move |_| { open_terminal(&["bench", side]); }
    });
    btn(x + 12 + bw + 12, y + 116, bw, "Log", C_CARD, {
        let side = side; move |_| { open_terminal(&["logs", side]); }
    });

    (led, dot, model)
}

// ── title-strip widgets (bold, individually colored) ─────────────────
fn title_chip(x: i32, text: &str) -> Frame {
    let mut f = Frame::new(x, 4, 42, 20, None);
    f.set_label(text);
    f.set_label_color(Color::from_u32(C_GRAY));
    f.set_label_font(Font::HelveticaBold);
    f.set_label_size(13);
    f.set_align(Align::Left | Align::Inside);
    f
}
fn title_val(x: i32, w: i32) -> Frame {
    let mut f = Frame::new(x, 4, w, 20, None);
    f.set_label_color(Color::from_u32(C_SUB));
    f.set_label_font(Font::HelveticaBold);
    f.set_label_size(13);
    f.set_align(Align::Left | Align::Inside);
    f
}
fn set_chip(f: &mut Frame, on: bool, color: u32) {
    f.set_label_color(Color::from_u32(if on { color } else { C_GRAY }));
    f.redraw();
}
fn load_color(pct: f64) -> u32 {
    if pct < 70.0 { C_OK } else if pct < 90.0 { C_WARN } else { C_DOWN }
}

fn section_label(x: i32, y: i32, text: &str) {
    let mut f = Frame::new(x, y, 200, 18, None);
    f.set_label(text);
    f.set_label_color(Color::from_u32(C_ACC));
    f.set_label_font(Font::HelveticaBold);
    f.set_label_size(14);
    f.set_align(Align::Left | Align::Inside);
}

fn gauge(x: i32, y: i32, label: &str) -> Progress {
    let mut lab = Frame::new(x, y, 46, 24, None);
    lab.set_label(label);
    lab.set_label_color(Color::from_u32(C_FG));
    lab.set_label_size(13);
    lab.set_align(Align::Left | Align::Inside);

    let mut p = Progress::new(x + 50, y, W - x - 50 - 12, 24, None);
    p.set_minimum(0.0);
    p.set_maximum(100.0);
    p.set_value(0.0);
    p.set_color(Color::from_u32(0x45475a));
    p.set_selection_color(Color::from_u32(C_OK));
    p.set_label_color(Color::from_u32(C_BG));
    p.set_label_size(12);
    p
}

fn set_gauge(p: &mut Progress, pct: f64, text: &str) {
    let pct = pct.clamp(0.0, 100.0);
    p.set_value(pct);
    let col = if pct < 70.0 {
        C_OK
    } else if pct < 90.0 {
        C_WARN
    } else {
        C_DOWN
    };
    p.set_selection_color(Color::from_u32(col));
    p.set_label(text);
}

// ── VRAM usage history + graph ───────────────────────────────────────
struct VramHist {
    used: Vec<f64>, // MB, oldest → newest
    total: f64,     // MB
    cap: usize,
}
impl VramHist {
    fn new(cap: usize) -> Self {
        Self { used: Vec::new(), total: 0.0, cap }
    }
    fn push(&mut self, used_mb: f64, total_mb: f64) {
        self.total = total_mb;
        self.used.push(used_mb);
        if self.used.len() > self.cap {
            self.used.remove(0);
        }
    }
}

// A small live line/area chart of VRAM used over time (newest at right edge).
fn vram_graph(x: i32, y: i32, w: i32, h: i32, hist: Rc<RefCell<VramHist>>) -> Frame {
    let mut f = Frame::new(x, y, w, h, None);
    f.set_frame(FrameType::FlatBox);
    f.set_color(Color::from_u32(C_CONSOLE));
    f.draw(move |f| {
        let (gx, gy, gw, gh) = (f.x(), f.y(), f.w(), f.h());
        draw::set_draw_color(Color::from_u32(C_CONSOLE));
        draw::draw_rectf(gx, gy, gw, gh);
        // gridlines at 25/50/75% of VRAM total
        draw::set_draw_color(Color::from_u32(0x2a2a3a));
        for k in 1..4 {
            let yy = gy + gh - gh * k / 4;
            draw::draw_line(gx, yy, gx + gw, yy);
        }
        let hb = hist.borrow();
        let total = if hb.total > 0.0 { hb.total } else { 1.0 };
        let n = hb.used.len();
        let cap = hb.cap.max(2);
        let dx = gw as f64 / (cap as f64 - 1.0);
        let map = |i: usize| -> (i32, i32) {
            let xx = gx + gw - ((n - 1 - i) as f64 * dx).round() as i32;
            let yy = gy + gh - ((hb.used[i] / total).clamp(0.0, 1.0) * gh as f64).round() as i32;
            (xx.max(gx), yy)
        };
        if n >= 2 {
            // filled area
            draw::set_draw_color(Color::from_u32(0x39456b));
            draw::begin_complex_polygon();
            let (x0, _) = map(0);
            draw::vertex(x0 as f64, (gy + gh) as f64);
            for i in 0..n {
                let (px, py) = map(i);
                draw::vertex(px as f64, py as f64);
            }
            let (xl, _) = map(n - 1);
            draw::vertex(xl as f64, (gy + gh) as f64);
            draw::end_complex_polygon();
            // line on top
            draw::set_draw_color(Color::from_u32(C_ACC));
            for i in 0..n - 1 {
                let (a, b) = map(i);
                let (c, d) = map(i + 1);
                draw::draw_line(a, b, c, d);
            }
        }
        // border
        draw::set_draw_color(Color::from_u32(C_GRAY));
        draw::draw_rect(gx, gy, gw, gh);
        // current value label (top-left inside)
        draw::set_draw_color(Color::from_u32(C_SUB));
        draw::set_font(Font::Helvetica, 11);
        let cur = hb.used.last().copied().unwrap_or(0.0) / 1024.0;
        let tot = hb.total / 1024.0;
        draw::draw_text2(
            &format!("{cur:.1} / {tot:.0} GB"),
            gx + 6,
            gy + 2,
            gw - 12,
            14,
            Align::Left | Align::Top,
        );
    });
    f
}

fn update_ep(led: &mut Frame, dot: &mut Frame, model: &mut Frame, m: &Option<String>, pid: Option<i64>) {
    match m {
        Some(name) => {
            led.set_color(Color::from_u32(C_OK));
            dot.set_label(&format!("UP   (pid {})", pid.unwrap_or(0)));
            dot.set_label_color(Color::from_u32(C_OK));
            model.set_label(&format!("model: {name}"));
        }
        None => {
            led.set_color(Color::from_u32(C_DOWN));
            dot.set_label("down");
            dot.set_label_color(Color::from_u32(C_DOWN));
            model.set_label("model: -");
        }
    }
    led.redraw();
}

fn btn<F: FnMut(&mut Button) + 'static>(x: i32, y: i32, w: i32, label: &str, bg: u32, cb: F) {
    let mut b = Button::new(x, y, w, 30, None);
    b.set_label(label);
    b.set_frame(FrameType::FlatBox);
    b.set_color(Color::from_u32(bg));
    b.set_label_color(Color::from_u32(if bg == C_CARD { C_FG } else { C_BG }));
    b.set_label_font(Font::HelveticaBold);
    b.set_label_size(14);
    b.set_callback(cb);
}
