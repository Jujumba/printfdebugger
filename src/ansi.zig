//! Some ANSI escape sequences
const escape = "\x1b";
pub const reset = escape ++ "[0m";

pub const bold = escape ++ "[1m";

pub const greenfg = escape ++ "[32m";
pub const magentafg = escape ++ "[35m";

pub const brredfg = escape ++ "[91m";
pub const brblackfg = escape ++ "[90m";
pub const brgreenfg = escape ++ "[92m";
pub const bryellowfg = escape ++ "[93m";
