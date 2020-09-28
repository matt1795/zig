// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2020 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.
const std = @import("../../../std.zig");
const BPF = std.os.linux.BPF;

pub const helpers = switch (std.builtin.arch) {
    .bpfel, .bpfeb => @import("helpers.zig"),
    else => struct {},
};

pub const MapDef = extern struct {
    type: u32,
    key_size: u32,
    value_size: u32,
    max_entries: u32,
    map_flags: u32,
};

pub fn Map(
    comptime Key: type,
    comptime Value: type,
) type {
    return struct {
        def: MapDef,

        const Self = @This();

        pub fn init(map_type: BPF.MapType, max_entries: u32, flags: u32) Self {
            return Self{
                .def = MapDef{
                    .type = @enumToInt(map_type),
                    .key_size = @sizeOf(Key),
                    .value_size = @sizeOf(Value),
                    .max_entries = max_entries,
                    .map_flags = flags,
                },
            };
        }

        /// Perform a lookup in *map* for an entry associated to *key*.
        pub fn lookup(self: Self, key: Key) ?*Value {
            return @ptrCast(?*Value, @alignCast(@alignOf(?*Value), helpers.map_lookup_elem(@ptrCast(*const MapDef, &self), &key)));
        }

        /// Add or update the value of the entry associated to *key* in *map* with
        /// *value*. *flags* is one of:
        ///
        /// **BPF_NOEXIST**
        ///     The entry for *key* must not exist in the map.
        /// **BPF_EXIST**
        /// 	The entry for *key* must already exist in the map.
        /// **BPF_ANY**
        /// 	No condition on the existence of the entry for *key*.
        ///
        /// Flag value **BPF_NOEXIST** cannot be used for maps of types
        /// **BPF_MAP_TYPE_ARRAY** or **BPF_MAP_TYPE_PERCPU_ARRAY**  (all elements
        /// always exist), the helper would return an error.
        pub fn update(self: Self, key: Key, value: Value, flags: u64) !void {
            const rc = helpers.map_update_elem(@ptrCast(*const MapDef, &self), &key, &value, flags);
            return switch (rc) {
                0 => {},
                else => error.Unknown,
            };
        }

        /// Delete entry with *key* from *map*.
        pub fn delete(self: Self, key: Key) !void {
            const rc = helpers.map_delete_elem(@ptrCast(*const MapDef, &self), &key);
            return switch (rc) {
                0 => {},
                else => error.Unknown,
            };
        }
    };
}

pub fn HashMap(
    comptime Key: type,
    comptime Value: type,
) type {
    return struct {
        map: Map(Key, Value),

        const Self = @This();

        pub fn init(max_entries: u32, flags: u32) Self {
            return .{
                .map = Map(Key, Value).init(.hash, max_entries, flags),
            };
        }

        pub fn lookup(self: Self, key: Key) ?*Value {
            return self.map.lookup(key);
        }

        pub fn update(self: Self, key: Key, value: Value, flags: u64) !void {
            return self.map.update(key, value, flags);
        }

        pub fn delete(self: Self, key: Key) !void {
            return self.map.delete(key);
        }
    };
}

pub fn ArrayMap(comptime Value: type) type {
    return struct {
        map: Map(u32, Value),

        const Self = @This();

        pub fn init(max_entries: u32, flags: u32) Self {
            return .{
                .map = Map(u32, Value).init(.array, max_entries, flags),
            };
        }

        pub fn lookup(self: Self, key: u32) ?*Value {
            return self.map.lookup(key);
        }

        pub fn update(self: Self, key: u32, value: Value, flags: u64) !void {
            return self.map.update(key, value, flags);
        }

        pub fn delete(self: Self, key: u32) !void {
            return self.map.delete(key);
        }
    };
}

pub const PerfEventArray = struct {
    map: Map(u32, u32),

    const Self = @This();

    pub fn init(max_entries: u32, flags: u32) Self {
        return .{
            .map = Map(u32, u32).init(.perf_event_array, max_entries, flags),
        };
    }

    /// Write raw `data` blob into a special BPF perf event held by `self` (must
    /// be `.perf_event_array` as `map_type`). The perf event must have the
    /// following attributes:
    ///
    /// - `PERF_SAMPLE_RAW` as `sample_type`
    /// - `PERF_TYPE_SOFTWARE` as `type`
    /// - `PERF_COUNT_SW_BPF_OUTPUT` as `config`
    ///
    /// The `flags` are used to indicate the index in this map for which the
    /// value must be put, masked with `BPF_F_INDEX_MASK`.  Alternatively,
    /// `flags` can be set to `BPF_F_CURRENT_CPU` to indicate that the index of
    /// the current CPU core should be used.
    ///
    /// The value to write, `data`, is passed through eBPF stack.
    ///
    /// The context of the program `ctx` needs also be passed.
    ///
    /// In user space, a program willing to read the values needs to call
    /// `perf_event_open()` on the perf event (either for one or for all CPUs)
    /// and to store the file descriptor into the map. This must be done before
    /// the eBPF program can send data into it. An example is available in file
    /// `samples/bpf/trace_output_user.c` in the Linux kernel source tree (the
    /// eBPF program counterpart is in `samples/bpf/trace_output_kern.c`).
    ///
    /// `perf_event_output()` achieves better performance than
    /// `bpf_trace_printk()` for sharing data with user space, and is much
    /// better suitable for streaming data from eBPF programs.
    ///
    /// Note that this is not restricted to tracing use cases and can be used
    /// with programs attached to TC or XDP as well, where it allows for passing
    /// data to user space listeners. Data can be:
    ///
    /// - Only custom structs,
    /// - Only the packet payload, or
    /// - A combination of both.
    pub fn event_output(self: Self, ctx: anytype, flags: u64, data: []u8) !void {
        const rc = helpers.perf_event_output(ctx, @ptrCast(*const MapDef, &self), flags, data.ptr, data.len);
        return switch (rc) {
            0 => {},
            else => error.Unknown,
        };
    }
};

/// Return the time elapsed since system boot, in nanoseconds.  Does not include
/// time the system was suspended.
pub const ktime_get_ns = helpers.ktime_get_ns;

pub const BpfSock = @Type(.Opaque);
pub const BpfSockAddr = @Type(.Opaque);
pub const FibLookup = @Type(.Opaque);
pub const PerfEventData = @Type(.Opaque);
pub const PerfEventValue = @Type(.Opaque);
pub const PidNsInfo = @Type(.Opaque);
pub const SeqFile = @Type(.Opaque);
pub const SkBuff = @Type(.Opaque);
pub const SkMsgMd = @Type(.Opaque);
pub const SkReusePortMd = @Type(.Opaque);
pub const Sock = @Type(.Opaque);
pub const SockAddr = @Type(.Opaque);
pub const SockOps = @Type(.Opaque);
pub const SockTuple = @Type(.Opaque);
pub const SpinLock = @Type(.Opaque);
pub const SysCtl = @Type(.Opaque);
pub const Tcp6Sock = @Type(.Opaque);
pub const TcpRequestSock = @Type(.Opaque);
pub const TcpSock = @Type(.Opaque);
pub const TcpTimewaitSock = @Type(.Opaque);
pub const TunnelKey = @Type(.Opaque);
pub const Udp6Sock = @Type(.Opaque);
pub const XdpMd = @Type(.Opaque);
pub const XfrmState = @Type(.Opaque);
