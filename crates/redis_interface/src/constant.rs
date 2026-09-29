//! Shared constants for the redis_interface crate.
//!
//! Backend-specific command string constants live in each backend's module.

/// Redis commands used in redis::cmd() and pipe.cmd() calls (redis-rs backend)
#[cfg(feature = "redis-rs")]
pub mod redis_rs_commands {
    pub const REDIS_COMMAND_SET: &str = "SET";
    pub const REDIS_COMMAND_GET: &str = "GET";
    pub const REDIS_COMMAND_HSCAN: &str = "HSCAN";
    pub const REDIS_COMMAND_SCAN: &str = "SCAN";

    /// Redis arguments used in .arg() calls
    pub const REDIS_ARG_EX: &str = "EX";
    pub const REDIS_ARG_NX: &str = "NX";
    pub const REDIS_ARG_MATCH: &str = "MATCH";
    pub const REDIS_ARG_COUNT: &str = "COUNT";
    pub const REDIS_ARG_TYPE: &str = "TYPE";
    /// Default reconnect max attempts, matching RedisSettings::default().reconnect_max_attempts
    pub const DEFAULT_RECONNECT_MAX_ATTEMPTS: usize = 5;
    /// Minimum error check interval in seconds (used in `on_error`).
    pub const MIN_ERROR_CHECK_INTERVAL_SECS: u64 = 1;
    /// Safety limit for HSCAN/SCAN iterations to guard against a corrupted cursor
    /// that never returns to 0. 1000 iterations × default COUNT(100) = ~100K entries.
    pub const MAX_SCAN_ITERATIONS: u32 = 1000;
}

/// Deletes every consumer of group `ARGV[1]` on stream `KEYS[1]`, other than `ARGV[2]`, that has
/// no pending entries and has been idle for at least `ARGV[3]` milliseconds. Returns the number of
/// consumers deleted. Runs as a script so no consumer can read between the check and the delete.
pub const DELETE_IDLE_CONSUMERS_SCRIPT: &str = r#"
local deleted = 0
for _, consumer in ipairs(redis.call("XINFO", "CONSUMERS", KEYS[1], ARGV[1])) do
    local info = {}
    for i = 1, #consumer, 2 do
        info[consumer[i]] = consumer[i + 1]
    end
    if info["name"] ~= ARGV[2] and info["pending"] == 0 and info["idle"] >= tonumber(ARGV[3]) then
        redis.call("XGROUP", "DELCONSUMER", KEYS[1], ARGV[1], info["name"])
        deleted = deleted + 1
    end
end
return deleted
"#;
