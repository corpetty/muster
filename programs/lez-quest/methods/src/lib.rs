// This crate exists only to host the risc0 build infrastructure.
// The guest binary is guest/src/bin/quest.rs.
include!(concat!(env!("OUT_DIR"), "/methods.rs"));
