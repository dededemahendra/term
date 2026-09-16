//! Feeds deterministic pseudo random bytes, biased towards escape
//! sequence syntax, through the core. Any panic is a bug in the core.

use termcore::term::Term;

struct XorShift(u64);

impl XorShift {
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }
}

const INTERESTING: &[u8] =
    b"\x1b[]?;:0123456789ABCDEFGHIJKLMPSTXZabcdefghlmnqrsu@` \x07\x08\x09\x0a\x0d\x9b\\P()#78=>\xc3\xa9\xe6\x97\xa5\xf0\x9f\x91\x8d\xe2\x80\x8d\xef\xb8\x8f";

fn fill(rng: &mut XorShift, buf: &mut [u8]) {
    for b in buf {
        let r = rng.next();
        *b = if r % 3 == 0 {
            (r >> 8) as u8
        } else {
            INTERESTING[((r >> 8) as usize) % INTERESTING.len()]
        };
    }
}

#[test]
fn random_bytes_never_panic() {
    let mut rng = XorShift(0x9E37_79B9_7F4A_7C15);
    let mut term = Term::new(80, 24, 100);
    let mut buf = vec![0u8; 4096];
    let mut responses = vec![0u8; 256];
    for round in 0..768 {
        let len = (rng.next() % 4096) as usize;
        fill(&mut rng, &mut buf[..len]);
        term.feed(&buf[..len]);
        if round % 64 == 0 {
            let cols = 1 + (rng.next() % 200) as usize;
            let rows = 1 + (rng.next() % 100) as usize;
            term.resize(cols, rows);
        }
        let screen = term.screen();
        let cursor = screen.cursor();
        assert!(
            cursor.col < screen.cols() && cursor.row < screen.rows(),
            "cursor out of bounds after round {round}"
        );
        let _ = term.dump();
        term.screen_mut().take_responses(&mut responses);
    }
}

#[test]
fn tiny_grids_survive_everything() {
    let mut rng = XorShift(42);
    let mut buf = vec![0u8; 512];
    for (cols, rows) in [(1, 1), (1, 5), (5, 1), (2, 2)] {
        let mut term = Term::new(cols, rows, 3);
        for _ in 0..64 {
            fill(&mut rng, &mut buf);
            term.feed(&buf);
            let _ = term.dump();
        }
    }
}
