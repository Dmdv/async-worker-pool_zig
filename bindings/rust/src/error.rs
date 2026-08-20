//! Typed error types for awp-zig-rs.

use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AwpError {
    /// Invalid configuration or argument (-EINVAL).
    InvalidArg,
    /// Feed, symbol, or payload exceeds buffer limit (-E2BIG).
    TooBig,
    /// Queue is full or backpressured (-EAGAIN).
    QueueFull,
    /// Out of memory during initialization (-ENOMEM).
    OutOfMemory,
    /// Generic error code returned by libawp_zig.
    Failed(i32),
}

impl fmt::Display for AwpError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            AwpError::InvalidArg => write!(f, "Invalid argument or configuration (EINVAL)"),
            AwpError::TooBig => write!(f, "Payload or identifier exceeds buffer limit (E2BIG)"),
            AwpError::QueueFull => write!(f, "Queue is full (EAGAIN)"),
            AwpError::OutOfMemory => write!(f, "Out of memory during allocation (ENOMEM)"),
            AwpError::Failed(rc) => {
                write!(f, "libawp_zig operation failed with error code: {}", rc)
            }
        }
    }
}

impl std::error::Error for AwpError {}

impl From<i32> for AwpError {
    fn from(rc: i32) -> Self {
        match rc {
            -22 => AwpError::InvalidArg,
            -7 => AwpError::TooBig,
            -11 => AwpError::QueueFull,
            -12 => AwpError::OutOfMemory,
            code => AwpError::Failed(code),
        }
    }
}
