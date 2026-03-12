//! # A Multi-threaded Job System for Parallel Execution
//!
//! This module implements a work-stealing job system tuned for CPU-heavy frame workloads.
//! It keeps owner-thread queue operations lock-free, uses stealing for load balancing, and
//! supports cooperative waiting where the waiting thread helps drain queued work.

const std = @import("std");
const log = @import("log.zig");

const job_logger = log.get("jobs.core");

threadlocal var tls_worker_id: ?u32 = null;
threadlocal var tls_worker_steal_cursor: u32 = 1;

// ========== JOB STRUCTURE ==========

/// A job function signature. All jobs are functions that take a single, generic pointer for context.
pub const JobFn = *const fn (ctx: *anyopaque) void;

/// A `Job` represents a single unit of work that can be executed by any worker thread.
pub const Job = struct {
    function: JobFn,
    context: *anyopaque,
    parent: ?*Job,
    /// Non-null when this job itself was heap-allocated and should be destroyed after execution.
    owner_allocator: ?std.mem.Allocator,
    /// Tracks "self + children" completion state.
    unfinished_jobs: std.atomic.Value(u32),

    pub fn init(function: JobFn, context: *anyopaque, parent: ?*Job) Job {
        return Job{
            .function = function,
            .context = context,
            .parent = parent,
            .owner_allocator = null,
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

// ========== JOB QUEUE (LOCK-FREE CHASE-LEV DEQUE) ==========

fn roundUpPow2(v: usize) usize {
    if (v <= 1) return 1;
    var x = v - 1;
    const bits = @bitSizeOf(usize);
    var shift: usize = 1;
    while (shift < bits) : (shift <<= 1) {
        x |= x >> @intCast(shift);
    }
    return x + 1;
}

/// Work-stealing deque:
/// - Owner thread pushes/pops from `bottom` (LIFO), lock-free.
/// - Thieves steal from `top` (FIFO-ish), lock-free CAS.
pub const JobQueue = struct {
    jobs: []?*Job,
    capacity: usize,
    mask: usize,
    top: std.atomic.Value(usize),
    bottom: std.atomic.Value(usize),
    allocator: std.mem.Allocator,

    pub fn init(capacity: u32, allocator: std.mem.Allocator) !JobQueue {
        if (capacity == 0) return error.InvalidCapacity;
        const cap = roundUpPow2(@as(usize, capacity));
        const jobs = try allocator.alloc(?*Job, cap);
        @memset(jobs, null);
        return JobQueue{
            .jobs = jobs,
            .capacity = cap,
            .mask = cap - 1,
            .top = std.atomic.Value(usize).init(0),
            .bottom = std.atomic.Value(usize).init(0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *JobQueue) void {
        self.allocator.free(self.jobs);
    }

    /// Owner-thread only.
    pub fn push(self: *JobQueue, job: *Job) bool {
        const b = self.bottom.load(.monotonic);
        const t = self.top.load(.acquire);
        if (b - t >= self.capacity) return false; // Full.

        self.jobs[b & self.mask] = job;
        self.bottom.store(b + 1, .release);
        return true;
    }

    /// Owner-thread only.
    pub fn pop(self: *JobQueue) ?*Job {
        const b_start = self.bottom.load(.monotonic);
        if (b_start == 0) return null;

        const b = b_start - 1;
        self.bottom.store(b, .monotonic);
        const t = self.top.load(.monotonic);
        if (t > b) {
            self.bottom.store(t, .release);
            return null;
        }

        var job = self.jobs[b & self.mask];
        if (t == b) {
            // Last item races with stealers.
            if (self.top.cmpxchgStrong(t, t + 1, .seq_cst, .monotonic) != null) {
                job = null;
            }
            self.bottom.store(t + 1, .release);
        }
        return job;
    }

    /// Thief-thread safe.
    pub fn steal(self: *JobQueue) ?*Job {
        const t = self.top.load(.acquire);
        const b = self.bottom.load(.acquire);
        if (t >= b) return null;

        const job = self.jobs[t & self.mask];
        if (self.top.cmpxchgStrong(t, t + 1, .acq_rel, .acquire) != null) return null;
        return job;
    }

    pub fn count(self: *const JobQueue) u32 {
        const t = self.top.load(.acquire);
        const b = self.bottom.load(.acquire);
        if (b <= t) return 0;
        const diff = b - t;
        return @intCast(@min(diff, @as(usize, std.math.maxInt(u32))));
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
        tls_worker_steal_cursor = self.steal_cursor;
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

        job_logger.infoSub(
            "init",
            "detected {} cpu(s), creating {} worker thread(s)",
            .{ cpu_count, worker_count },
        );

        const workers = try allocator.alloc(WorkerThread, worker_count);
        errdefer allocator.free(workers);

        const system = try allocator.create(JobSystem);
        errdefer allocator.destroy(system);

        system.* = JobSystem{
            .workers = workers,
            .worker_count = worker_count,
            .allocator = allocator,
            .running = std.atomic.Value(bool).init(true),
            .submit_seed = std.atomic.Value(u32).init(1),
            .pending_jobs = std.atomic.Value(u32).init(0),
            .work_mutex = .{},
            .work_cond = .{},
        };

        for (workers, 0..) |*worker, i| {
            const seed = @as(u32, @intCast(i)) *% 2654435761 +% 1;
            worker.* = WorkerThread{
                .thread = undefined,
                .queue = try JobQueue.init(1024, allocator),
                .system = system,
                .id = @intCast(i),
                .running = std.atomic.Value(bool).init(true),
                .steal_cursor = seed,
            };
        }

        for (workers) |*worker| {
            worker.thread = try std.Thread.spawn(.{}, WorkerThread.run, .{worker});
            job_logger.debugSub("init", "worker {} online queue_capacity={}", .{ worker.id, worker.queue.capacity });
        }

        job_logger.infoSub("init", "job system ready workers={}", .{worker_count});
        return system;
    }

    pub fn deinit(self: *JobSystem) void {
        const allocator = self.allocator;

        job_logger.infoSub("shutdown", "stopping job system workers={}", .{self.worker_count});

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

        allocator.free(self.workers);
        allocator.destroy(self);
    }

    pub fn submitJobAuto(self: *JobSystem, job: *Job) bool {
        if (self.worker_count == 0) return false;

        if (job.parent) |parent| parent.registerChild();
        errdefer if (job.parent) |parent| parent.unregisterChild();

        const start = self.submit_seed.fetchAdd(1, .monotonic) % self.worker_count;
        var attempts: u32 = 0;
        while (attempts < self.worker_count) : (attempts += 1) {
            const worker_idx = (start + attempts) % self.worker_count;
            if (self.workers[worker_idx].queue.push(job)) {
                _ = self.pending_jobs.fetchAdd(1, .acq_rel);
                self.work_mutex.lock();
                self.work_cond.signal();
                self.work_mutex.unlock();
                return true;
            }
        }

        job_logger.errorSub("submit", "failed to submit job after {} worker attempts", .{self.worker_count});
        return false;
    }

    pub fn waitFor(self: *JobSystem, job: *const Job) void {
        var spins: u32 = 0;
        var main_steal_cursor = self.submit_seed.load(.acquire);
        if (main_steal_cursor == 0) main_steal_cursor = 1;

        while (!job.isComplete()) {
            var progressed = false;
            if (tls_worker_id) |wid| {
                progressed = self.executeOneForWorker(wid, &tls_worker_steal_cursor);
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
        var maybe_job = self.workers[worker_id].queue.pop();
        if (maybe_job == null) maybe_job = self.stealJob(worker_id, steal_cursor);
        if (maybe_job) |job| {
            self.executeAndFinalize(job);
            return true;
        }
        return false;
    }

    fn executeOneAny(self: *JobSystem, steal_cursor: *u32) bool {
        if (self.worker_count == 0) return false;
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
        if (previous <= 1) {
            self.pending_jobs.store(0, .release);
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
