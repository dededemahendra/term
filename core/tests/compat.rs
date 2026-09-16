//! Feeds every `tests/compat/*.in` through an 80x24 terminal and
//! compares `Term::dump()` with the matching `.snap`.
//!
//! Regenerate snapshots with `UPDATE_SNAPSHOTS=1 cargo test --test compat`,
//! then read every changed `.snap` before committing it.

use std::fs;
use std::path::Path;

use termcore::term::Term;

#[test]
fn fixtures_match_snapshots() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/compat");
    let update = std::env::var_os("UPDATE_SNAPSHOTS").is_some();
    let mut failures = Vec::new();
    let mut count = 0;
    let mut entries: Vec<_> = fs::read_dir(&dir).unwrap().map(|e| e.unwrap().path()).collect();
    entries.sort();
    for path in entries {
        if path.extension().and_then(|e| e.to_str()) != Some("in") {
            continue;
        }
        count += 1;
        let input = fs::read(&path).unwrap();
        let mut term = Term::new(80, 24, 100);
        term.feed(&input);
        let actual = term.dump();
        let snap = path.with_extension("snap");
        if update {
            fs::write(&snap, &actual).unwrap();
            continue;
        }
        match fs::read_to_string(&snap) {
            Ok(expected) if expected == actual => {}
            Ok(expected) => failures.push(format!(
                "{}\n--- expected\n{expected}\n--- actual\n{actual}\n",
                path.display()
            )),
            Err(_) => failures.push(format!(
                "{}: no snapshot. Run with UPDATE_SNAPSHOTS=1 and review the result.",
                path.display()
            )),
        }
    }
    assert!(count > 0, "no fixtures found in {}", dir.display());
    assert!(failures.is_empty(), "\n{}", failures.join("\n"));
}
