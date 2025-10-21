const std = @import("std");

pub fn baselinePass(allocator: std.mem.Allocator, meshlet_count: usize) !u32 {
    if (meshlet_count == 0) return 0;

    const visibility = try allocator.alloc(bool, meshlet_count);
    defer allocator.free(visibility);
    const jobs = try allocator.alloc(u8, meshlet_count);
    defer allocator.free(jobs);
    const completion = try allocator.alloc(bool, meshlet_count);
    defer allocator.free(completion);

    @memset(visibility, true);
    @memset(completion, false);

    var checksum: u32 = 0;
    var i: usize = 0;
    while (i < meshlet_count) : (i += 1) {
        jobs[i] = @as(u8, @truncate(i));
        if ((i & 1) == 0) completion[i] = true;
        if (completion[i]) checksum ^= @as(u32, @intCast(i));
    }
    return checksum;
}

pub const JobCache = struct {
    allocator: std.mem.Allocator,
    visibility: []bool = &[_]bool{},
    jobs: []u8 = &[_]u8{},
    completion: []bool = &[_]bool{},

    pub fn init(allocator: std.mem.Allocator) JobCache {
        return JobCache{
            .allocator = allocator,
        };
    }

    pub fn ensureCapacity(self: *JobCache, count: usize) !void {
        if (count == 0) return;

        if (self.visibility.len < count) {
            if (self.visibility.len != 0) self.allocator.free(self.visibility);
            self.visibility = try self.allocator.alloc(bool, count);
        }
        if (self.jobs.len < count) {
            if (self.jobs.len != 0) self.allocator.free(self.jobs);
            self.jobs = try self.allocator.alloc(u8, count);
        }
        if (self.completion.len < count) {
            if (self.completion.len != 0) self.allocator.free(self.completion);
            self.completion = try self.allocator.alloc(bool, count);
        }
    }

    pub fn deinit(self: *JobCache) void {
        if (self.visibility.len != 0) self.allocator.free(self.visibility);
        if (self.jobs.len != 0) self.allocator.free(self.jobs);
        if (self.completion.len != 0) self.allocator.free(self.completion);
        self.visibility = &[_]bool{};
        self.jobs = &[_]u8{};
        self.completion = &[_]bool{};
    }

    pub fn cachedPass(self: *JobCache, meshlet_count: usize) !u32 {
        if (meshlet_count == 0) return 0;
        try self.ensureCapacity(meshlet_count);

        const visibility = self.visibility[0..meshlet_count];
        const jobs = self.jobs[0..meshlet_count];
        const completion = self.completion[0..meshlet_count];

        @memset(visibility, true);
        @memset(completion, false);

        var checksum: u32 = 0;
        var i: usize = 0;
        while (i < meshlet_count) : (i += 1) {
            jobs[i] = @as(u8, @truncate(i));
            if ((i & 1) == 0) completion[i] = true;
            if (completion[i]) checksum ^= @as(u32, @intCast(i));
        }
        return checksum;
    }
};
