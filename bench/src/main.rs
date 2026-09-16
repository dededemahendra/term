//! Feeds a deterministic 100 MB stream of mixed text and escape
//! sequences through the core and reports throughput.
//! Run: cargo run --release -p termbench

use std::time::Instant;

use termcore::term::Term;

const TARGET_BYTES: usize = 100 * 1024 * 1024;

fn build_stream() -> Vec<u8> {
    let mut out = Vec::with_capacity(TARGET_BYTES + 256);
    let mut state: u64 = 0x2545_F491_4F6C_DD1D;
    while out.len() < TARGET_BYTES {
        state = state
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        match (state >> 60) % 6 {
            0 => out.extend_from_slice(b"\x1b[1;32mINFO\x1b[0m compiling module core::grid\r\n"),
            1 => out.extend_from_slice(b"\x1b[38;2;200;100;50mwarning:\x1b[m unused variable `x`\r\n"),
            2 => out.extend_from_slice(b"\x1b[2K\x1b[G[=====>     ] 42% building\r"),
            3 => out.extend_from_slice("日本語テキスト ünïcödé ✓ 👍\r\n".as_bytes()),
            4 => out.extend_from_slice(b"\x1b[3;1H\x1b[K\x1b[24;1H"),
            _ => {
                for _ in 0..4 {
                    out.extend_from_slice(
                        b"the quick brown fox jumps over the lazy dog 0123456789\r\n",
                    );
                }
            }
        }
    }
    out
}

fn main() {
    let stream = build_stream();
    let mut term = Term::new(200, 60, 10_000);
    let start = Instant::now();
    for chunk in stream.chunks(64 * 1024) {
        term.feed(chunk);
    }
    let elapsed = start.elapsed().as_secs_f64();
    let mb = stream.len() as f64 / (1024.0 * 1024.0);
    println!("fed {mb:.1} MB in {elapsed:.3} s = {:.0} MB/s", mb / elapsed);
    println!("last row: {:?}", term.screen().row_text(59));
}
