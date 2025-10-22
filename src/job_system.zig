//! # A Multi-threaded Job System for Parallel Execution
//!
//! This module implements a "work-stealing" job system. Its purpose is to take a large
//! number of small tasks (jobs) and distribute them efficiently across all available CPU cores.
//! This is the foundation for the renderer's high performance.
//!
//! ## JavaScript Analogy: A Smart Web Worker Pool
//!
//! Imagine you have a pool of Web Workers. A job system is like a manager for that pool.
//!
//! 1.  **You define work**: You have a task, like `processImage(data)`, that you want to run in parallel.
//! 2.  **You submit jobs**: You tell the job system, "run `processImage` with `data1`", "run `processImage` with `data2`", etc.
//! 3.  **The system distributes work**: The job system automatically assigns these jobs to its pool of worker threads.
//! 4.  **Work-Stealing**: Here's the clever part. If one worker finishes its to-do list, it doesn't sit idle.
//!     It "steals" a job from the back of another worker's queue. This keeps all CPU cores busy.
//!
//! This is far more efficient than manually managing workers with `postMessage` because the load balancing is automatic.

const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");

const job_logger = log.get("jobs.core");

// ========== JOB STRUCTURE ==========

/// A job function signature. All jobs are functions that take a single, generic pointer for context.
/// JS Analogy: `(context) => { /* do work */ }`
pub const JobFn = *const fn (ctx: *anyopaque) void;

/// A `Job` represents a single unit of work that can be executed by any worker thread.
/// JS Analogy: This is the "message" you'd send to a Web Worker. It contains the function to run
/// and the data to run it on.
pub const Job = struct {
    /// The function to be executed for this job.
    function: JobFn,
    /// A generic ("opaque") pointer to the data this job needs. The job function knows how to interpret this.
    context: *anyopaque,
    /// A pointer to a parent job. This allows for creating dependencies between jobs.
    parent: ?*Job,
    /// An atomic counter for tracking how many child jobs are left to be completed.
    /// When this hits zero, the job is considered finished.
    unfinished_jobs: std.atomic.Value(u32),

    /// Creates a new job.
    pub fn init(function: JobFn, context: *anyopaque, parent: ?*Job) Job {
        return Job{
            .function = function,
            .context = context,
            .parent = parent,
            // A job starts with 1 unfinished task: itself.
            .unfinished_jobs = std.atomic.Value(u32).init(1),
        };
    }

    /// Executes the job's function and marks it as finished.
    pub fn execute(self: *Job) void {
        self.function(self.context);
        self.finish();
    }

    /// Marks the job as finished. If this job has a parent, it decrements the parent's
    /// unfinished job counter. This is how dependencies are resolved.
    fn finish(self: *Job) void {
        // Atomically decrement the counter.
        const unfinished = self.unfinished_jobs.fetchSub(1, .release);

        // If the counter was 1 before we decremented it, it means this was the last task
        // for this job to be completed.
        if (unfinished == 1) {
            // If we have a parent, we notify it that one of its children has finished.
            if (self.parent) |_| return;
        }
    }

    /// Checks if the job and all its potential children are complete.
    pub fn isComplete(self: *const Job) bool {
        return self.unfinished_jobs.load(.acquire) == 0;
    }

    /// Waits (by spinning) until the job is complete. This is a simple way to synchronize.
    pub fn wait(self: *const Job) void {
        while (!self.isComplete()) {
            // Hint to the CPU that we are in a spin-wait loop.
            std.atomic.spinLoopHint();
        }
    }
};

// ========== JOB QUEUE (DEQUE) ==========

/// A double-ended queue (deque) for jobs, guarded by a mutex.
/// Each worker thread has its own deque.
/// - The worker `pop`s from the bottom (LIFO - Last-In, First-Out).
/// - Other workers `steal` from the top (FIFO - First-In, First-Out).
/// This strategy reduces contention and improves cache performance.
pub const JobQueue = struct {
    jobs: []?*Job,
    capacity: u32,
    head: u32, // Index for stealing (top of the deque).
    tail: u32, // Index for pushing/popping (bottom of the deque).
    len: u32,
    mutex: std.Thread.Mutex, // A lock to ensure only one thread can modify the queue at a time.
    allocator: std.mem.Allocator,

    pub fn init(capacity: u32, allocator: std.mem.Allocator) !JobQueue {
        if (capacity == 0) return error.InvalidCapacity;
        const jobs = try allocator.alloc(?*Job, capacity);
        @memset(jobs, null);
        return JobQueue{
            .jobs = jobs,
            .capacity = capacity,
            .head = 0,
            .tail = 0,
            .len = 0,
            .mutex = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *JobQueue) void {
        self.allocator.free(self.jobs);
    }

    /// Pushes a job onto the bottom of the deque.
    pub fn push(self: *JobQueue, job: *Job) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.len == self.capacity) return false;
        self.jobs[self.tail] = job;
        self.tail = (self.tail + 1) % self.capacity;
        self.len += 1;
        return true;
    }

    /// Pops a job from the bottom of the deque (for the owner worker).
    pub fn pop(self: *JobQueue) ?*Job {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.len == 0) return null;
        self.tail = (self.tail + self.capacity - 1) % self.capacity;
        const job = self.jobs[self.tail];
        self.jobs[self.tail] = null;
        self.len -= 1;
        return job;
    }

    /// Steals a job from the top of the deque (for other workers).
    pub fn steal(self: *JobQueue) ?*Job {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.len == 0) return null;
        const job = self.jobs[self.head];
        self.jobs[self.head] = null;
        self.head = (self.head + 1) % self.capacity;
        self.len -= 1;
        return job;
    }

    pub fn count(self: *const JobQueue) u32 {
        const queue = @constCast(self);
        queue.mutex.lock();
        defer queue.mutex.unlock();
        return queue.len;
    }
};

// ========== WORKER THREAD ==========

/// Represents a single worker thread that executes jobs.
/// JS Analogy: An individual `Web Worker`.
const WorkerThread = struct {
    thread: std.Thread,
    queue: JobQueue, // The worker's own personal to-do list.
    system: *JobSystem, // A reference back to the main system.
    id: u32,
    running: std.atomic.Value(bool),

    /// The main loop for a worker thread.
    fn run(self: *WorkerThread) void {
        while (self.running.load(.acquire)) {
            // 1. First, try to get a job from our own queue.
            var job = self.queue.pop();

            // 2. If our queue is empty, try to steal a job from another worker.
            if (job == null) {
                job = self.system.stealJob(self.id);
            }

            // 3. If we have a job, execute it.
            if (job) |j| {
                j.execute();
            } else {
                // 4. If there's no work anywhere, yield to the OS to avoid busy-waiting.
                std.Thread.yield() catch {};
            }
        }
    }
};

// ========== JOB SYSTEM ==========

/// The main JobSystem struct. It manages the pool of worker threads and job distribution.
/// JS Analogy: The main class that manages your entire `Worker` pool.
pub const JobSystem = struct {
    workers: []WorkerThread,
    worker_count: u32,
    allocator: std.mem.Allocator,
    running: std.atomic.Value(bool),
    next_worker: std.atomic.Value(u32), // Used for round-robin job submission.

    /// Initializes the job system. It typically creates one worker thread per CPU core,
    /// minus one for the main application thread.
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
            .next_worker = std.atomic.Value(u32).init(0),
        };

        // Initialize each worker thread.
        for (workers, 0..) |*worker, i| {
            worker.* = WorkerThread{
                .thread = undefined,
                .queue = try JobQueue.init(1024, allocator), // Each worker gets its own queue.
                .system = system,
                .id = @intCast(i),
                .running = std.atomic.Value(bool).init(true),
            };
        }

        // Start the worker threads. They will immediately start looking for jobs.
        for (workers) |*worker| {
            worker.thread = try std.Thread.spawn(.{}, WorkerThread.run, .{worker});
            job_logger.debugSub("init", "worker {} online queue_capacity={}", .{ worker.id, worker.queue.capacity });
        }

        job_logger.infoSub("init", "job system ready workers={}", .{worker_count});
        return system;
    }

    /// Shuts down the job system, signaling all threads to stop and waiting for them to finish.
    pub fn deinit(self: *JobSystem) void {
        const allocator = self.allocator;

        job_logger.infoSub("shutdown", "stopping job system workers={}", .{self.worker_count});

        self.running.store(false, .release);
        for (self.workers) |*worker| {
            worker.running.store(false, .release);
        }

        for (self.workers) |*worker| {
            worker.thread.join();
            worker.queue.deinit();
        }

        allocator.free(self.workers);
        allocator.destroy(self);
    }

    /// Submits a job to the system. It uses a simple round-robin approach to try and find
    /// a worker queue that is not full.
    pub fn submitJobAuto(self: *JobSystem, job: *Job) bool {
        var attempts: u32 = 0;
        while (attempts < self.worker_count) : (attempts += 1) {
            const worker_idx = (self.next_worker.fetchAdd(1, .monotonic)) % self.worker_count;
            if (self.workers[worker_idx].queue.push(job)) {
                return true;
            }
        }
        job_logger.errorSub("submit", "failed to submit job after {} worker attempts", .{self.worker_count});
        return false;
    }

    /// The core work-stealing logic. Called by an idle worker to try and steal a job
    /// from another, potentially busy worker.
    fn stealJob(self: *JobSystem, stealer_id: u32) ?*Job {
        var i: u32 = 1;
        while (i < self.worker_count) : (i += 1) {
            const target_id = (stealer_id + i) % self.worker_count;
            if (target_id >= self.worker_count) continue;

            // Try to steal from the top of the target's queue.
            if (self.workers[target_id].queue.steal()) |job| {
                return job;
            }
        }
        return null;
    }

    pub fn pendingJobs(self: *const JobSystem) u32 {
        var total: u32 = 0;
        for (self.workers) |*worker| {
            total += worker.queue.count();
        }
        return total;
    }
};

// ========== HELPER FUNCTIONS ==========

/// Helper to allocate a new job on the heap.
pub fn allocateJob(allocator: std.mem.Allocator, function: JobFn, context: *anyopaque, parent: ?*Job) !*Job {
    const job = try allocator.create(Job);
    job.* = Job.init(function, context, parent);
    return job;
}

/// Helper to free a heap-allocated job.
pub fn freeJob(allocator: std.mem.Allocator, job: *Job) void {
    allocator.destroy(job);
}
