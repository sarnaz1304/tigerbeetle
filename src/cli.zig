const std = @import("std");
const assert = std.debug.assert;
const fmt = std.fmt;
const mem = std.mem;
const meta = std.meta;
const net = std.net;
const os = std.os;

const config = @import("config.zig");
const vsr = @import("vsr.zig");

const usage = fmt.comptimePrint(
    \\Usage:
    \\
    \\  tigerbeetle [-h | --help]
    \\
    \\  tigerbeetle format --cluster=<integer> --replica=<index> <path>
    \\
    \\  tigerbeetle start --addresses=<addresses> <path>
    \\
    \\Commands:
    \\
    \\  format  Create a TigerBeetle replica data file at <path>.
    \\          The --cluster and --replica arguments are required.
    \\          Each TigerBeetle replica must have its own data file.
    \\
    \\  start   Run a TigerBeetle replica from the data file at <path>.
    \\
    \\Options:
    \\
    \\  -h, --help
    \\        Print this help message and exit.
    \\
    \\  --cluster=<integer>
    \\        Set the cluster ID to the provided 32-bit unsigned integer.
    \\
    \\  --replica=<index>
    \\        Set the zero-based index that will be used for the replica process.
    \\        The value of this argument will be interpreted as an index into the --addresses array.
    \\
    \\  --addresses=<addresses>
    \\        Set the addresses of all replicas in the cluster.
    \\        Accepts a comma-separated list of IPv4 addresses with port numbers.
    \\        Either the IPv4 address or port number (but not both) may be omitted,
    \\        in which case a default of {[default_address]s} or {[default_port]d}
    \\        will be used.
    \\
    \\Examples:
    \\
    \\  tigerbeetle format --cluster=7 --replica=0 7_0.tigerbeetle
    \\  tigerbeetle format --cluster=7 --replica=1 7_1.tigerbeetle
    \\  tigerbeetle format --cluster=7 --replica=2 7_2.tigerbeetle
    \\
    \\  tigerbeetle start --addresses=127.0.0.1:3003,127.0.0.1:3001,127.0.0.1:3002 7_0.tigerbeetle
    \\  tigerbeetle start --addresses=3003,3001,3002 7_1.tigerbeetle
    \\  tigerbeetle start --addresses=3003,3001,3002 7_2.tigerbeetle
    \\
    \\  tigerbeetle start --addresses=192.168.0.1,192.168.0.2,192.168.0.3 7_0.tigerbeetle
    \\
, .{
    .default_address = config.address,
    .default_port = config.port,
});

pub const Command = union(enum) {
    format: struct {
        cluster: u32,
        replica: u8,
        path: [:0]const u8,
    },
    start: struct {
        addresses: []net.Address,
        path: [:0]const u8,
    },
};

/// Parse the command line arguments passed to the `tigerbeetle` binary.
/// Exits the program with a non-zero exit code if an error is found.
pub fn parse_args(allocator: std.mem.Allocator) Command {
    var path: ?[:0]const u8 = null;
    var cluster: ?[]const u8 = null;
    var replica: ?[]const u8 = null;
    var addresses: ?[]const u8 = null;

    var args = std.process.args();

    // Skip argv[0] which is the name of this executable.
    _ = args.nextPosix();

    const raw_command = args.nextPosix() orelse
        fatal("no command provided, expected 'start' or 'format'", .{});
    if (mem.eql(u8, raw_command, "-h") or mem.eql(u8, raw_command, "--help")) {
        std.io.getStdOut().writeAll(usage) catch os.exit(1);
        os.exit(0);
    }
    const command = meta.stringToEnum(meta.Tag(Command), raw_command) orelse
        fatal("unknown command '{s}', expected 'start' or 'format'", .{raw_command});

    while (args.nextPosix()) |arg| {
        if (mem.startsWith(u8, arg, "--cluster")) {
            cluster = parse_flag("--cluster", arg);
        } else if (mem.startsWith(u8, arg, "--replica")) {
            replica = parse_flag("--replica", arg);
        } else if (mem.startsWith(u8, arg, "--addresses")) {
            addresses = parse_flag("--addresses", arg);
        } else if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
            std.io.getStdOut().writeAll(usage) catch os.exit(1);
            os.exit(0);
        } else if (mem.startsWith(u8, arg, "-")) {
            fatal("unexpected argument: '{s}'", .{arg});
        } else if (path == null) {
            path = arg;
        } else {
            fatal("unexpected argument: '{s}' (must start with '--')", .{arg});
        }
    }

    switch (command) {
        .format => {
            if (addresses != null) fatal("--addresses: supported only by 'start' command", .{});

            return .{
                .format = .{
                    .cluster = parse_cluster(cluster orelse fatal("required: --cluster", .{})),
                    .replica = parse_replica(replica orelse fatal("required: --replica", .{})),
                    .path = path orelse fatal("required: <path>", .{}),
                },
            };
        },
        .start => {
            if (cluster != null) fatal("--cluster: supported only by 'format' command", .{});
            if (replica != null) fatal("--replica: supported only by 'format' command", .{});

            return .{
                .start = .{
                    .addresses = parse_addresses(
                        allocator,
                        addresses orelse fatal("required: --addresses", .{}),
                    ),
                    .path = path orelse fatal("required: <path>", .{}),
                },
            };
        },
    }
}

/// Format and print an error message followed by the usage string to stderr,
/// then exit with an exit code of 1.
pub fn fatal(comptime fmt_string: []const u8, args: anytype) noreturn {
    const stderr = std.io.getStdErr().writer();
    stderr.print("error: " ++ fmt_string ++ "\n", args) catch {};
    os.exit(1);
}

/// Parse e.g. `--cluster=1a2b3c` into `1a2b3c` with error handling.
fn parse_flag(comptime flag: []const u8, arg: [:0]const u8) [:0]const u8 {
    const value = arg[flag.len..];
    if (value.len < 2) {
        fatal("{s} argument requires a value", .{flag});
    }
    if (value[0] != '=') {
        fatal("expected '=' after '{s}' but found '{c}'", .{ flag, value[0] });
    }
    return value[1..];
}

fn parse_cluster(raw_cluster: []const u8) u32 {
    const cluster = fmt.parseUnsigned(u32, raw_cluster, 10) catch |err| switch (err) {
        error.Overflow => fatal("--cluster: value exceeds a 32-bit unsigned integer", .{}),
        error.InvalidCharacter => fatal("--cluster: value contains an invalid character", .{}),
    };
    return cluster;
}

/// Parse and allocate the addresses returning a slice into that array.
fn parse_addresses(allocator: std.mem.Allocator, raw_addresses: []const u8) []net.Address {
    return vsr.parse_addresses(allocator, raw_addresses) catch |err| switch (err) {
        error.AddressHasTrailingComma => fatal("--addresses: invalid trailing comma", .{}),
        error.AddressLimitExceeded => {
            fatal("--addresses: too many addresses, at most {d} are allowed", .{
                config.replicas_max,
            });
        },
        error.AddressHasMoreThanOneColon => {
            fatal("--addresses: invalid address with more than one colon", .{});
        },
        error.PortOverflow => fatal("--addresses: port exceeds 65535", .{}),
        error.PortInvalid => fatal("--addresses: invalid port", .{}),
        error.AddressInvalid => fatal("--addresses: invalid IPv4 address", .{}),
        error.OutOfMemory => fatal("--addresses: out of memory", .{}),
    };
}

fn parse_replica(raw_replica: []const u8) u8 {
    comptime assert(config.replicas_max <= std.math.maxInt(u8));
    const replica = fmt.parseUnsigned(u8, raw_replica, 10) catch |err| switch (err) {
        error.Overflow => fatal("--replica: value exceeds an 8-bit unsigned integer", .{}),
        error.InvalidCharacter => fatal("--replica: value contains an invalid character", .{}),
    };
    return replica;
}
