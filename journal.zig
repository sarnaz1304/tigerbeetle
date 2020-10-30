const std = @import("std");
const assert = std.debug.assert;
const fs = std.fs;
const log = std.log.scoped(.journal);
const mem = std.mem;
const os = std.os;

const config = @import("config.zig");

usingnamespace @import("types.zig");
usingnamespace @import("state.zig");

pub const Journal = struct {
                   state: *State,
                    file: fs.File,
         hash_chain_root: u128,
    prev_hash_chain_root: u128,
                  offset: u64,

    pub fn init(state: *State) !Journal {
        const path = "journal";
        const file = try Journal.open(path);
        errdefer file.close();

        var self = Journal {
            .state = state,
            .file = file,
            .hash_chain_root = 0,
            .prev_hash_chain_root = 0,
            .offset = 0,
        };

        log.debug("opened fd={}", .{ self.file.handle });
        try self.read();
        return self;
    }

    pub fn deinit(self: *Journal) void {
        self.file.close();
    }

    /// Append a batch of events to the journal:
    /// The journal will overwrite the 64-byte header in place at the front of the buffer.
    /// The buffer pointer address must be aligned to config.sector_size for direct I/O.
    /// The buffer length must similarly be a multiple of config.sector_size.
    /// `size` may be less than the sector multiple, but the remainder must already be zero padded.
    pub fn append(self: *Journal, command: Command, size: u32, buffer: []u8) !void {
        assert(@mod(@ptrToInt(buffer.ptr), config.sector_size) == 0);
        assert(@sizeOf(JournalHeader) == @sizeOf(NetworkHeader));
        assert(size >= @sizeOf(JournalHeader));
        assert(@mod(buffer.len, config.sector_size) == 0);
        assert(buffer.len == Journal.sector_multiple(size, config.sector_size));
        assert(buffer.len >= size);
        assert(buffer.len < size + config.sector_size);

        // Write the entry header to the front of the buffer:
        var entry = mem.bytesAsValue(JournalHeader, buffer[0..@sizeOf(JournalHeader)]);
        entry.* = .{
            .prev_checksum_meta = self.hash_chain_root,
            .offset = self.offset,
            .command = command,
            .size = size
        };
        // Zero padding is not included in the checksum since it is not material except to prevent
        // buffer bleeds, which we assert against next in Debug mode:
        entry.set_checksum_data(buffer[@sizeOf(JournalHeader)..size]);
        entry.set_checksum_meta();

        if (std.builtin.mode == .Debug) {
            // Assert that the last sector's padding (if any) is already zeroed:
            var sum_of_sector_padding_bytes: usize = 0;
            for (buffer[size..]) |byte| sum_of_sector_padding_bytes += byte;
            assert(sum_of_sector_padding_bytes == 0);
        }

        // Write the journal entry to the end of the journal:
        log.debug("appending {} bytes at offset {}: {}", .{
            buffer.len,
            self.offset,
            entry
        });
        try self.file.pwriteAll(buffer, self.offset);
        try os.fsync(self.file.handle);

        // Update journal state:
        self.hash_chain_root = entry.checksum_meta;
        self.prev_hash_chain_root = entry.prev_checksum_meta;
        self.offset += buffer.len;
    }

    pub fn read(self: *Journal) !void {
        var buffer: [config.request_size_max]u8 align(config.sector_size) = undefined;
        var output: [16384]u8 = undefined;
        assert(@mod(@ptrToInt(&buffer), config.sector_size) == 0);
        assert(@mod(buffer.len, config.sector_size) == 0);

        while (true) {
            var bytes_read = try self.file.preadAll(buffer[0..], self.offset);
            log.debug("read[0..{}]={}", .{ buffer.len, bytes_read });

            var buffer_offset: usize = 0;
            while (buffer_offset < bytes_read) {
                const entry = mem.bytesAsValue(
                    JournalHeader,
                    buffer[buffer_offset..][0..@sizeOf(JournalHeader)]
                );
                log.debug("{}", .{ entry });

                if (!entry.valid_checksum_meta()) return error.JournalEntryHeaderCorrupt;
                const entry_data = buffer[buffer_offset..][@sizeOf(JournalHeader)..entry.size];
                if (!entry.valid_checksum_data(entry_data)) return error.JournalEntryDataCorrupt;
                if (entry.prev_checksum_meta != self.hash_chain_root) {
                    return error.JournalEntryMisdirectedWrite;
                }

                _ = self.state.apply(entry.command, entry_data, output[0..]);

                self.hash_chain_root = entry.checksum_meta;
                self.prev_hash_chain_root = entry.prev_checksum_meta;
                buffer_offset += Journal.sector_multiple(entry.size, config.sector_size);
            }
            assert(buffer_offset == bytes_read);

            self.offset += buffer_offset;
            if (bytes_read < buffer.len) break;
        }
    }

    fn create(path: []const u8) !fs.File {
        try std.fs.cwd().createFile(path, .{
            .read = true,
            .exclusive = true,
            .truncate = false,
            .lock = .Exclusive,
            .mode = 0o666,
        });
    }

    fn open(path: []const u8) !fs.File {
        // TODO Figure out absolute path to journal file regardless of the server's cwd.
        log.debug("opening {}...", .{ path });
        return std.fs.cwd().openFile(path, .{
            .read = true,
            .write = true,
            .lock = .Exclusive,
        }) catch |err| switch (err) {
            error.FileNotFound => {
                log.debug("creating {}...", .{ path });
                return try std.fs.cwd().createFile(path, .{
                    .read = true,
                    .exclusive = true,
                    .truncate = false,
                    .lock = .Exclusive,
                    .mode = 0o666,
                });
            },
            else => return err,
        };
    }

    pub fn sector_multiple(entry_size: u64, sector_size: u64) u64 {
        assert(entry_size > 0);
        assert(sector_size > 0);
        assert(std.math.isPowerOfTwo(sector_size));
        const sectors = std.math.divCeil(u64, entry_size, sector_size) catch unreachable;
        assert(sectors > 0);
        const rounded = sectors * sector_size;
        assert(rounded >= entry_size);
        assert(rounded < entry_size + sector_size);
        return rounded;
    }
};

const testing = std.testing;

test "sector_multiple()" {
    const sector_size: u64 = 4096;
    testing.expectEqual(sector_size, Journal.sector_multiple(1, sector_size));
    testing.expectEqual(sector_size, Journal.sector_multiple(sector_size - 1, sector_size));
    testing.expectEqual(sector_size, Journal.sector_multiple(sector_size, sector_size));
    testing.expectEqual(sector_size * 2, Journal.sector_multiple(sector_size + 1, sector_size));
}