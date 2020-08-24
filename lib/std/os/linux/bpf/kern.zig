pub const helpers = @import("helpers.zig");
const std = @import("std");
const assert = std.debug.assert;
usingnamespace std.os.linux.BPF;

pub const MapDef = packed struct {
    type: MapType,
    key_size: u32,
    value_size: u32,
    max_entries: u32,
    flags: u32,
};

pub const bpf_flow_keys = extern struct {
    nhoff: u16,
    thoff: u16,
    /// ETH_P_* of valid addrs
    addr_proto: u16,
    is_frag: u8,
    is_first_frag: u8,
    is_encap: u8,
    ip_proto: u8,
    // be16
    n_proto: u16,
    // be16
    sport: u16,
    // be16
    dport: u16,
    addrs: extern union {
        ipv4: extern struct {
            // be32
            src: u32,
            // be32
            dst: u32,
        },
        ipv6: extern struct {
            // network order
            src: [4]u32,
            // network order
            dst: [4]u32,
        },
    },
    flags: u32,
    // be32
    flow_label: u32,
};

pub const bpf_sock = extern struct {
    bound_dev_if: u32,
    family: u32,
    type: u32,
    protocol: u32,
    mark: u32,
    priority: u32,
    /// IP address also allows 1 and 2 bytes access
    src_ip4: u32,
    src_ip6: [4]u32,
    /// host byte order
    src_port: u32,
    /// network byte order
    dst_port: u32,
    dst_ip4: u32,
    dst_ip6: [4]u32,
    state: u32,
};

pub const __sk_buff = extern struct {
    len: u32,
    pkt_type: u32,
    mark: u32,
    queue_mapping: u32,
    protocol: u32,
    vlan_present: u32,
    vlan_tci: u32,
    vlan_proto: u32,
    priority: u32,
    ingress_ifindex: u32,
    ifindex: u32,
    tc_index: u32,
    cb: [5]u32,
    hash: u32,
    tc_classid: u32,
    data: u32,
    data_end: u32,
    napi_id: u32,

    // Accessed by BPF_PROG_TYPE_sk_skb types from here to ...
    family: u32,
    /// Stored in network byte order
    remote_ip4: u32,
    /// Stored in network byte order
    local_ip4: u32,
    /// Stored in network byte order
    remote_ip6: [4]u32,
    /// Stored in network byte order
    local_ip6: [4]u32,
    /// Stored in network byte order
    remote_port: u32,
    /// Stored in host byte order
    local_port: u32,
    // ... here.

    data_meta: u32,
    flow_keys: extern union {
        val: *bpf_flow_keys,
        _: u64,
    },
    tstamp: u64,
    wire_len: u32,
    gso_segs: u32,
    sk: extern union {
        val: *bpf_sock,
        _: u64,
    },
};

pub fn trace_printk(comptime fmt: []const u8, args: []u64) !u32 {
    const rc = switch (args.len) {
        0 => helpers.trace_printk(fmt.ptr, fmt.len, 0, 0, 0),
        1 => helpers.trace_printk(fmt.ptr, fmt.len, args[0], 0, 0),
        2 => helpers.trace_printk(fmt.ptr, fmt.len, args[0], args[1], 0),
        3 => helpers.trace_printk(fmt.ptr, fmt.len, args[0], args[1], args[2]),
        else => @compileError("Maximum 3 args for trace_printk"),
    };

    return switch (rc) {
        0...std.math.maxInt(c_int) => @intCast(u32, rc),
        EINVAL => error.Invalid,
        else => error.UnknownError,
    };
}

// TODO: add
//  - perf_event_output
//  - perf_event_read
//  to methods
pub const PerfEventArray = Map(u32, u32, .perf_event_array, 0);

pub fn Map(comptime Key: type, comptime Value: type, map_type: MapType, entries: u32) type {
    return struct {
        def: MapDef,

        const Self = @This();

        pub fn init() Self {
            return .{
                .def = .{
                    .type = map_type,
                    .key_size = @sizeOf(Key),
                    .value_size = @sizeOf(Value),
                    .max_entries = entries,
                    .flags = 0,
                },
            };
        }

        pub fn lookup(self: *const Self, key: *const Key) ?*Value {
            return @ptrCast(?*Value, @alignCast(@alignOf(?*Value), helpers.map_lookup_elem(&self.def, key)));
        }

        pub fn update(self: *const Self, flags: UpdateFlags, key: *const Key, value: *const Value) !void {
            switch (helpers.map_update_elem(&self.def, key, value, @enumToInt(flags))) {
                0 => return,
                else => return error.UnknownError,
            }
        }

        pub fn delete(self: *const Self, key: *const Key) !void {
            switch (helpers.map_delete_elem(&self.def, key)) {
                0 => return,
                else => return error.UnknownError,
            }
        }
    };
}

pub const ktime_get_ns = helpers.ktime_get_ns;
pub const get_prandom_u32 = helpers.get_prandom_u32;
pub const get_smp_processor_id = helpers.get_smp_processor_id;
pub const get_current_pid_tgid = helpers.get_current_pid_tgid;
pub const get_current_uid_gid = helpers.get_current_uid_gid;
pub const get_cgroup_classid = helpers.get_cgroup_classid;

pub fn probe_read(comptime T: type, dst: []T, src: []const T) !void {
    if (dst.len < src.len) {
        return error.TooBig;
    }

    switch (helpers.probe_read(dst.ptr, src.len * @sizeOf(T), src.ptr)) {
        0 => return,
        else => return error.UnknownError,
    }
}

pub fn probe_read_user_str(dst: []u8, src: *const [*:0]u8) !void {
    switch (helpers.probe_read_user_str(dst.ptr, @truncate(u32, dst.len), @ptrCast(*const c_void, src))) {
        0 => return,
        else => return error.UnknownError,
    }
}

pub fn skb_store_bytes(skb: *SkBuff, offset: u32, from: []const u8, flags: u64) !void {
    switch (helpers.skb_store_bytes(skb, offset, from.ptr, from.len, flags)) {
        0 => return,
        else => return error.UnknownError,
    }
}

pub fn l3_csum_replace(skb: *SkBuff, offset: u32, from: u64, to: u64, size: u64) !void {
    switch (helpers.l3_csum_replace(skb, offset, from, to, size)) {
        0 => return,
        else => return error.UnknownError,
    }
}

pub fn l4_csum_replace(skb: *SkBuff, offset: u32, from: u64, to: u64, flags: u64) !void {
    switch (helpers.l4_csum_replace(skb, offset, from, to, flags)) {
        0 => return,
        else => return error.UnknownError,
    }
}

pub fn tail_call(ctx: anytype, map: *ProgArrayMap, index: u32) !void {
    switch (helpers.tail_call(ctx, map, index)) {
        0 => return,
        else => return error.UnknownError,
    }
}

pub fn clone_redirect(skb: *SkBuff, ifindex: u32, flags: u64) !void {
    switch (helpers.clone_redirect(skb, ifindex, flags)) {
        0 => return,
        else => return error.UnknownError,
    }
}

pub fn get_current_comm(buf: []u8) !void {
    switch (helpers.get_current_comm(buf.ptr, @truncate(u32, buf.len))) {
        0 => return,
        else => return error.UnknownError,
    }
}

pub fn skb_vlan_push(skb: *SkBuff, vlan_proto: u16, vlan_tci: u16) !void {
    switch (helpers.skb_vlan_push(skb, vlan_proto, vlan_tci)) {
        0 => return,
        else => return error.UnknownError,
    }
}

pub fn skb_vlan_pop(skb: *SkBuff) !void {
    switch (helpers.skb_vlan_pop(skb)) {
        0 => return,
        else => return error.UnknownError,
    }
}

pub fn skb_get_tunnel_key(skb: *SkBuff, key: *TunnelKey, size: u32, flags: u64) !void {
    switch (helpers.skb_get_tunnel_key(skb, key, size, flags)) {
        0 => return,
        else => return error.UnknownError,
    }
}

pub fn skb_set_tunnel_key(skb: *SkBuff, key: TunnelKey, size: u32, flags: u64) !void {
    switch (helpers.skb_set_tunnel_key(skb, key, size, flags)) {
        0 => return,
        else => return error.UnknownError,
    }
}

// TODO split bpf_direct for Xdp and non-xdp programs

pub fn get_route_realm(skb: *SkBuff) ?u32 {
    const ret = helpers.get_route_realm(skb);
    return if (ret == 0) null else ret;
}

const PerfEventOutputFlags = enum(u64) {
    current_cpu = 0xffffffff,
};

pub fn perf_event_output(ctx: anytype, map: *const MapDef, flags: PerfEventOutputFlags, data: []u8) !void {
    switch (helpers.perf_event_output(ctx, map, @enumToInt(flags), data.ptr, data.len)) {
        0 => return,
        else => return error.UnknownError,
    }
}

test "zigified bpf helpers" {
    const BPF = @import("../bpf.zig");
    inline for (std.meta.fields(BPF.Helper)) |field| {
        expect(@hasDecl(@This(), field.name));
    }
}
