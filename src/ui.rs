//! Terminal UI helpers: pacman-flavoured output and interactive prompts
//! (always degrading gracefully when not attached to a TTY).

use console::{style, Term};

pub fn is_interactive() -> bool {
    Term::stdout().features().is_attended() && Term::stderr().features().is_attended()
}

pub fn info(msg: &str) {
    println!("{} {msg}", style("==>").green().bold());
}

pub fn warn(msg: &str) {
    println!("{} {msg}", style("!!>").yellow().bold());
}

/// Yes/no prompt; non-interactive defaults to `false`.
pub fn confirm(prompt: &str) -> bool {
    if !is_interactive() {
        return false;
    }
    inquire::Confirm::new(prompt)
        .with_default(false)
        .prompt()
        .unwrap_or(false)
}

/// A second, explicit confirmation for destructive operations.
pub fn confirm_dangerous(prompt: &str) -> bool {
    if !is_interactive() {
        return false;
    }
    match inquire::Text::new(&format!("{prompt} Type 'yes' to proceed:")).prompt() {
        Ok(s) => s.eq_ignore_ascii_case("yes"),
        Err(_) => false,
    }
}
