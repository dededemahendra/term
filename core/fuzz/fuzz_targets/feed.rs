//! Run from core/: cargo +nightly fuzz run feed -- -max_total_time=60
//! Needs: rustup toolchain install nightly && cargo install cargo-fuzz

#![no_main]

use libfuzzer_sys::fuzz_target;
use termcore::term::Term;

fuzz_target!(|data: &[u8]| {
    let mut term = Term::new(80, 24, 50);
    for chunk in data.chunks(7) {
        term.feed(chunk);
    }
    if let Some(&b) = data.first() {
        term.resize(1 + (b as usize % 120), 1 + (b as usize / 2 % 60));
        term.feed(data);
    }
    let _ = term.dump();
    let _ = term.selection_text();
});
