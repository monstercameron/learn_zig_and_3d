//! # A Multi-threaded Job System for Parallel Execution
//!
//! This module implements a work-stealing job system tuned for CPU-heavy frame workloads.
//! It uses Chase-Lev worker deques plus lock-free injected submission stacks for cross-thread
//! work, and supports cooperative waiting where the waiting thread helps drain queued work.

const std = @import("std");
const job_logger = std.log.scoped(.jobs_core);
const worker_local_queue_capacity: u32 = 256;

threadlocal var tls_worker_id: ?u32 = null;

// ========== JOB STRUCTURE ==========

/// A job function signature. All jobs are functions that take a single, generic pointer for context.
pub const JobFn = *const fn (ctx: *anyopaque) void;

pub const JobClass = enum(u8) {
    high,
    normal,
    background,

    fn index(self: JobClass) usize {
        return @intFromEnum(self);
    }
};

const injected_queue_count: usize = @typeInfo(JobClass).@"enum".fields.len;

/// A `Job` represents a single unit of work that can be executed by any worker thread.
pub const Job = struct {
    function: JobFn,
    context: *anyopaque,
    parent: ?*Job,
    class: JobClass,
    /// Non-null when this job itself was heap-allocated and should be destroyed after execution.
    owner_allocator: ?std.mem.Allocator,
    injected_next: usize,
    /// Tracks "self + children" completion state.
    unfinished_jobs: std.atomic.Value(u32),

    pub fn init(function: JobFn, context: *anyopaque, parent: ?*Job) Job {
        return Job{
            .function = function,
            .context = context,
            .parent = parent,
            .class = .normal,
            .owner_allocator = null,
            .injected_next = 0,
            .unfinished_jobs = std.atomic.Value(u32).init(1),
        };
    }

    pub fn execute(self: *Job) void {
        self.function(self.context);
        self.finish();
    }

    fn finish(self: *Job) void {
        const unfinished = self.unfinished_jobs.fetchSub(1, .acq_rel);
        if (unfinished == 1) {
            if (self.parent) |parent| parent.finish();
        }
    }

    pub fn registerChild(self: *Job) void {
        _ = self.unfinished_jobs.fetchAdd(1, .acq_rel);
    }

    fn unregisterChild(self: *Job) void {
        _ = self.unfinished_jobs.fetchSub(1, .acq_rel);
    }

    pub fn complete(self: *Job) void {
        self.finish();
    }

    pub fn setClass(self: *Job, class: JobClass) void {
        self.class = class;
    }

    pub fn isComplete(self: *const Job) bool {
        return self.unfinished_jobs.load(.acquire) == 0;
    }

    /// Fallback wait API for call-sites that do not have a `JobSystem` handle.
    /// Prefer `JobSystem.waitFor` so waiting threads can help execute queued jobs.
    pub fn wait(self: *const Job) void {
        var spins: u32 = 0;
        while (!self.isComplete()) {
            if ((spins & 255) == 255) {
                std.Thread.yield() catch {};
            } else {
                std.atomic.spinLoopHint();
            }
            spins +%= 1;
        }
    }
};

// ========== JOB QUEUE ==========

/// Chase-Lev work-stealing deque:
/// - the owning worker pushes/pops from the bottom
/// - thieves steal from the top
/// - resize is rare and protected by a mutex, but steady-state queue ops are lock-free
pub const JobQueue = struct {
    jobs: []?*Job,
    mask: usize,
    top: std.atomic.Value(usize),
    bottom: std.atomic.Value(usize),
    resize_mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(capacity: u32, allocator: std.mem.Allocator) !JobQueue {
        if (capacity == 0) return error.InvalidCapacity;
        const cap = @as(usize, std.math.ceilPowerOfTwo(u32, capacity) catch capacity);
        const jobs = try allocator.alloc(?*Job, cap);
        @memset(jobs, null);
        return JobQueue{
            .jobs = jobs,
            .mask = cap - 1,
            .top = std.atomic.Value(usize).init(0),
            .bottom = std.atomic.Value(usize).init(0),
            .resize_mutex = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *JobQueue) void {
        self.allocator.free(self.jobs);
    }

    pub fn push(self: *JobQueue, job: *Job) bool {
        var bottom = self.bottom.load(.monotonic);
        const top = self.top.load(.acquire);
        if (bottom - top >= self.jobs.len - 1) {
            self.resize_mutex.lock();
            defer self.resize_mutex.unlock();
            bottom = self.bottom.load(.monotonic);
            const current_top = self.top.load(.acquire);
            if (bottom - current_top >= self.jobs.len - 1) self.growLocked() catch return false;
        }
        self.jobs[bottom & self.mask] = job;
        self.bottom.store(bottom + 1, .release);
        return true;
    }

    pub fn pop(self: *JobQueue) ?*Job {
        const bottom = self.bottom.load(.monotonic);
        if (bottom == 0) return null;

        const next_bottom = bottom - 1;
        self.bottom.store(next_bottom, .monotonic);
        const top = self.top.load(.acquire);
        if (top > next_bottom) {
            self.bottom.store(bottom, .monotonic);
            return null;
        }

        const slot = next_bottom & self.mask;
        const job = self.jobs[slot];
        if (top == next_bottom) {
            if (self.top.cmpxchgStrong(top, top + 1, .acq_rel, .acquire) != null) {
                self.bottom.store(bottom, .monotonic);
                return null;
            }
            self.bottom.store(bottom, .monotonic);
        }
        self.jobs[slot] = null;
        return job;
    }

    pub fn steal(self: *JobQueue) ?*Job {
        const top = self.top.load(.acquire);
        const bottom = self.bottom.load(.acquire);
        if (top >= bottom) return null;
        const slot = top & self.mask;
        const job = self.jobs[slot];
        if (self.top.cmpxchgStrong(top, top + 1, .acq_rel, .acquire) != null) return null;
        self.jobs[slot] = null;
        return job;
    }

    pub fn count(self: *const JobQueue) u32 {
        const top = self.top.load(.acquire);
        const bottom = self.bottom.load(.acquire);
        if (bottom <= top) return 0;
        return @intCast(@min(bottom - top, @as(usize, std.math.maxInt(u32))));
    }

    fn growLocked(self: *JobQueue) !void {
        const new_capacity = if (self.jobs.len < 1024) self.jobs.len * 2 else self.jobs.len + self.jobs.len / 2;
        const new_jobs = try self.allocator.alloc(?*Job, new_capacity);
        @memset(new_jobs, null);
        const top = self.top.load(.acquire);
        const bottom = self.bottom.load(.acquire);
        var idx = top;
        while (idx < bottom) : (idx += 1) {
            const source_idx = idx & self.mask;
            const dest_idx = idx - top;
            new_jobs[dest_idx] = self.jobs[source_idx];
        }
        self.allocator.free(self.jobs);
        self.jobs = new_jobs;
        self.mask = new_capacity - 1;
        self.top.store(0, .release);
        self.bottom.store(bottom - top, .release);
    }
};

const InjectedQueue = struct {
    head: std.atomic.Value(usize),

    fn init() InjectedQueue {
        return .{
            .head = std.atomic.Value(usize).init(0),
        };
    }

    fn deinit(self: *InjectedQueue) void {
        self.head.store(0, .release);
    }

    fn push(self: *InjectedQueue, job: *Job) bool {
        var current_head = self.head.load(.acquire);
        while (true) {
            job.injected_next = current_head;
            if (self.head.cmpxchgWeak(current_head, @intFromPtr(job), .acq_rel, .acquire) == null) return true;
            current_head = self.head.load(.acquire);
        }
    }

    fn pop(self: *InjectedQueue) ?*Job {
        var current_head = self.head.load(.acquire);
        while (current_head != 0) {
            const job: *Job = @ptrFromInt(current_head);
            const next = job.injected_next;
            if (self.head.cmpxchgWeak(current_head, next, .acq_rel, .acquire) == null) {
                job.injected_next = 0;
                return job;
            }
            current_head = self.head.load(.acquire);
        }
        return null;
    }

    fn isEmpty(self: *const InjectedQueue) bool {
        return self.head.load(.acquire) == 0;
    }

    fn countApprox(self: *const InjectedQueue) u32 {
        var count: u32 = 0;
        var next = self.head.load(.acquire);
        while (next != 0 and count < std.math.maxInt(u32)) {
            const job: *const Job = @ptrFromInt(next);
            next = job.injected_next;
            count += 1;
        }
        return count;
    }
};

// ========== WORKER THREAD ==========

const WorkerThread = struct {
    thread: std.Thread,
    queue: JobQueue,
    system: *JobSystem,
    id: u32,
    running: std.atomic.Value(bool),
    steal_cursor: u32,

    fn run(self: *WorkerThread) void {
        tls_worker_id = self.id;
        while (self.running.load(.acquire)) {
            if (self.system.executeOneForWorker(self.id, &self.steal_cursor)) continue;
            self.system.waitForWork();
        }
        tls_worker_id = null;
    }
};

// ========== JOB SYSTEM ==========

pub const JobSystem = struct {
    workers: []WorkerThread,
    injected_queues: [injected_queue_count]InjectedQueue,
    worker_count: u32,
    allocator: std.mem.Allocator,
    running: std.atomic.Value(bool),
    /// Seed/cursor used to spread submission starts and reduce hot-queue contention.
    submit_seed: std.atomic.Value(u32),
    /// Number of submitted jobs not yet fully completed.
    pending_jobs: std.atomic.Value(u32),
    work_mutex: std.Thread.Mutex,
    work_cond: std.Thread.Condition,

    pub fn init(allocator: std.mem.Allocator) !*JobSystem {
        const cpu_count = std.Thread.getCpuCount() catch 4;
        const worker_count: u32 = if (cpu_count > 1) @as(u32, @intCast(cpu_count - 1)) else 1;

        job_logger.info("detected {} cpu(s), creating {} worker thread(s)", .{ cpu_count, worker_count });

        const workers = try allocator.alloc(WorkerThread, worker_count);
        errdefer allocator.free(workers);

        const system = try allocator.create(JobSystem);
        errdefer allocator.destroy(system);

        system.* = JobSystem{
            .workers = workers,
            .injected_queues = undefined,
            .worker_count = worker_count,
            .allocator = allocator,
            .running = std.atomic.Value(bool).init(true),
            .submit_seed = std.atomic.Value(u32).init(1),
            .pending_jobs = std.atomic.Value(u32).init(0),
            .work_mutex = .{},
            .work_cond = .{},
        };
        var initialized_injected_queue_count: usize = 0;
        errdefer {
            var idx: usize = 0;
            while (idx < initialized_injected_queue_count) : (idx += 1) {
                system.injected_queues[idx].deinit();
            }
        }
        for (0..injected_queue_count) |queue_index| {
            system.injected_queues[queue_index] = InjectedQueue.init();
            initialized_injected_queue_count += 1;
        }

        var initialized_queue_count: usize = 0;
        var spawned_thread_count: usize = 0;
        errdefer {
            system.running.store(false, .release);
            var idx: usize = 0;
            while (idx < spawned_thread_count) : (idx += 1) {
                workers[idx].running.store(false, .release);
            }
            system.work_mutex.lock();
            system.work_cond.broadcast();
            system.work_mutex.unlock();
            idx = 0;
            while (idx < spawned_thread_count) : (idx += 1) {
                workers[idx].thread.join();
            }
            idx = 0;
            while (idx < initialized_queue_count) : (idx += 1) {
                workers[idx].queue.deinit();
            }
        }

        for (workers, 0..) |*worker, i| {
            const seed = @as(u32, @intCast(i)) *% 2654435761 +% 1;
            worker.* = WorkerThread{
                .thread = undefined,
                .queue = try JobQueue.init(worker_local_queue_capacity, allocator),
                .system = system,
                .id = @intCast(i),
                .running = std.atomic.Value(bool).init(true),
                .steal_cursor = seed,
            };
            initialized_queue_count += 1;
        }

        for (workers) |*worker| {
            worker.thread = try std.Thread.spawn(.{}, WorkerThread.run, .{worker});
            job_logger.debug("worker {} online queue_capacity={}", .{ worker.id, worker.queue.jobs.len });
            spawned_thread_count += 1;
        }

        job_logger.info("job system ready workers={}", .{worker_count});
        return system;
    }

    pub fn deinit(self: *JobSystem) void {
        const allocator = self.allocator;

        job_logger.info("stopping job system workers={}", .{self.worker_count});

        self.running.store(false, .release);
        for (self.workers) |*worker| {
            worker.running.store(false, .release);
        }

        self.work_mutex.lock();
        self.work_cond.broadcast();
        self.work_mutex.unlock();

        for (self.workers) |*worker| {
            worker.thread.join();
            worker.queue.deinit();
        }

        for (&self.injected_queues) |*queue| queue.deinit();
        allocator.free(self.workers);
        allocator.destroy(self);
    }

    pub fn submitJobAuto(self: *JobSystem, job: *Job) bool {
        return self.submitJobWithClass(job, job.class);
    }

    pub fn submitJobWithClass(self: *JobSystem, job: *Job, class: JobClass) bool {
        if (self.worker_count == 0) return false;
        job.class = class;

        var parent_registered = false;
        if (job.parent) |parent| {
            parent.registerChild();
            parent_registered = true;
        }
        defer if (parent_registered) {
            if (job.parent) |parent| parent.unregisterChild();
        };

        _ = self.pending_jobs.fetchAdd(1, .acq_rel);
        var should_rollback_pending = true;
        defer if (should_rollback_pending) {
            const pending_before = self.pending_jobs.fetchSub(1, .acq_rel);
            if (pending_before == 0) {
                self.pending_jobs.store(0, .release);
            }
        };

        if (tls_worker_id) |wid| {
            if (self.workers[wid].queue.push(job)) {
                should_rollback_pending = false;
                parent_registered = false;
                self.work_mutex.lock();
                self.work_cond.signal();
                self.work_mutex.unlock();
                return true;
            }
        }

        if (self.injected_queues[class.index()].push(job)) {
            should_rollback_pending = false;
            parent_registered = false;
            self.work_mutex.lock();
            self.work_cond.signal();
            self.work_mutex.unlock();
            return true;
        }

        job_logger.err("failed to submit job class={s}", .{@tagName(class)});
        return false;
    }

    pub fn waitFor(self: *JobSystem, job: *const Job) void {
        var spins: u32 = 0;
        var main_steal_cursor = self.submit_seed.load(.acquire);
        if (main_steal_cursor == 0) main_steal_cursor = 1;

        while (!job.isComplete()) {
            var progressed = false;
            if (tls_worker_id) |wid| {
                progressed = self.executeOneForWorker(wid, &self.workers[wid].steal_cursor);
            } else {
                progressed = self.executeOneAny(&main_steal_cursor);
            }

            if (progressed) {
                spins = 0;
                continue;
            }

            if ((spins & 255) == 255) {
                self.waitForProgress(job);
            } else {
                std.atomic.spinLoopHint();
            }
            spins +%= 1;
        }
    }

    fn waitForProgress(self: *JobSystem, job: *const Job) void {
        self.work_mutex.lock();
        defer self.work_mutex.unlock();

        if (job.isComplete()) return;
        if (!self.running.load(.acquire)) return;
        if (self.pending_jobs.load(.acquire) == 0) return;
        self.work_cond.wait(&self.work_mutex);
    }

    fn waitForWork(self: *JobSystem) void {
        self.work_mutex.lock();
        defer self.work_mutex.unlock();

        while (self.running.load(.acquire) and self.pending_jobs.load(.acquire) == 0) {
            self.work_cond.wait(&self.work_mutex);
        }
    }

    fn executeOneForWorker(self: *JobSystem, worker_id: u32, steal_cursor: *u32) bool {
        var maybe_job = self.tryTakeInjectedJob();
        if (maybe_job == null) maybe_job = self.workers[worker_id].queue.pop();
        if (maybe_job == null) maybe_job = self.stealJob(worker_id, steal_cursor);
        if (maybe_job) |job| {
            self.executeAndFinalize(job);
            return true;
        }
        return false;
    }

    fn executeOneAny(self: *JobSystem, steal_cursor: *u32) bool {
        if (self.worker_count == 0) return false;
        if (self.tryTakeInjectedJob()) |job| {
            self.executeAndFinalize(job);
            return true;
        }
        if (self.stealAny(steal_cursor)) |job| {
            self.executeAndFinalize(job);
            return true;
        }
        return false;
    }

    fn executeAndFinalize(self: *JobSystem, job: *Job) void {
        const owner_allocator = job.owner_allocator;
        job.execute();
        if (owner_allocator) |allocator| {
            allocator.destroy(job);
        }

        const previous = self.pending_jobs.fetchSub(1, .acq_rel);
        if (previous == 0) {
            self.pending_jobs.store(0, .release);
            job_logger.err("pending_jobs underflow detected while finalizing job", .{});
            self.work_mutex.lock();
            self.work_cond.broadcast();
            self.work_mutex.unlock();
            return;
        }
        if (previous <= 1) {
            self.work_mutex.lock();
            self.work_cond.broadcast();
            self.work_mutex.unlock();
            return;
        }

        if (previous <= self.worker_count + 1) {
            self.work_mutex.lock();
            self.work_cond.signal();
            self.work_mutex.unlock();
        }
    }

    fn stealJob(self: *JobSystem, stealer_id: u32, steal_cursor: *u32) ?*Job {
        if (self.worker_count <= 1) return null;

        const span = self.worker_count - 1;
        var offset = (steal_cursor.* % span) + 1;
        var attempts: u32 = 0;
        while (attempts < span) : (attempts += 1) {
            const target_id = (stealer_id + offset) % self.worker_count;
            if (self.workers[target_id].queue.steal()) |job| {
                steal_cursor.* = offset +% 1;
                return job;
            }
            offset = if (offset == span) 1 else offset + 1;
        }
        steal_cursor.* = offset;
        return null;
    }

    fn stealAny(self: *JobSystem, steal_cursor: *u32) ?*Job {
        if (self.worker_count == 0) return null;

        const start = steal_cursor.* % self.worker_count;
        var attempts: u32 = 0;
        while (attempts < self.worker_count) : (attempts += 1) {
            const target_id = (start + attempts) % self.worker_count;
            if (self.workers[target_id].queue.steal()) |job| {
                steal_cursor.* = target_id +% 1;
                return job;
            }
        }
        steal_cursor.* +%= 1;
        return null;
    }

    fn tryTakeInjectedJob(self: *JobSystem) ?*Job {
        inline for ([_]JobClass{ .high, .normal, .background }) |class| {
            if (self.injected_queues[class.index()].pop()) |job| return job;
        }
        return null;
    }

    pub fn pendingJobs(self: *const JobSystem) u32 {
        return self.pending_jobs.load(.acquire);
    }
};

// ========== HELPER FUNCTIONS ==========

pub fn allocateJob(allocator: std.mem.Allocator, function: JobFn, context: *anyopaque, parent: ?*Job) !*Job {
    const job = try allocator.create(Job);
    job.* = Job.init(function, context, parent);
    job.owner_allocator = allocator;
    return job;
}

pub fn freeJob(allocator: std.mem.Allocator, job: *Job) void {
    allocator.destroy(job);
}

test "job queue grows when full" {
    var queue = try JobQueue.init(1, std.testing.allocator);
    defer queue.deinit();

    var job_a = Job.init(noopTestJob, @ptrFromInt(1), null);
    var job_b = Job.init(noopTestJob, @ptrFromInt(2), null);

    try std.testing.expect(queue.push(&job_a));
    try std.testing.expect(queue.push(&job_b));
    try std.testing.expectEqual(@as(u32, 2), queue.count());
    try std.testing.expect(queue.jobs.len >= 2);
}

test "job completion cascades to parent" {
    var parent = Job.init(noopTestJob, @ptrFromInt(1), null);
    parent.registerChild();
    var child = Job.init(noopTestJob, @ptrFromInt(2), &parent);

    try std.testing.expect(!parent.isComplete());
    child.complete();
    try std.testing.expect(!parent.isComplete());
    parent.complete();
    try std.testing.expect(parent.isComplete());
}

test "injected queues prefer high priority work" {
    const empty_workers = try std.testing.allocator.alloc(WorkerThread, 0);
    defer std.testing.allocator.free(empty_workers);

    var queues: [injected_queue_count]InjectedQueue = undefined;
    for (0..injected_queue_count) |idx| {
        queues[idx] = InjectedQueue.init();
    }
    defer for (&queues) |*queue| queue.deinit();

    var system = JobSystem{
        .workers = empty_workers,
        .injected_queues = queues,
        .worker_count = 0,
        .allocator = std.testing.allocator,
        .running = std.atomic.Value(bool).init(true),
        .submit_seed = std.atomic.Value(u32).init(1),
        .pending_jobs = std.atomic.Value(u32).init(0),
        .work_mutex = .{},
        .work_cond = .{},
    };

    var low = Job.init(noopTestJob, @ptrFromInt(1), null);
    low.setClass(.background);
    var high = Job.init(noopTestJob, @ptrFromInt(2), null);
    high.setClass(.high);
    try std.testing.expect(system.injected_queues[JobClass.background.index()].push(&low));
    try std.testing.expect(system.injected_queues[JobClass.high.index()].push(&high));

    try std.testing.expectEqual(&high, system.tryTakeInjectedJob().?);
    try std.testing.expectEqual(&low, system.tryTakeInjectedJob().?);
}

fn noopTestJob(_: *anyopaque) void {}
